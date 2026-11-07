#!/usr/bin/env Rscript
# =============================================================================
# Temporal sensitivity: strict (window=0, today's standing behavior) vs.
# moderate (1yr) / permissive (2yr, 3yr) proximity backfill (specification
# 2026-11-06, S9)
# =============================================================================
# Re-classifies the SAME candidate moves classify_migration_moves_full_
# panel.R already found, under 4 window settings, using the identical rule
# set in R/lib/migration_move_classification.R -- no new truth-fusion
# refit, no new candidate-move detection, just a wider proximity search
# when a usable family's exact-year claim is missing.
#
# Windowing applies ONLY to dac_pecos_combined and open_payments (year/
# vintage-level sources with no more informative effective interval).
# tmsis_medicaid is NEVER windowed -- it already has real interval_start/
# interval_end dates, checked at exact-year resolution upstream (expand_
# intervals_to_year_claims()); widening its search would make its answer
# LESS precise, not more. facility_affiliation stays excluded from the
# support/contradict tally at every window, same as the strict run.
#
# A family's windowed answer is still never arbitrarily resolved: if
# nearby years disagree (or one of them is itself ambiguous), the result
# is "ambiguous", not a pick -- see lookup_family_windowed()'s header.
#
# Output: artifacts/migration_temporal_sensitivity_summary.csv (tracked,
#         aggregate: one row per transition x window, reconciling exactly
#         the same way Deliverable C does) and a transition-level
#         "robustness" column: does the dominant classification for that
#         transition change across ANY window tested.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tibble); library(tidyr)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "migration_move_classification.R"))

METHOD <- "dawid_skene"
YEARS <- 2013:2026
WINDOWS <- c(0L, 1L, 2L, 3L)
REQUIRED_CLASSES <- c("confirmed", "confirmed_not_held_out", "possible", "administrative_artifact", "indeterminate")

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()

pred <- read_csv(sprintf("artifacts/truth_fusion_predictions_%s.csv", METHOD), col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), predicted_value, abstained = as.logical(abstained)) %>%
  filter(npi %in% link$npi)

claims <- read_csv("artifacts/truth_fusion_claims.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(entity_id), source_family = source_id, claimed_value, year = as.integer(reference_year)) %>%
  filter(npi %in% link$npi)

loo <- read_csv("artifacts/truth_fusion_leave_one_out_predictions.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state, variant, method) %>%
  filter(npi %in% link$npi)

family_idx <- setNames(lapply(FAMILIES, function(f) build_family_index(claims, f)), FAMILIES)
loo_idx <- build_loo_index(loo, METHOD)

all_pairs <- bind_rows(lapply(seq_len(length(YEARS) - 1), function(i) {
  yf <- YEARS[i]; yt <- YEARS[i + 1]
  pf <- pred %>% filter(year == yf) %>% transmute(npi, state_from = predicted_value, abstain_from = abstained)
  pt <- pred %>% filter(year == yt) %>% transmute(npi, state_to = predicted_value, abstain_to = abstained)
  inner_join(pf, pt, by = "npi") %>% mutate(year_from = yf, year_to = yt)
})) %>% mutate(row_type = classify_row_type(abstain_from, abstain_to, state_from, state_to))

movers <- all_pairs %>% filter(row_type == "move")  # abstained pairs are IND-ABSTAIN at every window identically -- excluded from the per-window comparison, not re-derived 4 times for nothing
cat(sprintf("Re-classifying %s apparent movers across %d window settings (%s)...\n",
            format(nrow(movers), big.mark = ","), length(WINDOWS), paste(WINDOWS, collapse = ", ")))

classify_all_windows <- bind_rows(lapply(WINDOWS, function(w) {
  cat(sprintf("  window=%d...\n", w))
  bind_rows(lapply(seq_len(nrow(movers)), function(i) {
    r <- movers[i, ]
    v <- classify_apparent_move(family_idx, loo_idx, r$npi, r$year_from, r$year_to, r$state_from, r$state_to, window = w)
    tibble(npi = r$npi, year_from = r$year_from, year_to = r$year_to, window = w,
           classification = v$classification, rule_id = v$rule_id,
           n_windowed_families_used = length(v$windowed_families_used))
  }))
}))

# -----------------------------------------------------------------------------
# Per-transition, per-window summary -- same reconciliation discipline as
# Deliverable C (missing classification columns padded to 0, never a crash).
# -----------------------------------------------------------------------------
cls_counts <- classify_all_windows %>% count(year_from, year_to, window, classification, name = "n") %>%
  pivot_wider(names_from = classification, values_from = n, values_fill = 0)
for (cls in setdiff(REQUIRED_CLASSES, names(cls_counts))) cls_counts[[cls]] <- 0L

n_apparent <- movers %>% count(year_from, year_to, name = "n_apparent_movers")
n_windowed <- classify_all_windows %>% filter(n_windowed_families_used > 0) %>%
  count(year_from, year_to, window, name = "n_moves_using_a_windowed_family")

summary_tbl <- cls_counts %>% left_join(n_apparent, by = c("year_from", "year_to")) %>%
  left_join(n_windowed, by = c("year_from", "year_to", "window")) %>%
  mutate(n_moves_using_a_windowed_family = tidyr::replace_na(n_moves_using_a_windowed_family, 0L),
         pct_confirmed = round(100 * confirmed / n_apparent_movers, 2),
         pct_possible = round(100 * possible / n_apparent_movers, 2),
         pct_administrative_artifact = round(100 * administrative_artifact / n_apparent_movers, 2),
         pct_indeterminate = round(100 * indeterminate / n_apparent_movers, 2)) %>%
  arrange(year_from, window)

write_with_provenance(summary_tbl, "artifacts/migration_temporal_sensitivity_summary.csv",
                       inputs = c("artifacts/migration_move_classification_full_panel.csv"))
cat("\n=== Temporal sensitivity by transition x window ===\n")
print(as.data.frame(summary_tbl %>% select(year_from, year_to, window, n_apparent_movers,
                                            confirmed, confirmed_not_held_out, possible,
                                            administrative_artifact, indeterminate,
                                            n_moves_using_a_windowed_family)), row.names = FALSE)

# -----------------------------------------------------------------------------
# Robustness: does the DOMINANT (plurality) classification for a transition
# change across any window tested, relative to window=0 (strict)?
# -----------------------------------------------------------------------------
dominant <- summary_tbl %>%
  rowwise() %>%
  mutate(dominant_classification = REQUIRED_CLASSES[which.max(c(confirmed, confirmed_not_held_out, possible, administrative_artifact, indeterminate))]) %>%
  ungroup() %>% select(year_from, year_to, window, dominant_classification)
strict_dominant <- dominant %>% filter(window == 0) %>% select(year_from, year_to, dominant_classification_strict = dominant_classification)
robustness <- dominant %>% left_join(strict_dominant, by = c("year_from", "year_to")) %>%
  group_by(year_from, year_to) %>%
  summarise(robust_to_all_windows_tested = all(dominant_classification == dominant_classification_strict), .groups = "drop")

cat("\n=== Robustness: does the dominant classification change under any tested window? ===\n")
print(as.data.frame(robustness), row.names = FALSE)

cat("\nDone.\n")
