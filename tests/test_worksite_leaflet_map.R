#!/usr/bin/env Rscript

path <- "qa/leaflet_work_sites_INTERNAL.html"
stopifnot(file.exists(path))
info <- file.info(path)
stopifnot(is.finite(info$size), info$size > 100000)
html <- paste(readLines(path, warn = FALSE), collapse = "\n")
map_script <- paste(readLines("build_worksite_leaflet_map.R", warn = FALSE), collapse = "\n")
stopifnot(grepl("Midwifery work sites", html, fixed = TRUE))
stopifnot(grepl("associated midwives", html, fixed = TRUE))
stopifnot(grepl("NPPES Type-2 organization", html, fixed = TRUE))
stopifnot(grepl("Facility setting crosswalk", html, fixed = TRUE))
stopifnot(grepl("paste0(\"Facility setting crosswalk: \"", map_script, fixed = TRUE))
stopifnot(grepl("esc(setting_source)", map_script, fixed = TRUE))
stopifnot(!grepl('"method":"addTiles"', html, fixed = TRUE))
stopifnot(grepl("server.arcgisonline.com/ArcGIS/rest/services", html, fixed = TRUE))
stopifnot(!grepl("CartoDB.Voyager", html, fixed = TRUE))
cat("OK: internal work-site Leaflet map exists and contains site popup content\n")
