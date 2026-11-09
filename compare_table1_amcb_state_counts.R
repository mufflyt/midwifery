#!/usr/bin/env Rscript
# =============================================================================
# This project's state distribution vs. AMCB's own published state counts
# =============================================================================
# AMCB publishes its own "Number of CNM & CM by State" sheet -- an exact,
# authoritative count unrelated to NPPES, this project's linkage, or any
# federal source. Compared against this project's own NPPES-derived
# practice-state distribution (artifacts/amcb_npi_geography_by_state.csv,
# linkage_tier == "primary_midwifery", every status), it is a real external
# check on the linkage, not another internal cross-reference.
#
# AMCB_STATE_COUNTS below is manually transcribed, not scraped -- AMCB
# publishes this as a PDF, not structured data. Source: "Number of CNM & CM
# by State" (As of: August 2026), fetched 2026-11-05 from
# https://www.amcbmidwife.org/docs/default-source/default-document-library/number-of-cnm-cm-by-state---aug-2026.pdf
# Total stated on that document: 15,322 active midwives (144 CM) across 50
# states + DC + 5 territories + 3 military "states"; only the 50 states + DC
# are compared here -- territories and military addresses have no NPPES
# practice-state equivalent to compare against.
#
# See docs/TECHNICAL_APPENDIX_AMCB_DEMOGRAPHIC_COMPARISON.md for the full
# comparison and discussion; this script produces only its state-level table.
#
# Inputs : artifacts/amcb_npi_geography_by_state.csv
# Outputs: artifacts/table1_amcb_state_comparison.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("R/lib/artifact_provenance.R")

AMCB_STATE_COUNTS <- tibble::tribble(
  ~state, ~amcb_aug2026,
  "AL",  76, "AK", 106, "AZ", 300, "AR",  57, "CA", 1299,
  "CO", 496, "CT", 245, "DE",  52, "FL",  961, "GA",  645,
  "HI",  60, "ID",  96, "IL", 551, "IN",  233, "IA",  142,
  "KS", 101, "KY", 150, "LA",  90, "ME",  121, "MD",  363,
  "MA", 474, "MI", 559, "MN", 449, "MS",   45, "MO",  155,
  "MT",  68, "NE",  64, "NV",  70, "NH",  131, "NJ",  357,
  "NM", 207, "NY",1104, "NC", 641, "ND",   22, "OH",  535,
  "OK",  86, "OR", 415, "PA", 593, "RI",   86, "SC",  162,
  "SD",  46, "TN", 376, "TX", 678, "UT",  225, "VT",   94,
  "VA", 444, "WA", 558, "WV",  74, "WI",  299, "WY",   22,
  "DC",  55)
stopifnot(sum(AMCB_STATE_COUNTS$amcb_aug2026) == 15238L)  # 50 states + DC; excludes territories/military

geo_path <- "artifacts/amcb_npi_geography_by_state.csv"
ours <- read_csv(geo_path, show_col_types = FALSE, progress = FALSE) %>%
  filter(linkage_tier == "primary_midwifery") %>%
  transmute(state = nppes_state, ours_primary_midwifery = n)

cmp <- AMCB_STATE_COUNTS %>%
  left_join(ours, by = "state") %>%
  mutate(
    ours_primary_midwifery = coalesce(ours_primary_midwifery, 0L),
    diff = ours_primary_midwifery - amcb_aug2026,
    pct_diff = round(100 * diff / amcb_aug2026, 1)) %>%
  arrange(desc(amcb_aug2026))

write_with_provenance(cmp, "artifacts/table1_amcb_state_comparison.csv", inputs = geo_path)
cat(sprintf(
  "AMCB (50 states + DC): %s | this project (primary_midwifery): %s | diff: %+d (%.1f%%)\n",
  format(sum(cmp$amcb_aug2026), big.mark = ","),
  format(sum(cmp$ours_primary_midwifery), big.mark = ","),
  sum(cmp$ours_primary_midwifery) - sum(cmp$amcb_aug2026),
  100 * (sum(cmp$ours_primary_midwifery) - sum(cmp$amcb_aug2026)) / sum(cmp$amcb_aug2026)))
cat("written: artifacts/table1_amcb_state_comparison.csv\n")
