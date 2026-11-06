#!/usr/bin/env Rscript
# =============================================================================
# When within the spike years did the moves actually happen?
# =============================================================================
# docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md measures move rate at
# annual resolution only -- it cannot say whether a year's elevated rate is
# concentrated in a few months or spread evenly. artifacts/nppes_subannual_
# panel.csv (33 vintages, 2007-2026, built from archives already on the
# external drive -- see extract_nppes_subannual_panel.R) and the 3 new DAC
# vintages in artifacts/physician_compare_historical_midwives.csv (2017-04,
# 2018-12, 2019-12) let that be checked directly, for the two historical
# spikes (2017-18, 2023-24) and the 2020-21 signal docs/TECHNICAL_APPENDIX_
# TRUTH_FUSION_MIGRATION.md S4 surfaced when NPPES was removed from the
# truth-fusion vote.
#
# Read-only diagnostic: prints to stdout, writes nothing tracked, same
# convention as diagnose_migration_year_over_year.R.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "migration_rate.R"))

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% distinct()

# --- NPPES sub-annual, full consecutive series -----------------------------
nppes_sub <- read_csv("artifacts/nppes_subannual_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), vintage, state = clean_state(practice_state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, vintage, state)

vintages_ordered <- sort(unique(nppes_sub$vintage))
cat(sprintf("NPPES sub-annual vintages (%d): %s\n\n", length(vintages_ordered), paste(vintages_ordered, collapse = ", ")))

rates <- compute_consecutive_rates(nppes_sub, vintages_ordered)
cat("=== NPPES move rate between EVERY consecutive sub-annual vintage pair ===\n")
print(as.data.frame(rates), row.names = FALSE)

cat("\n=== Focus: the 2017-18 spike window, sub-annual ===\n")
print(as.data.frame(rates %>% filter(period_from %in% c("2017-04", "2017-12", "2018-12") |
                                        period_to %in% c("2017-04", "2017-12", "2018-12"))), row.names = FALSE)

cat("\n=== Focus: the newly-surfaced 2020-21 window, sub-annual ===\n")
print(as.data.frame(rates %>% filter(str_starts(period_from, "2020") | str_starts(period_from, "2021") |
                                        str_starts(period_to, "2021"))), row.names = FALSE)

cat("\n=== Focus: the 2023-24 spike window, sub-annual ===\n")
print(as.data.frame(rates %>% filter(str_starts(period_from, "2023") | str_starts(period_from, "2024") |
                                        str_starts(period_to, "2024"))), row.names = FALSE)

# --- DAC, same sub-annual check for the 2017-18/2018-19 window -------------
dac_hist <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), vintage, state = clean_state(practice_state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, vintage, state)

dac_window <- sort(unique(dac_hist$vintage[dac_hist$vintage %in% c("2016-04", "2017-04", "2017-12", "2018-06", "2018-12", "2019-06", "2019-12", "2020-06")]))
cat(sprintf("\n=== DAC, independent cross-check, same window (%s) ===\n", paste(dac_window, collapse = ", ")))
dac_rates <- compute_consecutive_rates(dac_hist, dac_window)
print(as.data.frame(dac_rates), row.names = FALSE)

cat("\nDone.\n")
