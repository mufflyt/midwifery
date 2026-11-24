#!/usr/bin/env Rscript
# =============================================================================
# Full source-by-source practice-state agreement matrix (Supplemental)
# =============================================================================
# Table 4 reports each source against the registry hub; this artifact reports
# every source pair. Two committed inputs, kept as separate tiers because
# their denominators differ in kind: the longitudinal tier counts
# provider-years across each pair's overlapping observation window
# (mrost_agreement_pairwise.csv, from compare_all_sources_mysteryroster.R);
# the snapshot tier compares each pair at its single common vintage
# (cross_source_pairwise_matrix.csv, from build_cross_source_comparison.R).
# The same pair can appear in both tiers with different denominators; that is
# the two questions, not a duplicate. A pair is flagged shared_lineage when
# both members descend from one upstream system (Part B and Part D claims;
# PECOS enrollment and the directory family it feeds), where agreement is a
# family resemblance rather than independent corroboration.
#
# Inputs : artifacts/mrost_agreement_pairwise.csv
#          artifacts/cross_source_pairwise_matrix.csv
# Outputs: artifacts/source_pairwise_agreement_matrix.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

IN_LONG <- "artifacts/mrost_agreement_pairwise.csv"
IN_SNAP <- "artifacts/cross_source_pairwise_matrix.csv"
OUT     <- "artifacts/source_pairwise_agreement_matrix.csv"
stopifnot(file.exists(IN_LONG), file.exists(IN_SNAP))

FAMILY <- list(
  medicare_claims      = c("medicare_part_b", "medicare_part_d"),
  enrollment_directory = c("pecos_revalidation", "dac_physician_compare",
                           "facility_affiliation_ccn", "cms_ndh_fhir"))
family_of <- function(s) {
  hit <- names(FAMILY)[vapply(FAMILY, function(m) s %in% m, logical(1))]
  if (length(hit)) hit[1] else NA_character_
}

read_tier <- function(path, tier) {
  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    mutate(tier = tier,
           shared_lineage = mapply(function(a, b) {
             fa <- family_of(a)
             fb <- family_of(b)
             !is.na(fa) && !is.na(fb) && fa == fb
           }, source_a, source_b))
}

out <- bind_rows(read_tier(IN_LONG, "longitudinal_provider_years"),
                 read_tier(IN_SNAP, "snapshot_common_vintage")) %>%
  arrange(tier, desc(n_comparable))

# Self-check: each percentage recomputes from its own counts, and no pair
# repeats within a tier in either orientation.
stopifnot(
  all(abs(out$pct_agree - 100 * out$n_agree / out$n_comparable) < 0.05),
  !any(duplicated(paste(out$tier, pmin(out$source_a, out$source_b),
                        pmax(out$source_a, out$source_b)))))

write_with_provenance(out, OUT, inputs = c(IN_LONG, IN_SNAP))
print(as.data.frame(out))
