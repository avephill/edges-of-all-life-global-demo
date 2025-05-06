library(rsconnect)

rsconnect::deployApp(".",
  appName = "EoAL-global-demo",
  appFiles = c(
    "app.R",
    "data/shiny.duckdb"
  )
)
