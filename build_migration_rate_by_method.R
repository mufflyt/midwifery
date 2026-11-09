#!/usr/bin/env Rscript
# =============================================================================
# Year-over-year migration rate, NPPES-alone vs. every available truth-
# fusion method, same eligibility criteria throughout
# =============================================================================
# The scientific question this answers: do the 2017->2018 and 2023->2024
# move-rate spikes (docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md)
# survive when the "state" used for each NPI-year comes from a multi-
# source truth-fusion estimate instead of raw NPPES alone -- or are they
# an artifact of trusting a single administrative source?
#
# Same "valid pair" / move-rate definition docs/TECHNICAL_APPENDIX_
# MIGRATION_YEAR_OVER_YEAR.md and audit_migration_corroboration_by_
# transition.R already use (a transition counts only where BOTH years have
# a known value), applied per method: a fusion method's own abstentions
# count as "not known" for that NPI-year, same as NPPES itself having no
# snapshot that year -- never backfilled from NPPES or any other method,
# since that would quietly change what each method's own denominator means.
#
# Reads every artifacts/truth_fusion_predictions_<method>.csv
# build_truth_fusion_predictions.R already wrote (run it, both backend
# passes, first) plus raw NPPES as the "nppes_raw" baseline method.
#
# Input : artifacts/truth_fusion_predictions_*.csv, midwife_panel.csv,
#         artifacts/amcb_npi_linkage_FROZEN.csv
# Output: artifacts/migration_rate_by_method.csv (tracked, aggregate)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr)})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "migration_rate.R"))

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)

pred_files <- Sys.glob("artifacts/truth_fusion_predictions_*.csv")
if (length(pred_files) == 0)
  stop("No artifacts/truth_fusion_predictions_*.csv found -- run build_truth_fusion_predictions.R (both backend passes) first.", call. = FALSE)

method_states <- list(nppes_raw = nppes %>% transmute(npi, year, state))
for (f in pred_files) {
  m <- sub("^truth_fusion_predictions_(.*)\\.csv$", "\\1", basename(f))
  d <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    mutate(year = as.integer(year), abstained = as.logical(abstained)) %>%
    filter(!abstained, !is.na(predicted_value)) %>%
    transmute(npi, year, state = predicted_value)
  method_states[[m]] <- d
}
cat(sprintf("Methods scored: %s\n", paste(names(method_states), collapse = ", ")))

YEARS <- 2013:2026
rates <- bind_rows(lapply(names(method_states), function(m)
  compute_migration_rates(method_states[[m]], YEARS) %>% mutate(method = m, .before = 1))) %>%
  mutate(is_spike_transition = (year_from == 2017 & year_to == 2018) | (year_from == 2023 & year_to == 2024))

write_with_provenance(rates, "artifacts/migration_rate_by_method.csv", inputs = c(pred_files, "midwife_panel.csv"))
cat(sprintf("\n-> artifacts/migration_rate_by_method.csv (%d rows)\n", nrow(rates)))

cat("\n=== Does each spike transition remain in the TOP 2 highest-rate transitions, per method? ===\n")
rank_check <- rates %>% group_by(method) %>%
  mutate(rank_desc = rank(-pct_moved, ties.method = "min")) %>%
  filter(is_spike_transition) %>%
  summarise(spike_transitions = paste(sprintf("%d->%d (rank %d of %d, %.2f%%)", year_from, year_to, rank_desc, n(), pct_moved), collapse = "; "),
            .groups = "drop")
print(as.data.frame(rank_check), right = FALSE)

cat("\n=== Spike mean pct_moved vs. every other transition's mean, per method ===\n")
spike_vs_other <- rates %>% group_by(method, is_spike_transition) %>%
  summarise(mean_pct_moved = round(mean(pct_moved), 2), n_transitions = n(), .groups = "drop") %>%
  pivot_wider(names_from = is_spike_transition, values_from = c(mean_pct_moved, n_transitions), names_prefix = "spike_")
print(as.data.frame(spike_vs_other), row.names = FALSE)

cat("\nDone.\n")
