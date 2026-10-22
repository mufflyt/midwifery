#!/usr/bin/env Rscript
# =============================================================================
# Build the DAC-vs-NPPES address_pairs table for the mismatch flow map
# =============================================================================
# Joins Census-geocoded DAC and NPPES-2026 coordinates back onto their city/
# state, for the NPIs both sources share -- the input
# make_dac_nppes_address_flow_map.R needs. Person-level (exact coordinate
# tied to an NPI), so this writes a gitignored file, not a tracked artifact;
# only the flow map's own aggregated output is tracked.
#
# Scope: DAC vs NPPES, 2026 only (DAC has no other vintage -- same reason the
# comparison appendix never built DAC-vs-Open-Payments). An Open-Payments
# panel can be added once this one is validated; geocoding that adds three
# more years of Open Payments addresses plus the matching NPPES snapshots,
# roughly 25,000-30,000 more addresses -- deliberately not done here.
#
# Inputs : artifacts/flowmap_geocoding/dac_batch_input.csv       (Census batch format, gitignored)
#          artifacts/flowmap_geocoding/dac_geocoded_raw.csv      (Census batch geocoder output, gitignored)
#          artifacts/flowmap_geocoding/nppes2026_batch_input.csv (gitignored)
#          artifacts/flowmap_geocoding/nppes2026_geocoded_raw.csv (gitignored)
#          dac_midwives.csv, midwife_panel.csv                   (person-level, gitignored)
# Output : artifacts/dac_vs_nppes_address_pairs.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr); library(cli)})
source(file.path("R", "lib", "address_flow_helpers.R"))  # read_census_batch_result()
source(file.path("R", "join_safety.R"))  # assert_unique_keys(dedupe = TRUE)

GEOCODE_DIR <- "artifacts/flowmap_geocoding"
OUT <- "artifacts/dac_vs_nppes_address_pairs.csv"

dac_geo <- read_census_batch_result(file.path(GEOCODE_DIR, "dac_geocoded_raw.csv"))
nppes_geo <- read_census_batch_result(file.path(GEOCODE_DIR, "nppes2026_geocoded_raw.csv"))
cli_alert_info("DAC geocoded: {nrow(dac_geo)} / {length(readLines(file.path(GEOCODE_DIR, 'dac_batch_input.csv')))} submitted")
cli_alert_info("NPPES-2026 geocoded: {nrow(nppes_geo)} / {length(readLines(file.path(GEOCODE_DIR, 'nppes2026_batch_input.csv')))} submitted")

dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi, comparison_city = str_to_upper(str_squish(practice_city)),
            comparison_state = str_to_upper(str_squish(practice_state))) %>%
  inner_join(dac_geo, by = "npi") %>%
  rename(comparison_lon = lon, comparison_lat = lat)

nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(snapshot_year == "2026", npi %in% dac$npi)
nppes <- assert_unique_keys(nppes, "npi", label = "midwife_panel.csv (2026)", dedupe = TRUE) %>%
  transmute(npi, nppes_city = str_to_upper(str_squish(practice_city)),
            nppes_state = str_to_upper(str_squish(practice_state))) %>%
  inner_join(nppes_geo, by = "npi") %>%
  rename(nppes_lon = lon, nppes_lat = lat)

pairs <- inner_join(nppes, dac, by = "npi") %>%
  mutate(year = 2026L, source = "DAC") %>%
  select(npi, year, source, nppes_city, nppes_state, nppes_lon, nppes_lat,
         comparison_city, comparison_state, comparison_lon, comparison_lat)

cli_alert_info("NPIs with both sides geocoded: {nrow(pairs)}")
write_csv(pairs, OUT)
cli_alert_success("wrote {OUT}")
