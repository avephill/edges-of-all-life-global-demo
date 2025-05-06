library(shiny)
library(leaflet)
library(duckdb)
library(dplyr)
library(dbplyr)
library(shinyWidgets)
library(stringr)
library(leafgl)
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
  titlePanel("Edges of All Life"),

  # Map with controls overlay
  div(
    style = "position: relative;",
    leafletOutput("map"),

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
      pickerInput(
        inputId = "speciesFilter",
        label = "Filter by Species (optional):",
        choices = NULL
      )
    )
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

  # Get unique species list for dropdown
  tic("Species list generation")
  species_list <- minmax_tbl %>%
    select(species) %>%
    distinct() %>%
    collect() %>%
    pull(species) %>%
    sort()
  toc()

  print(paste("Total number of species:", length(species_list)))

  # Initialize with empty choices
  updatePickerInput(session, "speciesFilter",
    choices = species_list,
    selected = character(0),
    # server = TRUE,
    options = list(
      `liveSearch` = TRUE,
      `maxOptions` = 20
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
    print(paste("Number of points:", nrow(result)))
    toc()
    result
  })

  # Render the map
  output$map <- renderLeaflet({
    leaflet() %>%
      addProviderTiles("CartoDB.Positron") |>
      setView(lng = 0, lat = 20, zoom = 2)
  })

  # Update map markers when data changes
  observe({
    tic("Map update")
    data <- points_data() %>%
      st_as_sf(coords = c("lng", "lat"), crs = 4326, remove = FALSE)

    # Define color based on display type
    color <- switch(input$displayType,
      "is_max_lat" = "red",
      "is_min_lat" = "blue",
      "is_max_alt" = "green",
      "is_min_alt" = "purple"
    )

    # Create popup content
    popups <- paste0(
      "<strong>Species:</strong> ", data$species, "<br>",
      "<strong>Latitude:</strong> ", round(data$lat, 4), "<br>",
      "<strong>Longitude:</strong> ", round(data$lng, 4), "<br>",
      "<strong>Altitude:</strong> ", round(data$altitude, 1), " m<br>"
    )

    leafletProxy("map", data = data) %>%
      clearShapes() |>
      clearMarkers() |>
      # addCircleMarkers(
      #   lng = ~lng,
      #   lat = ~lat,
      #   popup = popups,
      #   radius = 5,
      #   color = color,
      #   stroke = FALSE,
      #   fillOpacity = 0.7,
      #   clusterOptions = markerClusterOptions(
      #     # only cluster until zoom 5, then show raw points
      #     disableClusteringAtZoom = 6,
      #     maxClusterRadius       = 40
      #   )
      # )
      addGlPoints(
        data = data,
        popup = popups,
        radius = 5,
        fillColor = color
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
