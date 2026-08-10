#' @title Coordinate plausibility, with territories treated as real places
#'
#' @description
#' CYCLE 11. Nothing in this repo validated coordinate RANGES. A swapped
#' lon/lat pair -- `st_as_sf(coords = c("longitude", "latitude"))` is
#' order-sensitive -- produces a valid point in the Indian Ocean rather than an
#' error, and the point-in-polygon assignment then reports it as simply "not in
#' a district", indistinguishable from a legitimate miss.
#'
#' @section Why this is not a CONUS box:
#' The obvious check is "longitude must be negative". Applying it to
#' `artifacts/ob_hospitals_geocoded.csv` flags **three real hospitals**: one in
#' American Samoa (-14.3, -171) and two in Guam and the Northern Marianas
#' (13.5, 145) and (15.2, 146). Positive longitude is correct for the western
#' Pacific territories, and a naive sign test would delete obstetric capacity
#' from exactly the places least able to spare it.
#'
#' So this classifies rather than rejects: `conus`, `noncontiguous` (AK, HI),
#' `territory`, or `implausible`. Only the last is an error, and territories
#' stay visible instead of being silently absorbed into a "bad data" bucket.
#'
#' @family spatial-contracts

#' Classify a coordinate pair
#'
#' @param lon,lat [numeric]: decimal degrees.
#' @return [character] one of "conus", "noncontiguous", "territory",
#'   "implausible", or NA where either coordinate is missing.
classify_coordinate <- function(lon, lat) {
  lon <- suppressWarnings(as.numeric(lon))
  lat <- suppressWarnings(as.numeric(lat))
  out <- rep(NA_character_, length(lon))
  have <- !is.na(lon) & !is.na(lat) & is.finite(lon) & is.finite(lat)

  conus <- have & lon >= -125 & lon <= -66 & lat >= 24 & lat <= 50
  ak    <- have & lon >= -180 & lon <= -129 & lat >= 51 & lat <= 72
  hi    <- have & lon >= -161 & lon <= -154 & lat >= 18 & lat <= 23
  # PR/USVI to the east; AS to the south; GU/MP across the antimeridian.
  pr    <- have & lon >= -68  & lon <= -64  & lat >= 17 & lat <= 19
  as_   <- have & lon >= -171 & lon <= -168 & lat >= -15 & lat <= -13
  gu    <- have & lon >= 144  & lon <= 147  & lat >= 13 & lat <= 21

  out[have] <- "implausible"
  out[conus] <- "conus"
  out[ak | hi] <- "noncontiguous"
  out[pr | as_ | gu] <- "territory"
  out
}
