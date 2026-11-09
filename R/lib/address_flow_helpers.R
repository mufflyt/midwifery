# =============================================================================
# Pure helpers for the DAC/NPPES address mismatch flow map
# =============================================================================
# No I/O, no network, no plotting -- so they can be tested on small fixtures
# without paying for tigris::states() or a Census geocoder round trip. Used
# by build_dac_nppes_address_flow_pairs.R (read_census_batch_result()) and
# make_dac_nppes_address_flow_map.R (everything else).
#
# Tested by tests/test_address_flow_helpers_saboteur.R and exercised against
# tests/mutation_catalogue.R.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(tidyr); library(readr)})
source(file.path("R", "lib", "work_site_topology.R"))  # haversine_km(lat1, lon1, lat2, lon2)

ADDRESS_PAIRS_REQUIRED_COLS <- c("npi", "year", "source", "nppes_city", "nppes_state",
                                 "nppes_lon", "nppes_lat", "comparison_city",
                                 "comparison_state", "comparison_lon", "comparison_lat")

#' Stop if address_pairs is missing any column the flow map needs
validate_address_pairs_columns <- function(address_pairs) {
  missing_cols <- setdiff(ADDRESS_PAIRS_REQUIRED_COLS, names(address_pairs))
  if (length(missing_cols) > 0) stop("Missing columns: ", paste(missing_cols, collapse = ", "))
  invisible(TRUE)
}

#' Stop if rows holds more than one record per (npi, year, source)
#'
#' The flow map draws exactly one line per midwife per source per year. A
#' silent duplicate would either double-count her in whichever flow her two
#' rows disagree on, or (if later code collapses duplicates by row order)
#' silently assign her to whichever one happened to sort first.
check_no_duplicate_rows <- function(rows) {
  dupes <- rows %>% dplyr::count(.data$npi, .data$year, .data$source) %>% dplyr::filter(.data$n > 1)
  if (nrow(dupes) > 0) stop("Duplicate NPI/year/source records -- resolve before mapping.")
  invisible(TRUE)
}

#' Keep only rows with present, plausible coordinates on both sides
valid_coordinate_rows <- function(df) {
  df %>% dplyr::filter(
    !is.na(.data$nppes_lon), !is.na(.data$nppes_lat),
    !is.na(.data$comparison_lon), !is.na(.data$comparison_lat),
    nzchar(.data$nppes_city), nzchar(.data$comparison_city),
    nzchar(.data$nppes_state), nzchar(.data$comparison_state),
    dplyr::between(.data$nppes_lon, -180, 180), dplyr::between(.data$comparison_lon, -180, 180),
    dplyr::between(.data$nppes_lat, -90, 90), dplyr::between(.data$comparison_lat, -90, 90))
}

#' Classify an NPPES/comparison address pair as the same city, a different
#' city in the same state, or a different state
#'
#' Corrects city-name SPELLING variants (SAINT PAUL vs ST PAUL, GEORGETOWN
#' vs GEORGE TOWN) using actual distance rather than city-string equality
#' alone -- found while building this map: 5.2% of string-different-city
#' pairs in this cohort geocode within 0.5 km of each other, including the
#' single largest flow in an early draft (LARGO -> UPPER MARLBORO, MD, n=8,
#' verified identical coordinates). See
#' docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md §9.
#'
#' @param same_place_km distance below which two points count as the same
#'   place regardless of city-string spelling. Default 1 km -- the same
#'   tolerance R/lib/geocode_conflicts.R uses for "same rooftop, different
#'   precision".
#' @return character vector, same length as the inputs.
classify_mismatch <- function(nppes_lat, nppes_lon, nppes_city, nppes_state,
                              comparison_lat, comparison_lon, comparison_city, comparison_state,
                              same_place_km = 1) {
  dist_km <- haversine_km(nppes_lat, nppes_lon, comparison_lat, comparison_lon)
  dplyr::case_when(
    dist_km < same_place_km ~ "Same city",
    nppes_state != comparison_state ~ "Different state",
    nppes_city != comparison_city ~ "Different city, same state",
    TRUE ~ "Same city"
  )
}

#' Collapse individual mismatches into city-to-city flows, applying the
#' min_flow_n disclosure control
#'
#' A flow of n=1 would name one specific midwife's two addresses on a
#' public map. min_flow_n is a privacy control, not only a legibility one
#' -- see docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md §9.
#' Origin/destination use the MEDIAN of the group's coordinates, not the
#' mean, so one outlier geocode inside an otherwise-tight cluster cannot
#' drag a flow's displayed position toward it.
#'
#' @return list(all = every city-to-city flow, displayed = only flows with
#'   n_midwives >= min_flow_n).
aggregate_flows <- function(mismatches, min_flow_n) {
  flow_pairs <- mismatches %>%
    dplyr::group_by(.data$source, .data$nppes_state, .data$nppes_city,
                    .data$comparison_state, .data$comparison_city, .data$mismatch_type) %>%
    dplyr::summarise(n_midwives = dplyr::n_distinct(.data$npi),
                     origin_lon = stats::median(.data$nppes_lon), origin_lat = stats::median(.data$nppes_lat),
                     destination_lon = stats::median(.data$comparison_lon), destination_lat = stats::median(.data$comparison_lat),
                     .groups = "drop")
  list(all = flow_pairs, displayed = dplyr::filter(flow_pairs, .data$n_midwives >= min_flow_n))
}

#' Parse one Census Bureau batch-geocoder result file
#'
#' No header; columns are ID, input_address, match_status, match_type,
#' matched_address, "lon,lat", tiger_line_id, side. Keeps ONLY rows CMS
#' marked "Match" -- a No_Match or Tie row carries no usable coordinate, and
#' including one would join a midwife to a phantom location (NA lon/lat, or
#' worse, a stale value left over from a prior row if the caller isn't
#' careful). The coords field unpacks to (lon, lat) in THAT order -- the
#' order the Census API actually returns, not alphabetical.
read_census_batch_result <- function(path) {
  stopifnot(file.exists(path))
  d <- readr::read_csv(path, col_names = c("id", "input_address", "match_status", "match_type",
                                           "matched_address", "coords", "tiger_line_id", "side"),
                       col_types = readr::cols(.default = "c"), progress = FALSE)
  d <- dplyr::filter(d, .data$match_status == "Match")
  d <- tidyr::separate(d, .data$coords, into = c("lon", "lat"), sep = ",", convert = TRUE)
  dplyr::transmute(d, npi = .data$id, lon = .data$lon, lat = .data$lat)
}
