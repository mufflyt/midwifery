#!/usr/bin/env Rscript
#' @title Step 14: Fallback geocoding for OB hospitals the Census API missed
#'
#' @description
#' Runs the isochrones fallback chain (`geocode_with_fallbacks()`) on the
#' hospitals that the Census batch geocoder could not match, and merges the
#' results back into `artifacts/ob_hospitals_geocoded.csv`.
#'
#' @section Precision is recorded, because the fallbacks are not equivalent:
#' The chain degrades: Census one-line, then ArcGIS, then Nominatim, then a
#' CITY CENTROID. A city centroid is not the hospital -- in a large county it
#' can be tens of kilometres from the building, which for a drive-time analysis
#' is the difference between "within 30 minutes" and not.
#'
#' Every fallback result therefore keeps its `match_type` and provenance, and
#' `coord_precision` marks centroid-level rows explicitly. A downstream travel
#' time computed from a centroid is a statement about a town, not a hospital,
#' and must be able to say so.
#'
#' @section Rate limits:
#' Nominatim's usage policy is one request per second, and ArcGIS throttles
#' too. This runs sequentially with the chain's own pacing rather than in
#' parallel; a few hundred addresses take minutes, which is the correct trade
#' against being blocked.
#'
#' Output : artifacts/ob_hospitals_geocoded.csv (updated in place)
#'          artifacts/ob_hospitals_fallback_log.csv
#'
#' @family step-functions
#' @concept county-profiles
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(cli); library(jsonlite)
})

# CYCLE 21b. Inputs recorded beside every artifact this script writes, so a
# reader can tell whether the numbers were built from the bytes still on disk.
source(file.path("R", "lib", "artifact_provenance.R"))

# Helpers shared with the other numbered scripts. Defined once: these were
# duplicated across files sourced into one environment, where load order
# decided which definition won.
source(file.path("R", "lib", "common_helpers.R"))


source(file.path("R", "lib", "isochrones_dep.R"))
ISO <- isochrones_home()
GEO <- file.path("artifacts", "ob_hospitals_geocoded.csv")
LOG <- file.path("artifacts", "ob_hospitals_fallback_log.csv")


run_fallbacks <- function() {
  stopifnot(file.exists(GEO))
  with_iso_wd(suppressWarnings(suppressMessages({
    source(file.path(ISO, "R", "geocode_cache_utils.R"))
    source(file.path(ISO, "R", "census_geocode_enhanced.R"))
  })))
  if (!exists("geocode_with_fallbacks", mode = "function")) {
    stop("geocode_with_fallbacks() unavailable from ", ISO, call. = FALSE)
  }
  cli::cli_alert_success("fallback chain loaded (Census one-line -> ArcGIS -> Nominatim -> city centroid)")

  d <- read_csv(GEO, show_col_types = FALSE, progress = FALSE) %>%
    # IDEMPOTENCE: strip any columns a previous run of this script left behind.
    # Without this the re-join produces fb_match_type.x / .y and the merge dies
    # on "object 'fb_match_type' not found" -- after the API calls have already
    # been paid for.
    select(-any_of(c("fb_match_type", "fb_source", "coord_precision")))
  todo <- d %>% filter(is.na(latitude) | is.na(longitude))
  cli::cli_alert_info("hospitals without coordinates: {nrow(todo)} of {nrow(d)}")
  if (nrow(todo) == 0) { cli::cli_alert_success("nothing to do"); return(invisible(d)) }

  # Reuse a completed log rather than re-querying. The log is written BEFORE
  # the merge precisely so a merge failure never costs another few hundred
  # rate-limited API calls.
  if (file.exists(LOG)) {
    prev <- read_csv(LOG, show_col_types = FALSE, progress = FALSE)
    if (all(todo$prvdr_num %in% prev$prvdr_num)) {
      cli::cli_alert_info("reusing {nrow(prev)} results from {LOG} (no API calls)")
      return(merge_fallbacks(d, prev %>% filter(prvdr_num %in% todo$prvdr_num)))
    }
  }

  res <- vector("list", nrow(todo))
  for (i in seq_len(nrow(todo))) {
    r <- todo[i, ]
    out <- tryCatch(
      with_iso_wd(geocode_with_fallbacks(r$geocode_address_1, r$geocode_city,
                                         r$geocode_state, r$geocode_zip)),
      error = function(e) NULL)
    # BOTH coordinate names, defensively. geocode_with_fallbacks() returns
    # lat/lon while the cache returns latitude/longitude -- the same silent
    # mismatch fixed upstream in isochrones PR #522. Reading only `latitude`
    # here reported "fallback resolved 0 of 366" on a run where ArcGIS was
    # returning rooftop matches. Until #522 merges, read both.
    pick <- function(o, ...) {
      for (nm in c(...)) if (!is.null(o) && !is.null(o[[nm]])) return(o[[nm]])
      NULL
    }
    res[[i]] <- tibble(
      prvdr_num = r$prvdr_num,
      fb_lat  = pick(out, "latitude", "lat")  %|na|% NA_real_,
      fb_lon  = pick(out, "longitude", "lon") %|na|% NA_real_,
      fb_match_type = as.character(pick(out, "match_type") %|na|% NA_character_),
      fb_source     = as.character(pick(out, "geocode_source") %|na|% NA_character_),
      fb_provenance = as.character(pick(out, "geocoder_provenance") %|na|% NA_character_))
    if (i %% 50 == 0) cli::cli_alert_info("  {i}/{nrow(todo)}")
  }
  fb <- bind_rows(res)
  write_with_provenance(fb, LOG, na = "", inputs = prov_inputs(file.path("artifacts", "ob_hospitals_geocoded.csv"), file.path("artifacts", "ob_hospitals_fallback_log.csv")))
  merge_fallbacks(d, fb)
}

#' Merge fallback results into the geocoded table
#' @keywords internal
#' @noRd
merge_fallbacks <- function(d, fb) {
  n_new <- sum(!is.na(fb$fb_lat))
  cli::cli_alert_info("fallback resolved {n_new} of {nrow(fb)}")

  merged <- d %>%
    # one fallback record per provider number
    left_join(fb, by = "prvdr_num", relationship = "many-to-one") %>%
    mutate(
      # A centroid is a town, not a hospital. Recorded, never smoothed over.
      coord_precision = case_when(
        !is.na(latitude) & source == "cache"    ~ "cache",
        !is.na(latitude) & source == "geocoded" ~ "census_batch",
        !is.na(fb_lat) & grepl("centroid", fb_match_type, ignore.case = TRUE) ~ "city_centroid",
        !is.na(fb_lat)                          ~ "fallback_address",
        TRUE                                    ~ "unresolved"),
      latitude  = coalesce(latitude, fb_lat),
      longitude = coalesce(longitude, fb_lon),
      geocoder_provenance = coalesce(geocoder_provenance, fb_provenance)) %>%
    select(-fb_lat, -fb_lon, -fb_provenance)

  stopifnot(nrow(merged) == nrow(d))
  n_coord <- sum(!is.na(merged$latitude))
  cli::cli_alert_success("with coordinates: {n_coord} of {nrow(merged)} ({round(100*n_coord/nrow(merged),1)}%)")
  print(as.data.frame(count(merged, coord_precision, sort = TRUE)), row.names = FALSE)

  write_with_provenance(merged, GEO, na = "", inputs = prov_inputs(file.path("artifacts", "ob_hospitals_geocoded.csv"), file.path("artifacts", "ob_hospitals_fallback_log.csv")))
  invisible(merged)
}

if (identical(environment(), globalenv()) && !interactive()) run_fallbacks()
