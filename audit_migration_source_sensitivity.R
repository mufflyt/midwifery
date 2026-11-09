#!/usr/bin/env Rscript
# =============================================================================
# Source-family sensitivity: how much does each source family move the
# needle, measured two ways (specification 2026-11-06, S6/Table 2)
# =============================================================================
# Both measures reuse artifacts build_leave_one_source_out_sensitivity.R
# ALREADY computed and persisted -- no new truth-fusion refit here, no new
# ~90-minute run:
#
#  1. Prediction-level: for each of the 5 "drop one family" variants vs.
#     the "full" baseline (dawid_skene only, the classifier's primary
#     method), how many NPI-years' predicted state actually CHANGES, how
#     many lose prediction coverage entirely (present/non-abstained in
#     full, absent from the variant -- this script does not distinguish
#     "became abstained" from "entity has zero claims once that family's
#     claims are removed," since truth_fusion_leave_one_out_predictions.csv
#     only persists non-abstained rows either way; reported together as
#     "lost coverage", not over-attributed to abstention specifically).
#  2. Rate-level: for each variant, the already-tracked per-transition
#     move rate (artifacts/truth_fusion_leave_one_out_sensitivity.csv)
#     compared directly against the full baseline's rate, same transition,
#     same method.
#
# Deliberately NOT done here (follow-on work, named so it isn't silently
# dropped): re-running classify_migration_moves_full_panel.R's rule set
# under each drop-variant's own candidate moves and evidence. This script
# answers "how much does dropping a family change the FUSED PREDICTIONS
# and the raw MOVE RATE", not "how much does it change the CLASSIFICATION
# counts" -- that is a materially bigger task (the classifier's own
# held-out check is itself built on these same leave-one-out variants, so
# re-classifying under each variant needs its own design, not a quick
# add-on).
#
# Inputs : artifacts/truth_fusion_leave_one_out_predictions.csv,
#          artifacts/truth_fusion_leave_one_out_sensitivity.csv
# Outputs: artifacts/migration_source_sensitivity_summary.csv (tracked, aggregate)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})
source(file.path("R", "lib", "artifact_provenance.R"))

METHOD <- "dawid_skene"
VARIANTS_DROP <- c("drop_nppes", "drop_dac_pecos_combined", "drop_open_payments",
                    "drop_tmsis_medicaid", "drop_facility_affiliation")

loo <- read_csv("artifacts/truth_fusion_leave_one_out_predictions.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(method == METHOD) %>% transmute(npi = trimws(npi), year = as.integer(year), state, variant)
cat(sprintf("Loaded %s leave-one-out predictions (%s)\n", format(nrow(loo), big.mark = ","), METHOD))

full <- loo %>% filter(variant == "full") %>% select(npi, year, state_full = state)
cat(sprintf("Baseline (full): %s npi-years\n", format(nrow(full), big.mark = ",")))

prediction_level <- bind_rows(lapply(VARIANTS_DROP, function(v) {
  var_df <- loo %>% filter(variant == v) %>% select(npi, year, state_variant = state)
  comparable <- inner_join(full, var_df, by = c("npi", "year"))
  n_lost <- nrow(anti_join(full, var_df, by = c("npi", "year")))
  n_gained <- nrow(anti_join(var_df, full, by = c("npi", "year")))
  n_changed <- sum(comparable$state_full != comparable$state_variant)
  tibble(excluded_family = sub("^drop_", "", v),
         n_npi_years_variant = nrow(var_df),
         n_comparable_to_full = nrow(comparable),
         n_changed_value = n_changed,
         pct_changed_value = round(100 * n_changed / nrow(comparable), 2),
         n_lost_coverage = n_lost,
         n_gained_coverage = n_gained)
}))

rate_level <- read_csv("artifacts/truth_fusion_leave_one_out_sensitivity.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(method == METHOD) %>%
  transmute(variant, year_from = as.integer(year_from), year_to = as.integer(year_to),
            pct_moved = as.numeric(pct_moved), is_spike_transition = as.logical(is_spike_transition))

full_rates <- rate_level %>% filter(variant == "full") %>% select(year_from, year_to, pct_moved_full = pct_moved)

rate_sensitivity <- bind_rows(lapply(VARIANTS_DROP, function(v) {
  var_rates <- rate_level %>% filter(variant == v) %>% select(year_from, year_to, pct_moved_variant = pct_moved)
  merged <- inner_join(full_rates, var_rates, by = c("year_from", "year_to")) %>%
    mutate(abs_change = abs(pct_moved_variant - pct_moved_full),
           signed_change = pct_moved_variant - pct_moved_full)
  worst <- merged %>% slice_max(abs_change, n = 1, with_ties = FALSE)
  tibble(excluded_family = sub("^drop_", "", v),
         mean_abs_rate_change_pts = round(mean(merged$abs_change), 3),
         max_abs_rate_change_pts = round(worst$abs_change, 3),
         max_abs_rate_change_transition = sprintf("%d->%d", worst$year_from, worst$year_to),
         mean_signed_rate_change_pts = round(mean(merged$signed_change), 3))
}))

summary_tbl <- prediction_level %>% left_join(rate_sensitivity, by = "excluded_family") %>% arrange(desc(pct_changed_value))

write_with_provenance(summary_tbl, "artifacts/migration_source_sensitivity_summary.csv",
                       inputs = c("artifacts/truth_fusion_leave_one_out_predictions.csv", "artifacts/truth_fusion_leave_one_out_sensitivity.csv"))
cat("\n=== Source-family sensitivity (dawid_skene) ===\n")
print(as.data.frame(summary_tbl), row.names = FALSE)
cat("\nDone.\n")
