library(shiny)
library(mapgl)
library(duckdb)
library(dplyr)
library(dbplyr)
library(shinyWidgets)
library(stringr)
library(sf)
library(tictoc)


# UI
ui <- fluidPage(
  tags$head(
    tags$style(HTML("
      html, body {height: 100%;}
      #map {height: calc(100vh - 120px) !important;}
      .controls {
        position: absolute;
        top: 10px;
        right: 10px;
        z-index: 1000;
        background: white;
        padding: 10px;
        border-radius: 5px;
        box-shadow: 0 0 15px rgba(0,0,0,0.2);
        width: 300px;
      }
    "))
  ),

  # Title
  titlePanel("Edges of All Life Global Demo"),

  # Map with controls overlay
  div(
    style = "position: relative;",
    maplibreOutput("map"),

    # Controls panel
    div(
      class = "controls",
      selectInput("displayType", "Display Points By:",
        choices = c(
          "Max Latitude" = "is_max_lat",
          "Min Latitude" = "is_min_lat",
          "Max Altitude" = "is_max_alt",
          "Min Altitude" = "is_min_alt"
        ),
        selected = "is_max_lat"
      ),
      selectizeInput(
        inputId = "speciesFilter",
        label = "Filter by Species (optional):",
        choices = character(0),
      )
    )
  ),

  # Footer
  div(
    style = "padding: 10px; text-align: center; color: #666; font-size: 0.9em;",
    "Data downloaded January 2025 form GBIF • Map only shows 10,000 points at a time"
  )
)

# Server
server <- function(input, output, session) {
  tic("Server initialization")
  # Connect to DuckDB
  con <- dbConnect(duckdb(dbdir = "data/shiny.duckdb"))
  toc()

  # Create tbl reference to the minmax table
  minmax_tbl <- tbl(con, "minmax")

  # Set up server-side species search
  tic("Configure server-side species search")
  # Initialize selectize with server-side processing
  matching_species <- minmax_tbl %>%
    distinct(species) %>%
    pull(species)

  # Update the selectize choices
  updateSelectizeInput(
    session,
    "speciesFilter",
    choices = matching_species,
    server = TRUE,
    options = list(
      placeholder = "Type to search...",
      maxItems = 10,
      maxOptions = 10
    )
  )

  # Reactive query to get points based on filters
  points_data <- reactive({
    tic("Points query")
    req(input$displayType)

    # Base query using dbplyr
    query <- minmax_tbl %>%
      select(species,
        lng = decimallongitude,
        lat = decimallatitude,
        altitude,
        gbifid,
        starts_with("is_")
      ) %>%
      filter(.data[[input$displayType]] == TRUE) %>%
      mutate(is_selected = TRUE)

    # Add species filter if selected
    if (!is.null(input$speciesFilter) && length(input$speciesFilter) > 0) {
      query <- query %>% filter(species %in% !!input$speciesFilter)
    }

    # Execute the query
    result <- query %>% collect()
    n_points <- nrow(result)
    print(paste("Number of points:", n_points))

    # Sample down if needed for performance
    if (n_points > 10000) {
      sample_size <- min(10000, n_points)
      print(paste("Sampling down to", sample_size, "points for performance"))
      result <- result %>% sample_n(sample_size)
    }

    toc()
    result
  })

  # Render the map
  output$map <- renderMaplibre({
    maplibre(style = carto_style("positron")) %>%
      set_view(center = c(0, 20), zoom = 1) %>%
      add_navigation_control(position = "top-left") %>%
      add_scale_control(position = "bottom-left") %>%
      add_fullscreen_control(position = "top-left")
  })

  # Update map when data changes
  observe({
    tic("Map update")
    # Get data and convert to SF
    data <- points_data()
    if (nrow(data) == 0) {
      maplibre_proxy("map") %>%
        clear_layer("points_layer")
      toc()
      return()
    }

    # Create popup content

    data_sf <- st_as_sf(data, coords = c("lng", "lat"), crs = 4326, remove = FALSE) |>
      mutate(
        popup = paste0(
          "<strong>Species:</strong> ", species, "<br>",
          "<strong>Latitude:</strong> ", round(lat, 4), "<br>",
          "<strong>Longitude:</strong> ", round(lng, 4), "<br>",
          "<strong>Altitude:</strong> ", round(altitude, 1), " m"
        )
      )

    # Define color based on display type
    color <- switch(input$displayType,
      "is_max_lat" = "#E63946", # Warm red for maximum latitude
      "is_min_lat" = "#457B9D", # Cool blue for minimum latitude
      "is_max_alt" = "#2A9D8F", # Teal for maximum altitude
      "is_min_alt" = "#9B5DE5" # Purple for minimum altitude
    )

    # Clear layers
    map_proxy <- maplibre_proxy("map") %>%
      clear_layer("points_layer")


    # Add points layer with simplified approach - no clustering
    map_proxy %>%
      add_circle_layer(
        id = "points_layer",
        source = data_sf,
        circle_color = color,
        circle_radius = 5,
        circle_opacity = 0.7,
        circle_stroke_width = 1,
        circle_stroke_color = "white",
        popup = "popup"
      )

    toc()
  })

  # Close connection when app stops
  onSessionEnded(function() {
    dbDisconnect(con, shutdown = TRUE)
  })
}

# Run the app
shinyApp(ui, server)
