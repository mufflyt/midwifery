#!/usr/bin/env Rscript
# =============================================================================
# Leave-one-source-family-out sensitivity, and whether the migration
# spikes survive WITHOUT NPPES in the vote
# =============================================================================
# Scoped to majority + dawid_skene only (crowd_kit backend) -- the fast,
# highest-value pair; the full 5-method truthdiscovery sweep x 5 leave-
# one-out variants was judged not worth the added runtime for a sensitivity
# check whose main job is to say whether dropping a source family changes
# the headline picture, not to re-litigate every method again. Requires
# RETICULATE_PYTHON pointed at the crowd-kit venv (see
# build_truth_fusion_predictions.R's header for both venvs' paths).
#
# 6 variants over 5 source families (NPPES, DAC+PECOS-combined, Open
# Payments, T-MSIS Medicaid enrollment state, and facility/hospital
# affiliation via NPI-CCN -- all added 2026-11-05, run extract_tmsis_
# medicaid_enrollment_state_history.R first): full, and one drop per
# family.
#
# The single most direct test of "is the migration spike an NPPES
# artifact": rerun dawid_skene on DAC+PECOS-combined and Open Payments
# ONLY, with NPPES entirely excluded from both the claims AND the move-
# rate calculation (which otherwise always uses NPPES's own year-pairs as
# the backbone) -- if 2017->2018 and 2023->2024 still show elevated move
# rates using only non-NPPES evidence, that is real signal the spike isn't
# specific to how NPPES is read.
#
# Input : same sources as build_truth_fusion_predictions.R
# Output: artifacts/truth_fusion_leave_one_out_sensitivity.csv (tracked, aggregate)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(mysteryroster)})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "truth_fusion_claims.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "migration_rate.R"))

backends <- attribute_truth_backends()
if (!isTRUE(backends$available[backends$backend == "crowd_kit"]))
  stop("crowd_kit backend not available in this R process -- set RETICULATE_PYTHON to the crowd-kit venv first.", call. = FALSE)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "[0-9]{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(!is.na(payment_amount), payment_amount > 0) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
TMSIS_PATH <- "artifacts/tmsis_medicaid_enrollment_state_by_year.csv"
if (!file.exists(TMSIS_PATH))
  stop(sprintf("%s not found -- run extract_tmsis_medicaid_enrollment_state_history.R first.", TMSIS_PATH), call. = FALSE)
tmsis_medicaid <- read_csv(TMSIS_PATH, col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
facility_affiliation <- read_csv("artifacts/dac_facility_affiliations.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
dac_pecos_combined <- merge_dac_pecos_sources(dac_all, pecos)

ALL_SOURCES <- list(nppes = nppes, dac_pecos_combined = dac_pecos_combined, open_payments = op_all,
                     tmsis_medicaid = tmsis_medicaid, facility_affiliation = facility_affiliation)
VARIANTS <- list(
  full = ALL_SOURCES,
  drop_nppes = ALL_SOURCES[c("dac_pecos_combined", "open_payments", "tmsis_medicaid", "facility_affiliation")],
  drop_dac_pecos_combined = ALL_SOURCES[c("nppes", "open_payments", "tmsis_medicaid", "facility_affiliation")],
  drop_open_payments = ALL_SOURCES[c("nppes", "dac_pecos_combined", "tmsis_medicaid", "facility_affiliation")],
  drop_tmsis_medicaid = ALL_SOURCES[c("nppes", "dac_pecos_combined", "open_payments", "facility_affiliation")],
  drop_facility_affiliation = ALL_SOURCES[c("nppes", "dac_pecos_combined", "open_payments", "tmsis_medicaid")]
)

YEARS <- 2013:2026

results <- list()
for (variant_name in names(VARIANTS)) {
  cat(sprintf("\n========== variant: %s (sources: %s) ==========\n", variant_name, paste(names(VARIANTS[[variant_name]]), collapse = ", ")))
  claims <- build_truth_fusion_claims(VARIANTS[[variant_name]], npi_filter = link$npi)
  for (m in c("majority", "dawid_skene")) {
    res <- tryCatch(suppressWarnings(attribute_truth_fusion(claims, method = m)),
                     error = function(e) { cat(sprintf("%s FAILED: %s\n", m, conditionMessage(e))); NULL })
    if (is.null(res)) next
    cat(sprintf("%s: n=%d, abstained=%.1f%%\n", m, nrow(res$predictions), 100 * mean(res$predictions$abstained)))
    pred_states <- res$predictions %>% filter(!abstained) %>% transmute(npi = entity_id, year = as.integer(reference_year), state = predicted_value)
    rates <- compute_migration_rates(pred_states, YEARS) %>%
      mutate(variant = variant_name, method = m,
             is_spike_transition = (year_from == 2017 & year_to == 2018) | (year_from == 2023 & year_to == 2024))
    results[[paste(variant_name, m)]] <- rates
  }
}

all_results <- bind_rows(results)
write_with_provenance(all_results, "artifacts/truth_fusion_leave_one_out_sensitivity.csv",
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv", op_files))
cat(sprintf("\n-> artifacts/truth_fusion_leave_one_out_sensitivity.csv (%d rows)\n", nrow(all_results)))

cat("\n=== Spike transitions (2017-18, 2023-24) vs. every other transition's mean, by variant x method ===\n")
summ <- all_results %>% group_by(variant, method, is_spike_transition) %>%
  summarise(mean_pct_moved = round(mean(pct_moved), 2), n_transitions = n(), .groups = "drop")
print(as.data.frame(summ), row.names = FALSE)

cat("\nDone.\n")
