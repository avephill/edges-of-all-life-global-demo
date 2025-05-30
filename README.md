# Global Species Altitude and Latitude Range Limits

A Shiny web application that visualizes the latitudinal and altitudinal range limits of species from iNaturalist data. This is a proof-of-concept that extends [Brian Buma's "Edges of (All) Life"](https://www.brianbuma.com/edges-of-all-life) to a global scale and adds altitude data.

## Major Packages

- **R Shiny** - Web application framework
- **DuckDB** - High-performance columnar database engine
- **Maplibre GL** - Interactive web mapping
- **sf** - Spatial data handling

## Data Processing Pipeline

The `data-prep.R` script performs a multi-stage data processing workflow:

**Input Data:**
- Raw GBIF database (`.duckdb` format) containing global biodiversity observations
- SRTM v3 digital elevation model (`.tif` format, 100+GB) providing global altitude data

**Processing Steps:**
1. **Filter iNaturalist records** - Extracts all iNaturalist observations from the complete GBIF dataset (January 2025 snapshot) with valid coordinates
2. **Altitude extraction** - Uses parallel processing to extract elevation values from 30m SRTM rasters for all iNaturalist observation points (~50 minutes runtime)
3. **Range limit calculation** - Groups data by species and identifies northernmost/southernmost latitudes and highest/lowest altitudes for each of ~390,000 species (~15 minutes runtime)

**Output:**
- `data/shiny.duckdb` - Optimized database (~500MB) containing species range limit points with:
  - Geographic coordinates (lat/lon)
  - Altitude values
  - Range limit flags (max/min latitude and altitude per species)
  - Database indexes for fast querying in the Shiny application

**Local Setup Requirements:**
Note that you won't be able to run the data processing workflow of this application on your own machine without:
1. A local `.duckdb` version of the GBIF dataset
2. SRTM elevation data files (100+GB)
3. Significant computational resources for data processing (the workflow uses up to 300GB memory, and could use less but would take longer)
 