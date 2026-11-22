#!/usr/bin/env Rscript
#' @title County FIPS from coordinates, by point-in-polygon
#'
#' @description
#' The fallback both geocoders reach for when tract boundaries are
#' unavailable: assign each row the county whose TIGER polygon contains its
#' point. County only; the tract stays `NA`, because a county polygon cannot
#' answer a tract question.
#'
#' @section Why it is here:
#' `geocode_midwives.R` and `geocode_panel_addresses.R` each carried this
#' function, byte-identical, 21 lines apiece. The copies had not drifted yet.
#' `tools/measure_code_complexity.R` pass 3 found them; consolidating before
#' they disagree is the only moment when the move costs nothing. Two scripts
#' is the threshold for a shared file at this size: a 21-line body is worth
#' more than the `source()` line each caller pays.
#'
#' @section Loading sf and tigris lazily:
#' The libraries load inside the function, not at file scope, and that is
#' deliberate. Both callers run in environments where the spatial stack may be
#' absent, and the fallback only fires when the tract path has already failed.
#' A file-scope `library(sf)` would make every caller pay for a path most runs
#' never take.

#' @param df [data.frame] rows carrying numeric `latitude` and `longitude`.
#'   Rows with either missing are skipped and return `NA`.
#' @return [character] county GEOID per row, `NA` where the point is missing
#'   or falls inside no county polygon.
assign_county_from_points <- function(df) {
  ok <- !is.na(df$latitude) & !is.na(df$longitude)
  out <- rep(NA_character_, nrow(df))
  if (!any(ok)) return(out)

  suppressPackageStartupMessages({ library(sf); library(tigris) })
  options(tigris_use_cache = TRUE)

  counties <- tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE) %>%
    sf::st_transform(4326)
  pts <- sf::st_as_sf(df[ok, c("longitude", "latitude")],
                      coords = c("longitude", "latitude"), crs = 4326)
  idx <- sf::st_within(pts, sf::st_geometry(counties))
  first <- vapply(idx, function(i) if (length(i)) i[1] else NA_integer_, integer(1))
  out[ok] <- counties$GEOID[first]
  out
}
