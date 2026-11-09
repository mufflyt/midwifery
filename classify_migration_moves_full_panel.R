#!/usr/bin/env Rscript
# =============================================================================
# Full-panel migration move classifier: confirmed / possible / likely
# administrative artifact / indeterminate
# =============================================================================
# Generalizes this repo's spike-specific sub-annual checks
# (docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S7) into a rule-based,
# auditable classifier run over every apparent interstate move in the full
# 2013-2026 cohort panel (13 transitions), not just the two historical
# spikes -- per a user-supplied specification (2026-11-06) whose central
# requirement is that agreement among sources must never be read as
# accuracy: DAC's address field is CMS-derived from PECOS directly (see
# R/lib/truth_fusion_claims.R), and NPPES agreeing with itself is not
# independent confirmation of itself.
#
# Candidate moves are defined on the FUSED (dawid_skene) prediction, not raw
# NPPES, per that spec -- which makes a naive "does another source's claim
# match" corroboration check circular by construction: any source whose
# claim matches the before/after states necessarily voted for those same
# states in the fusion. Resolved the same way build_leave_one_source_out_
# sensitivity.R already resolves "is the spike an NPPES artifact" -- by
# checking whether the move SURVIVES refitting the model with the
# supporting source's family excluded (the held-out check below), not by
# inventing new per-vote bookkeeping.
#
# Source-family registry for this classifier: dac_pecos_combined,
# open_payments, and tmsis_medicaid are usable for corroboration (direct
# observation only, no inference -- same discipline as R/lib/
# corroboration_lookup.R's lookup_state()). facility_affiliation is
# DESCRIPTIVE ONLY: it has no data before 2026, so it can never satisfy
# "both endpoint years directly observed" -- recorded in the evidence
# table, excluded from the support/contradict tally with that reason
# stated, never silently dropped.
#
# Cohort: the same 16,775-NPI linkage-eligible cohort
# (artifacts/amcb_npi_linkage_FROZEN.csv, cohort_member == "TRUE") the
# existing truth-fusion build already uses -- NOT the stricter 12,170-NPI
# canonical_active_primary() subset (R/lib/cohort_definitions.R), which is
# an AMCB clinical-status filter unrelated to NPI-matching and would
# silently narrow this analysis's population without being asked to.
#
# Deferred to a follow-on pass (see docs/TECHNICAL_APPENDIX_MIGRATION_
# MOVE_CLASSIFICATION.md for the full list): the 10-scenario sensitivity
# suite beyond leave-one-out, 3 temporal-window variants, diagnostic
# figures, and re-extracting NPPES's Last Update Date / Open Payments'
# Date_of_Payment to upgrade their date_precision.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv,
#          artifacts/truth_fusion_predictions_dawid_skene.csv,
#          artifacts/truth_fusion_claims.csv,
#          artifacts/truth_fusion_leave_one_out_predictions.csv
# Outputs: artifacts/migration_move_evidence_table.csv (Deliverable A,
#            person-level, gitignored)
#          artifacts/migration_move_classification_full_panel.csv
#            (Deliverable B, person-level, gitignored)
#          artifacts/migration_move_classification_summary_by_transition.csv
#            (Deliverable C, tracked, aggregate)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tibble)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "migration_move_classification.R"))

METHOD <- "dawid_skene"
YEARS <- 2013:2026

LOCATION_TYPE <- c(
  nppes                = "practice (self-reported)",
  dac_pecos_combined   = "enrollment/practice (DAC's field is CMS-derived from PECOS)",
  open_payments        = "reported recipient/mailing address",
  tmsis_medicaid       = "Medicaid enrollment",
  facility_affiliation = "hospital/facility address -- not the person's own location"
)
DATE_PRECISION <- c(
  nppes = "year", dac_pecos_combined = "month", open_payments = "year",
  tmsis_medicaid = "interval", facility_affiliation = "snapshot"
)

# -----------------------------------------------------------------------------
# Load
# -----------------------------------------------------------------------------
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort: %s NPIs (linkage-eligible, cohort_member == TRUE -- NOT the stricter\n", format(nrow(link), big.mark = ",")))
cat("12,170-NPI canonical_active_primary() subset, which is an AMCB clinical-status\n")
cat("filter unrelated to NPI-matching, per docs/TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md)\n")

pred <- read_csv(sprintf("artifacts/truth_fusion_predictions_%s.csv", METHOD), col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), predicted_value,
            abstained = as.logical(abstained)) %>%
  filter(npi %in% link$npi)

claims <- read_csv("artifacts/truth_fusion_claims.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(entity_id), source_family = source_id, claimed_value, year = as.integer(reference_year)) %>%
  filter(npi %in% link$npi)

loo <- read_csv("artifacts/truth_fusion_leave_one_out_predictions.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state, variant, method) %>%
  filter(npi %in% link$npi)

cat(sprintf("Predictions (%s): %s npi-years (%.1f%% abstained)\n",
            METHOD, format(nrow(pred), big.mark = ","), 100 * mean(pred$abstained)))
cat(sprintf("Claims: %s rows across %d source families\n", format(nrow(claims), big.mark = ","), length(unique(claims$source_family))))

# -----------------------------------------------------------------------------
# Deliverable A: observation-level evidence table
# -----------------------------------------------------------------------------
# evidence_status is per (npi, source_family, year): "ambiguous" when that
# family carries >1 distinct claimed_value for the same npi-year (a genuine
# multi-value conflict build_truth_fusion_claims() already preserves rather
# than collapsing), "usable" otherwise. date_precision/location_type are
# static per family -- an honest encoding of what's ACTUALLY available
# (never a fabricated finer date for sources that only carry a vintage/
# release-level label -- see this script's header and docs/
# TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md for why DAC, PECOS,
# and facility_affiliation can never get finer than that).
evidence <- claims %>%
  group_by(npi, source_family, year) %>%
  mutate(evidence_status = if_else(n_distinct(claimed_value) > 1, "ambiguous", "usable")) %>%
  ungroup() %>%
  mutate(location_type = LOCATION_TYPE[source_family], date_precision = DATE_PRECISION[source_family])

write_with_provenance(evidence, "artifacts/migration_move_evidence_table.csv",
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "artifacts/truth_fusion_claims.csv"))
cat(sprintf("-> artifacts/migration_move_evidence_table.csv (%s rows)\n", format(nrow(evidence), big.mark = ",")))

# -----------------------------------------------------------------------------
# Per-family direct-observation index (build_family_index()/lookup_family(),
# sourced from R/lib/migration_move_classification.R) and the held-out
# leave-one-out index (build_loo_index()/held_out_ok(), same file).
# -----------------------------------------------------------------------------
family_idx <- setNames(lapply(FAMILIES, function(f) build_family_index(claims, f)), FAMILIES)
loo_idx <- build_loo_index(loo, METHOD)

# -----------------------------------------------------------------------------
# Candidate pairs: every (npi, year_from, year_to) where BOTH years have a
# prediction row (eligible), 13 consecutive-year transitions, 2013-2026.
# -----------------------------------------------------------------------------
all_pairs <- bind_rows(lapply(seq_len(length(YEARS) - 1), function(i) {
  yf <- YEARS[i]; yt <- YEARS[i + 1]
  pf <- pred %>% filter(year == yf) %>% transmute(npi, state_from = predicted_value, abstain_from = abstained)
  pt <- pred %>% filter(year == yt) %>% transmute(npi, state_to = predicted_value, abstain_to = abstained)
  inner_join(pf, pt, by = "npi") %>% mutate(year_from = yf, year_to = yt)
}))
cat(sprintf("Eligible consecutive-year pairs: %s\n", format(nrow(all_pairs), big.mark = ",")))

# -----------------------------------------------------------------------------
# Classify ONE apparent move (never called for abstained or stable pairs).
# Rule IDs documented in docs/TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md.
# -----------------------------------------------------------------------------
# classify_apparent_move() itself is sourced from
# R/lib/migration_move_classification.R -- see this script's header for why
# it lives there (testability against synthetic indices).

# -----------------------------------------------------------------------------
# Apply: abstained pairs -> Indeterminate (IND-ABSTAIN) directly, never
# compared for stability or passed to the classifier. Stable pairs
# (state_from == state_to) are excluded from classification entirely and
# reported as their own denominator (per spec SS3.3/13C), not folded into
# any of the 4 categories.
# -----------------------------------------------------------------------------
all_pairs <- all_pairs %>% mutate(row_type = classify_row_type(abstain_from, abstain_to, state_from, state_to))
cat(sprintf("Row types: %s\n", paste(sprintf("%s=%s", names(table(all_pairs$row_type)), table(all_pairs$row_type)), collapse = ", ")))

movers <- all_pairs %>% filter(row_type %in% c("abstained", "move"))
cat(sprintf("Classifying %s abstained + apparent-mover pairs...\n", format(nrow(movers), big.mark = ",")))

classified <- bind_rows(lapply(seq_len(nrow(movers)), function(i) {
  r <- movers[i, ]
  if (r$row_type == "abstained") {
    verdict <- list(classification = "indeterminate", rule_id = "IND-ABSTAIN",
                     reason = "at least one endpoint year abstained in the fused prediction -- classified separately as an unresolved transition, never imputed",
                     support = character(0), contradict = character(0), ambiguous = character(0))
  } else {
    verdict <- classify_apparent_move(family_idx, loo_idx, r$npi, r$year_from, r$year_to, r$state_from, r$state_to)
    if (is.null(verdict$support)) verdict$support <- character(0)
    if (is.null(verdict$contradict)) verdict$contradict <- character(0)
    if (is.null(verdict$ambiguous)) verdict$ambiguous <- character(0)
  }
  tibble(
    npi = r$npi, year_from = r$year_from, year_to = r$year_to,
    state_from = r$state_from, state_to = r$state_to,
    classification = verdict$classification, rule_id = verdict$rule_id, reason = verdict$reason,
    supporting_families = paste(verdict$support, collapse = "|"),
    contradicting_families = paste(verdict$contradict, collapse = "|"),
    ambiguous_families = paste(verdict$ambiguous, collapse = "|"),
    n_support = length(verdict$support), n_contradict = length(verdict$contradict),
    held_out_confirmed = identical(verdict$rule_id, "CONF-2FAM"),
    is_known_gap_transition = is_gap_transition(r$year_from, r$year_to)
  )
}))

write_with_provenance(classified, "artifacts/migration_move_classification_full_panel.csv",
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv",
                                  sprintf("artifacts/truth_fusion_predictions_%s.csv", METHOD),
                                  "artifacts/truth_fusion_claims.csv",
                                  "artifacts/truth_fusion_leave_one_out_predictions.csv"))
cat(sprintf("-> artifacts/migration_move_classification_full_panel.csv (%s rows)\n", format(nrow(classified), big.mark = ",")))

# -----------------------------------------------------------------------------
# Deliverable C: aggregate summary by transition, every denominator explicit.
# -----------------------------------------------------------------------------
stable_counts <- all_pairs %>% filter(row_type == "stable") %>% count(year_from, year_to, name = "stable_pairs")
# A classification value that never fires anywhere in the panel (e.g.
# ART-CONTRA finding zero contradictions) would otherwise leave its column
# missing from pivot_wider entirely, crashing the mutate(across(...)) below
# -- add any of the 5 required columns that didn't occur, as all-zero.
REQUIRED_CLASSES <- c("confirmed", "confirmed_not_held_out", "possible", "administrative_artifact", "indeterminate")
cls_counts <- classified %>% count(year_from, year_to, classification, name = "n") %>%
  tidyr::pivot_wider(names_from = classification, values_from = n, values_fill = 0)
for (cls in setdiff(REQUIRED_CLASSES, names(cls_counts))) cls_counts[[cls]] <- 0L
abstain_counts <- classified %>% filter(rule_id == "IND-ABSTAIN") %>% count(year_from, year_to, name = "indeterminate_abstained")
mixed_counts <- classified %>% filter(rule_id == "MIXED-SPLIT") %>% count(year_from, year_to, name = "indeterminate_mixed")

summary_by_transition <- all_pairs %>% count(year_from, year_to, name = "eligible_pairs") %>%
  left_join(stable_counts, by = c("year_from", "year_to")) %>%
  left_join(cls_counts, by = c("year_from", "year_to")) %>%
  left_join(abstain_counts, by = c("year_from", "year_to")) %>%
  left_join(mixed_counts, by = c("year_from", "year_to")) %>%
  mutate(across(c(stable_pairs, confirmed, confirmed_not_held_out, possible, administrative_artifact,
                   indeterminate, indeterminate_abstained, indeterminate_mixed), ~ tidyr::replace_na(., 0))) %>%
  mutate(apparent_movers = eligible_pairs - stable_pairs,
         pct_confirmed = round(100 * confirmed / eligible_pairs, 2),
         pct_confirmed_not_held_out = round(100 * confirmed_not_held_out / eligible_pairs, 2),
         pct_possible = round(100 * possible / eligible_pairs, 2),
         pct_administrative_artifact = round(100 * administrative_artifact / eligible_pairs, 2),
         pct_indeterminate = round(100 * indeterminate / eligible_pairs, 2),
         is_known_gap_transition = is_gap_transition(year_from, year_to)) %>%
  arrange(year_from)

write_with_provenance(summary_by_transition, "artifacts/migration_move_classification_summary_by_transition.csv",
                       inputs = c("artifacts/migration_move_classification_full_panel.csv"))
cat("\n=== Summary by transition (Deliverable C) ===\n")
print(as.data.frame(summary_by_transition), row.names = FALSE)

# -----------------------------------------------------------------------------
# Regression check (spec S11.3): compare against this session's prior
# narrative conclusions for the 3 already-investigated transitions. Report
# agreement or explicit discrepancy -- never forced to match.
# -----------------------------------------------------------------------------
cat("\n=== Regression check vs. prior narrative (TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md) ===\n")
for (pair in list(c(2017L, 2018L, "2017-18: prior finding = NOT a real spike, substantially NPPES-specific"),
                   c(2020L, 2021L, "2020-21: prior finding = DAC alone shows elevation (H2 2021-H1 2022); PECOS corroboration retracted as a dedup-determinism bug"),
                   c(2023L, 2024L, "2023-24: prior finding = holds up at annual multi-source resolution, but no sub-annual DAC/PECOS corroboration"))) {
  yf <- as.integer(pair[1]); yt <- as.integer(pair[2])
  row <- summary_by_transition %>% filter(year_from == yf, year_to == yt)
  cat(sprintf("\n%s\n  this classifier: confirmed=%d, confirmed_not_held_out=%d, possible=%d, administrative_artifact=%d, indeterminate=%d (of %d eligible pairs)\n",
              pair[3], row$confirmed, row$confirmed_not_held_out, row$possible, row$administrative_artifact, row$indeterminate, row$eligible_pairs))
}
cat("\nNote: 2020-21 may reasonably land mostly as 'possible' rather than 'confirmed' here --\n")
cat("only ONE family (dac_pecos_combined) ever showed elevation for that window, and this\n")
cat("classifier's CONF-2FAM rule requires >=2 independent families. That is a stricter\n")
cat("standard than the earlier ad hoc sub-annual diagnostic used, not a contradiction.\n")

cat("\nDone.\n")
