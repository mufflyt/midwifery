#!/usr/bin/env Rscript
# =============================================================================
# Does each FROZEN consumer need a frozen POPULATION, or is it merely pinned to
# stale LINKAGE?
# =============================================================================
# artifacts/amcb_npi_linkage_FROZEN.csv is ONE 60-column file carrying TWO
# different kinds of claim, and that is why the freeze is hard to reason about:
#
#   POPULATION  who is in the study -- certification_number, amcb_id, status,
#               certification_date, the AMCB name fields, cohort_member. This
#               is a scientific definition. Its manifest records a deliberate
#               decision -- currently the 2026-10-22 re-freeze that retired
#               class-4 (Levenshtein surname) matching, run
#               reconcile_ab_20261022T134500_remove_fuzzy_surname_matching,
#               16,775 members -- and changing it changes what the paper is
#               about. This comment described the 54-column, 16,898-member
#               2026-08-10 freeze until 2026-11-13; the shape and the count
#               belong to the manifest, not to a comment written once.
#   LINKAGE     which NPI that person is, and the evidence for it -- npi,
#               npi_match_*, name_evidence_class, linkage_tier, match_strategy,
#               and every nppes_* field. This is an EVIDENCE-DEPENDENT estimate.
#               It should improve when NPPES does, and pinning it means
#               publishing an old answer to a question that now has a better one.
#
# A consumer reading only POPULATION columns is correctly frozen. A consumer
# reading LINKAGE columns is pinned to the identity decisions of a 2025-vintage
# NPPES panel, which is a pipeline artifact rather than a scientific choice.
# This script sorts the consumers into those classes by the columns they
# actually name, so the freeze question is answered per consumer instead of
# per repository.
#
# COLUMN NAMES ARE EVIDENCE, NOT PROOF. A script that builds column names
# dynamically, or passes the whole frame to a helper, will under-report. Those
# land in "unclassified" and are listed, never assumed harmless -- the same
# discipline frozen_dependency_graph.R applies to output paths it cannot
# resolve statically.
#
# Output: artifacts/frozen_consumer_classification.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source("R/frozen_dependency_graph.R")

POPULATION_COLS <- c("certification", "certification_number", "status",
  "certification_date", "expiration_date", "last_name", "first_name",
  "middle_name", "discipline", "primary_source", "customer_id", "amcb_id",
  "amcb_name_original", "amcb_customer_id", "normalized_last_name",
  "normalized_first_name", "normalized_middle_name", "cohort_member")

LINKAGE_COLS <- c("npi", "npi_match_method", "nppes_matched_last",
  "nppes_matched_first", "nppes_mid_init", "npi_tax_class",
  "name_evidence_class", "npi_match_resolution", "npi_match_confidence",
  "npi_match_score", "match_strategy", "nppes_first_name", "nppes_middle_name",
  "nppes_last_name", "nppes_credential", "nppes_city", "nppes_state",
  "nppes_zip", "nppes_practice_address", "nppes_location_year",
  "n_candidates_pre_rank", "n_midwifery_candidates", "n_nursing_only_candidates",
  "best_evidence_class", "n_at_best_class", "n_mid_vetoed_c5",
  "resolved_by_absence_c5", "npi_demoted_absence_c5", "npi_match_status",
  "has_candidate", "linkage_tier", "candidate_count",
  "nppes_name_changed_since_match", "ambiguity_flag", "match_reason",
  "class5_candidate_npi")

cons <- frozen_consumers(".")
cons <- cons[cons$reads_frozen, , drop = FALSE]
cat(sprintf("FROZEN consumers discovered by the repo's own scanner: %d\n", nrow(cons)))

# `npi` is a substring of many names (npi_match_score, n_midwifery_...), so it
# is matched on a word boundary and only where it looks like a column
# reference, not anywhere the three letters appear.
names_in <- function(code, cols) {
  cols[vapply(cols, function(c)
    grepl(sprintf("[\"'`$]%s[\"'`]?\\b|\\b%s\\b\\s*(=|<-|,|\\))", c, c), code), logical(1))]
}

rows <- lapply(cons$script, function(f) {
  code <- paste(readLines(f, warn = FALSE), collapse = "\n")
  code <- gsub("#[^\n]*", "", code)        # comments are documentation, not use
  pop <- names_in(code, POPULATION_COLS)
  lnk <- names_in(code, LINKAGE_COLS)
  cls <- if (length(lnk) && length(pop)) "both"
         else if (length(lnk)) "linkage_only"
         else if (length(pop)) "population_only"
         else "unclassified"
  tibble(script = f, class = cls,
         n_population_cols = length(pop), n_linkage_cols = length(lnk),
         population_cols = paste(pop, collapse = "|"),
         linkage_cols = paste(lnk, collapse = "|"))
})
cl <- bind_rows(rows) %>%
  left_join(cons %>% select(script, network), by = "script") %>%
  arrange(class, desc(n_linkage_cols))

cat("\n=== classification ===\n")
print(as.data.frame(cl %>% count(class, name = "n_scripts")), row.names = FALSE)
cat(sprintf("\nnetwork-dependent (cannot be rebuilt offline): %d\n", sum(cl$network)))

cat("\n=== population_only: correctly frozen, nothing to regenerate ===\n")
po <- cl %>% filter(class == "population_only")
if (nrow(po)) cat(paste0("  ", po$script, collapse = "\n"), "\n") else cat("  <none>\n")

cat("\n=== unclassified: names no FROZEN column literally; MUST be read by hand ===\n")
uc <- cl %>% filter(class == "unclassified")
if (nrow(uc)) cat(paste0("  ", uc$script, collapse = "\n"), "\n") else cat("  <none>\n")

cat("\n=== most linkage-dependent consumers (candidates to become dynamic) ===\n")
print(as.data.frame(cl %>% filter(class %in% c("linkage_only", "both")) %>%
  select(script, class, n_linkage_cols, n_population_cols) %>% head(12)), row.names = FALSE)

write_csv(cl, "artifacts/frozen_consumer_classification.csv", na = "")
cat(sprintf("\nwrote artifacts/frozen_consumer_classification.csv (%d rows)\n", nrow(cl)))
