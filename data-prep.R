library(tidyverse)
library(sf)
library(duckdb)
library(tictoc)
library(furrr)
library(terra)
library(dbplyr)

con <- dbConnect(duckdb(dbdir = "data/inat.duckdb"))
con |> dbExecute("install spatial; load spatial;")
con |> dbExecute("ATTACH DATABASE '~/Data/Occurrences/GBIF/gbif.duckdb' AS gbif (READ_ONLY);")


specs100 <- con |>
  tbl("gbif.gbif") |>
  distinct(species) |>
  head(500) |>
  collect() |>
  pull(species)

con |> dbExecute(
  sprintf(
    "
    CREATE OR REPLACE TABLE inat AS
  SELECT * FROM gbif.gbif
  WHERE institutioncode = 'iNaturalist'
  -- AND species IN ('%s')
  AND decimallatitude IS NOT NULL
  AND decimallongitude IS NOT NULL
  ",
    paste(specs100, collapse = "','")
  )
)

# elv <- con |>
#   tbl("gbif") |>
#   filter(species == "Calochortus albus") |>
#   pull(elevation)


# SRTM altitude ---------------------------------------
# library(gdalUtilities)
# setwd('~/Data/Environment/SRTM')
# gdal_translate(
#   src_dataset = "srtm-v3-1s.tif",
#   dst_dataset = "srtm-v3-1s_cog.tif",
#   of = "COG",
#   co = c(
#     "COMPRESS=DEFLATE",
#     "TILED=YES",
#     "BLOCKSIZE=512",
#     "ADD_OVERVIEWS=YES",
#     "BIGTIFF=YES"
#   )
# )


# 1. open DuckDB and your COG (still on disk!)
con <- dbConnect(duckdb(dbdir = "data/inat.duckdb"))
con |> dbExecute("install spatial; load spatial;")
terraOptions(memmax = 25)
r <- rast("~/Data/Environment/SRTM/srtm-v3-1s_cog.tif")

# 2. prepare and fetch all data at once
all_points <- con |> dbGetQuery("
  SELECT gbifid, decimallongitude AS x, decimallatitude AS y
  FROM inat
")
object.size(all_points) |> format(units = "GB")

# 3. Split data into chunks for parallel processing
chunk_size <- 1e5
chunks <- split(all_points, ceiling(seq_len(nrow(all_points)) / chunk_size))

# Set up parallel processing
plan(multicore, workers = 8)
con |> dbExecute("DROP TABLE IF EXISTS points_sampled")
tic("Parallel processing - computation phase")
# Process chunks in parallel but only do computation, not DB writes
processed_chunks <- future_map(chunks, function(.x) {
  pts_xy <- cbind(.x$x, .x$y)
  alt <- terra::extract(r, pts_xy) |> pull(1)
  .x$altitude <- alt

  # Return the processed chunk instead of writing to DB
  return(.x)
}, .options = furrr_options(seed = TRUE))
toc()
plan(sequential)

# Now write to database sequentially after parallel processing is complete
tic("Writing to database")
# Create table for first chunk
con |> dbWriteTable("points_sampled", processed_chunks |> bind_rows(), overwrite = TRUE)
con |> dbDisconnect(shutdown = TRUE)

# Free up memory
rm(all_points, chunks, processed_chunks)
gc()

con |>
  tbl("points_sampled")


# Find max and min lat and elev for each species ---------------------------------------
ncon <- dbConnect(duckdb(dbdir = "data/shiny.duckdb"))
ncon |> dbExecute("install spatial; load spatial;")
ncon |> dbExecute("SET MEMORY_LIMIT ='300GB';")
ncon |> dbExecute("ATTACH DATABASE 'data/inat.duckdb' AS inat (READ_ONLY);")

minmax <- ncon |>
  tbl("inat.inat") |>
  left_join(
    ncon |> tbl("inat.points_sampled") |>
      select(gbifid, altitude),
    by = c("gbifid" = "gbifid")
  ) |>
  group_by(species) |>
  mutate(
    is_max_lat = decimallatitude == max(decimallatitude, na.rm = TRUE),
    is_min_lat = decimallatitude == min(decimallatitude, na.rm = TRUE),
    is_max_alt = altitude == max(altitude, na.rm = TRUE),
    is_min_alt = altitude == min(altitude, na.rm = TRUE)
  ) |>
  ungroup() |>
  filter(is_max_lat | is_min_lat | is_max_alt | is_min_alt)

sql_minmax <- minmax |> sql_render()

ncon |> dbExecute(
  sprintf("CREATE OR REPLACE TABLE shiny.minmax AS (%s)", sql_minmax)
)

# add indexes to gbifid, altitude, and decimallatitude on shiny.minmax
ncon |> dbExecute("CREATE INDEX idx_gbifid ON shiny.minmax (gbifid);")
ncon |> dbExecute("CREATE INDEX idx_altitude ON shiny.minmax (altitude);")
ncon |> dbExecute("CREATE INDEX idx_decimallatitude ON shiny.minmax (decimallatitude);")
ncon |> dbExecute("CREATE INDEX idx_decimallongitude ON shiny.minmax (decimallongitude);")
ncon |> dbExecute("CREATE INDEX idx_species ON shiny.minmax (species);")

ncon |>
  tbl("minmax") |>
  filter(species == "Calochortus albus") |>
  collect()

dbDisconnect(ncon)

# add h3 ---------------------------------------
ncon <- dbConnect(duckdb(dbdir = "data/shiny.duckdb"))
ncon |> dbExecute("install spatial; load spatial; INSTALL h3 FROM community;LOAD h3;")

ncon |> dbExecute("
-- Add H3 cells at resolution 4 as a new column
ALTER TABLE shiny.minmax
ADD COLUMN h3_cell_res4 UBIGINT;

UPDATE shiny.minmax
SET h3_cell_res4 = h3_latlng_to_cell(decimallatitude, decimallongitude, 4);

-- Add index on the H3 cell column
CREATE INDEX idx_h3_cell ON shiny.minmax (h3_cell_res4);
")

dbDisconnect(ncon)
