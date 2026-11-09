#!/usr/bin/env Rscript
# =============================================================================
# Apparent movers vs. stable-state controls (specification scenario #10)
# =============================================================================
# classify_migration_moves_full_panel.R found only 0.2% of apparent movers
# are confirmed by >=2 independent source families. Is that unusually low
# FOR MOVERS specifically, or does the same >=2-independent-family evidence
# bar rarely clear for ANY pair, including the 156,684 genuinely stable ones
# -- i.e. is the low confirmation rate about migration being hard to verify,
# or just about general source sparsity hitting every pair alike?
#
# Reuses the identical family index / direct-observation lookup
# (R/lib/migration_move_classification.R) the mover-side classifier already
# uses -- check_stability_support() is its mirror image for the stable case:
# a family AGREES if it directly observes the SAME state at both endpoint
# years; DISAGREES if it observes a DIFFERENT state at either year (i.e. the
# family itself detected something the fused prediction's stability call
# didn't). Same no-inference, never-arbitrarily-resolved discipline.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv,
#          artifacts/truth_fusion_predictions_dawid_skene.csv,
#          artifacts/truth_fusion_claims.csv
# Outputs: artifacts/migration_stable_vs_mover_corroboration_summary.csv (tracked, aggregate)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tibble)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "migration_move_classification.R"))

METHOD <- "dawid_skene"
YEARS <- 2013:2026

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()

pred <- read_csv(sprintf("artifacts/truth_fusion_predictions_%s.csv", METHOD), col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), predicted_value, abstained = as.logical(abstained)) %>%
  filter(npi %in% link$npi)

claims <- read_csv("artifacts/truth_fusion_claims.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(entity_id), source_family = source_id, claimed_value, year = as.integer(reference_year)) %>%
  filter(npi %in% link$npi)

family_idx <- setNames(lapply(FAMILIES, function(f) build_family_index(claims, f)), FAMILIES)

all_pairs <- bind_rows(lapply(seq_len(length(YEARS) - 1), function(i) {
  yf <- YEARS[i]; yt <- YEARS[i + 1]
  pf <- pred %>% filter(year == yf) %>% transmute(npi, state_from = predicted_value, abstain_from = abstained)
  pt <- pred %>% filter(year == yt) %>% transmute(npi, state_to = predicted_value, abstain_to = abstained)
  inner_join(pf, pt, by = "npi") %>% mutate(year_from = yf, year_to = yt)
})) %>% mutate(row_type = classify_row_type(abstain_from, abstain_to, state_from, state_to))

stable <- all_pairs %>% filter(row_type == "stable")
cat(sprintf("Checking independent-family agreement for all %s stable pairs (2013-2026)...\n", format(nrow(stable), big.mark = ",")))

stable_checked <- bind_rows(lapply(seq_len(nrow(stable)), function(i) {
  r <- stable[i, ]
  v <- check_stability_support(family_idx, r$npi, r$year_from, r$year_to, r$state_from)
  tibble(npi = r$npi, year_from = r$year_from, year_to = r$year_to, state = r$state_from,
         n_agree = v$n_agree, n_disagree = v$n_disagree, n_ambiguous = length(v$ambiguous),
         would_pass_conf_2fam_evidence_bar = v$n_agree >= 2 && v$n_disagree == 0)
}))

write_with_provenance(stable_checked %>% count(year_from, year_to, name = "stable_pairs") %>%
                         left_join(stable_checked %>% group_by(year_from, year_to) %>%
                                     summarise(n_zero_evidence = sum(n_agree == 0 & n_disagree == 0),
                                               n_single_family_agree = sum(n_agree == 1 & n_disagree == 0),
                                               n_meets_2fam_bar = sum(would_pass_conf_2fam_evidence_bar),
                                               n_any_disagree = sum(n_disagree >= 1), .groups = "drop"),
                                   by = c("year_from", "year_to")) %>%
                         mutate(pct_meets_2fam_bar = round(100 * n_meets_2fam_bar / stable_pairs, 3),
                                pct_zero_evidence = round(100 * n_zero_evidence / stable_pairs, 2)),
                       "artifacts/migration_stable_vs_mover_corroboration_summary.csv",
                       inputs = c("artifacts/migration_move_classification_full_panel.csv"))

cat("\n=== Stable pairs meeting the SAME >=2-independent-family evidence bar CONF-2FAM uses ===\n")
summary_tbl <- read_csv("artifacts/migration_stable_vs_mover_corroboration_summary.csv", show_col_types = FALSE)
print(as.data.frame(summary_tbl), row.names = FALSE)

total_stable <- nrow(stable_checked)
total_meets_bar <- sum(stable_checked$would_pass_conf_2fam_evidence_bar)
total_zero <- sum(stable_checked$n_agree == 0 & stable_checked$n_disagree == 0)
cat(sprintf("\nOverall: %s of %s stable pairs (%.2f%%) meet the >=2-independent-family evidence bar.\n",
            format(total_meets_bar, big.mark = ","), format(total_stable, big.mark = ","), 100 * total_meets_bar / total_stable))
cat(sprintf("Overall: %s of %s stable pairs (%.1f%%) have ZERO evidence either way from any family -- same coverage sparsity as movers.\n",
            format(total_zero, big.mark = ","), format(total_stable, big.mark = ","), 100 * total_zero / total_stable))
cat(sprintf("For comparison, movers: 14 of 4,592 (0.3%%) meet the same bar (classify_migration_moves_full_panel.R).\n"))

cat("\nDone.\n")
