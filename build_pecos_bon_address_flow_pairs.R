#!/usr/bin/env Rscript
# =============================================================================
# Build the PECOS/DAC-vs-BON address_pairs table for the mismatch flow map
# =============================================================================
# Sibling of build_dac_nppes_address_flow_pairs.R, for compare_pecos_to_bon_
# address.R's data instead of NPPES. CT is the only state included: CO was
# removed from that comparison entirely (2026-10-23, its field is a MAILING
# address, not a practice address -- see compare_pecos_to_bon_address.R's
# own header), and IL (n=1) and DE (n=0) are excluded here, same MIN_N=5 cut
# the address-agreement heatmap applies.
#
# ZIP5-CENTROID, NOT STREET-LEVEL. The DAC/NPPES map geocodes full street
# addresses via the Census batch geocoder. State BON data here only carries
# city/state/zip (CO's mail_zip, CT's zip) -- no street address at all -- so
# a street-level geocode isn't possible for the BON side. Rather than mix
# precision (street-level DAC against zip5-centroid BON), BOTH sides are
# geocoded to their ZIP5 centroid via data/us_zip_centroids.csv (gitignored
# reference file, zip/latitude/longitude), so the map compares like with
# like. This makes flows coarser than the DAC/NPPES map's (a flow here can
# connect two points that share a ZIP5 but sit at different street
# addresses) -- acceptable given BON's own data ceiling, not a shortcut
# taken where a better option existed.
#
# Columns are named nppes_*/comparison_* to match address_flow_helpers.R's
# fixed schema (ADDRESS_PAIRS_REQUIRED_COLS) -- nppes_* here holds PECOS/DAC
# (the fixed baseline, playing the same structural role NPPES plays in the
# original map), comparison_* holds BON. Reusing the existing, already
# mutation-tested helpers as-is beats forking them for a new column-name
# scheme.
#
# Inputs : dac_midwives.csv (person-level, gitignored; extract_dac_midwives.R)
#          artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv
#          data/us_zip_centroids.csv (gitignored reference; zip,latitude,longitude)
# Output : artifacts/pecos_vs_bon_address_pairs.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(cli)})
source(file.path("R", "lib", "address_flow_helpers.R"))
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

OUT <- "artifacts/pecos_vs_bon_address_pairs.csv"
ZIP_CENTROIDS <- "data/us_zip_centroids.csv"

stopifnot(file.exists("dac_midwives.csv"), file.exists(ZIP_CENTROIDS))

centroids <- read_csv(ZIP_CENTROIDS, col_types = cols(zip = "c", latitude = "d", longitude = "d"),
                      progress = FALSE)
centroids <- assert_unique_keys(centroids, "zip", label = ZIP_CENTROIDS, dedupe = TRUE)

BON_STATES <- list(
  list(path = "artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv",
       city = "live_bon_city", state = "live_bon_state", zip = "live_bon_zip")
)
BON_PATHS <- vapply(BON_STATES, `[[`, character(1), "path")
stopifnot(all(file.exists(BON_PATHS)))

dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, nppes_city = str_to_upper(str_squish(practice_city)),
            nppes_state = str_to_upper(str_squish(practice_state)),
            zip5 = str_sub(practice_zip, 1, 5)) %>%
  inner_join(centroids, by = c("zip5" = "zip")) %>%
  rename(nppes_lon = longitude, nppes_lat = latitude) %>%
  select(-zip5)
dac <- assert_unique_keys(dac, "npi", label = "dac_midwives.csv", dedupe = TRUE)

bon <- bind_rows(lapply(BON_STATES, function(spec) {
  read_csv(spec$path, col_types = cols(.default = "c"), progress = FALSE) %>%
    filter(live_bon_match_status == "VERIFIED_LIVE_BON", nzchar(npi)) %>%
    transmute(npi, comparison_city = str_to_upper(str_squish(.data[[spec$city]])),
              comparison_state = str_to_upper(str_squish(.data[[spec$state]])),
              zip5 = str_sub(.data[[spec$zip]], 1, 5))
})) %>%
  inner_join(centroids, by = c("zip5" = "zip")) %>%
  rename(comparison_lon = longitude, comparison_lat = latitude) %>%
  select(-zip5)
bon <- assert_unique_keys(bon, "npi", label = "CT BON", dedupe = TRUE)

pairs <- inner_join(dac, bon, by = "npi") %>%
  mutate(year = 2026L, source = "BON") %>%
  select(npi, year, source, nppes_city, nppes_state, nppes_lon, nppes_lat,
         comparison_city, comparison_state, comparison_lon, comparison_lat)

cli_alert_info("NPIs with both sides zip5-geocoded: {nrow(pairs)}")
write_csv(pairs, OUT)
cli_alert_success("wrote {OUT}")
