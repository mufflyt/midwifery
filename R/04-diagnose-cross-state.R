#!/usr/bin/env Rscript
#' @title Step 04: Cross-State Discordance Diagnosis
#'
#' @description
#' Stage 3 validation found 156 records where the coordinate-derived county and
#' the unique-ZIP county disagree, and 104 of those disagree by STATE. A ZIP can
#' straddle a county line; it cannot straddle Alabama and California. So this is
#' not a fallback-precision question — for those records the two sources
#' describe different places, and one of them is wrong about a person.
#'
#' 148 of the 156 come from the `exact_key` geocode tier, so the cache is
#' scrutinised BEFORE the ZIP fallback is blamed. `exact_key` only implies
#' confidence if the key is genuinely unique and refers to the same address
#' record.
#'
#' @section Method — three independent witnesses:
#' For every discordance, compare the state implied by each of:
#' \enumerate{
#'   \item the raw address text NPPES supplied,
#'   \item the ZIP Stage 3 used,
#'   \item the coordinates, assigned FRESH to a current county layer.
#' }
#'
#' The coordinate state is recomputed by point-in-polygon here and every cached
#' county/FIPS field is ignored, because a cached FIPS is the very thing under
#' suspicion — reusing it would let the suspect testify about itself.
#'
#' Partition:
#' \itemize{
#'   \item address + ZIP agree, coordinate differs -> geocoding/cache linkage
#'   \item address + coordinate agree, ZIP differs -> wrong/stale ZIP joined on
#'   \item ZIP + coordinate agree, address differs -> address field/version
#'   \item all three differ -> person-level linkage or row alignment
#' }
#'
#' Output : artifacts/cross_state_diagnosis.csv,
#'          artifacts/cross_state_partition.csv
#'
#' @family step-functions
#' @concept validation
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(cli)
  library(sf); library(tigris)
})
options(tigris_use_cache = TRUE)

ART <- "artifacts"

#' Assign points to current counties, ignoring every cached FIPS field
#'
#' @param df [data.frame]: rows with latitude/longitude.
#' @return [character] county GEOID per row, NA where no polygon contains it.
#' @keywords internal
#' @noRd
fresh_county <- function(df) {
  ok <- !is.na(df$latitude) & !is.na(df$longitude)
  out <- rep(NA_character_, nrow(df))
  if (!any(ok)) return(out)
  cty <- tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE) %>%
    sf::st_transform(4326)
  pts <- sf::st_as_sf(df[ok, c("longitude", "latitude")],
                      coords = c("longitude", "latitude"), crs = 4326)
  idx <- sf::st_within(pts, sf::st_geometry(cty))
  first <- vapply(idx, function(i) if (length(i)) i[1] else NA_integer_, integer(1))
  out[ok] <- cty$GEOID[first]
  out
}

diagnose <- function() {
  geo <- read_csv("midwives_geography.csv", show_col_types = FALSE,
                  col_types = cols(.default = col_character())) %>%
    mutate(latitude = as.numeric(latitude), longitude = as.numeric(longitude))
  disc <- read_csv(file.path(ART, "zip_fallback_discordant.csv"),
                   show_col_types = FALSE, col_types = cols(.default = "c"))

  # Raw address text as NPPES supplied it, straight from the matcher output.
  src <- read_csv("midwives_with_nppes.csv", show_col_types = FALSE,
                  col_types = cols(.default = col_character())) %>%
    select(certification_number, practice_address, practice_city,
           practice_state, practice_zip, npi,
           any_of(c("match_tier", "match_stage", "match_score",
                    "match_resolution", "match_status"))) %>%
    distinct(certification_number, .keep_all = TRUE)

  d <- disc %>%
    select(certification_number, GEOID_coord, GEOID_unique) %>%
    left_join(select(geo, certification_number, latitude, longitude,
                     geocode_match, quality_score), by = "certification_number") %>%
    left_join(src, by = "certification_number")

  cli::cli_alert_info("Re-deriving county from coordinates (cached FIPS ignored)...")
  d$GEOID_fresh <- fresh_county(d)

  st <- function(x) substr(x, 1, 2)
  # Address state is the two-letter code; convert via the fresh county layer's
  # own state lookup so all three witnesses speak the same language.
  fips_lu <- tigris::fips_codes %>% distinct(state, state_code)

  d <- d %>%
    left_join(fips_lu, by = c("practice_state" = "state")) %>%
    mutate(
      st_address = state_code,
      st_zip     = st(GEOID_unique),
      st_coord   = st(GEOID_fresh),
      # A cached county whose state disagrees with a fresh recomputation from
      # the same coordinates means the cached FIPS itself is wrong.
      cached_vs_fresh = if_else(is.na(GEOID_coord) | is.na(GEOID_fresh),
                                NA_character_,
                                if_else(GEOID_coord == GEOID_fresh,
                                        "cache_ok", "CACHE_WRONG")),
      partition = case_when(
        is.na(st_address) | is.na(st_zip) | is.na(st_coord) ~ "incomplete_evidence",
        st_address == st_zip & st_address != st_coord ~ "coordinate_is_wrong",
        st_address == st_coord & st_address != st_zip ~ "zip_is_wrong",
        st_zip == st_coord & st_address != st_zip     ~ "address_is_wrong",
        st_address != st_zip & st_address != st_coord & st_zip != st_coord ~ "all_three_differ",
        TRUE ~ "states_agree_county_differs"))

  cli::cli_h2("Three-way state comparison ({nrow(d)} discordances)")
  part <- d %>% count(partition, sort = TRUE, name = "n") %>%
    mutate(pct = round(100 * n / sum(n), 1))
  print(as.data.frame(part), row.names = FALSE)

  cli::cli_h3("Cached county vs fresh recomputation from the SAME coordinates")
  print(as.data.frame(count(d, cached_vs_fresh, name = "n")), row.names = FALSE)

  if ("geocode_match" %in% names(d)) {
    cli::cli_h3("By geocode tier")
    print(as.data.frame(count(d, geocode_match, partition, sort = TRUE, name = "n")),
          row.names = FALSE)
  }

  write_csv(d, file.path(ART, "cross_state_diagnosis.csv"), na = "")
  write_csv(part, file.path(ART, "cross_state_partition.csv"))
  cli::cli_alert_success("artifacts/cross_state_diagnosis.csv written")
  invisible(d)
}

if (identical(environment(), globalenv()) && !interactive()) diagnose()
