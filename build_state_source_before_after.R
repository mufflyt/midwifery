#!/usr/bin/env Rscript
# =============================================================================
# What the Open Payments restoration actually changed, year by year
# =============================================================================
# The 2026-11-12 build of the state-source audit discovered its Open Payments
# years by globbing artifacts/cohort_midwives_open_payments_general_*.csv. Only
# the 2024 file was on that machine, so the build produced a one-year analysis
# and reported success. 28ec41f restored 2021-2025 from the warehouse and made
# the window a declared property of config/state_source_audit_sources.csv.
#
# This script states what moved between the published numbers and the rebuilt
# ones, and why -- so that no reader has to take "it is better now" on trust.
#
# THERE ARE TWO DISTINCT "BEFORE" STATES, AND CONFLATING THEM WOULD MISLEAD:
#
#   PUBLISHED   the Section 3 table as it stood in the tracked appendix at
#               576b537 (2026-11-12). Five years, but computed on a source
#               vintage three rebuilds old. This is the record a reader of the
#               repository at that commit would have seen, so it is the honest
#               comparator and is carried below.
#   BUILT       what the 2026-11-12 run itself produced: 2024 alone. Never
#               published, never tracked (artifacts/state_source_audit_*.csv
#               are gitignored), and overwritten by the next run. It cannot be
#               recovered, which is itself the finding -- a build that silently
#               narrowed its own window also left nothing behind to prove it.
#
# Run: Rscript build_state_source_before_after.R
# Output: artifacts/state_source_audit_before_after.csv (+ provenance sidecar)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

AGREEMENT <- "artifacts/state_source_audit_agreement.csv"
COVERAGE  <- "artifacts/state_source_audit_coverage.csv"
AUDIT     <- "artifacts/open_payments_annual_coverage_audit.csv"
OUT       <- "artifacts/state_source_audit_before_after.csv"

for (needed in c(AGREEMENT, COVERAGE, AUDIT)) {
  if (!file.exists(needed))
    stop(sprintf("required input absent: %s\n  Run build_state_source_audit.R first.",
                 needed), call. = FALSE)
}

# The published Section 3 figures at 576b537, read out of the tracked appendix
# at that commit. Hard-coded rather than read from git: a superseded published
# number is a historical fact, not a live input, and a producer that shells out
# to `git show` stops working in a shallow clone or an exported tarball.
PUBLISHED_2026_11_12 <- tibble::tribble(
  ~program_year, ~original_comparable_npi_years, ~original_agreement_pct,
  2021L,                                  14441L,                   96.2,
  2022L,                                  19349L,                   96.5,
  2023L,                                  19261L,                   96.1,
  2024L,                                  18720L,                   97.5,
  2025L,                                  21731L,                   96.1)

# Which years the 2026-11-12 run actually had an input file for.
BUILT_YEARS_2026_11_12 <- 2024L

message("Reading the rebuilt audit ...")
rebuilt_agreement <- read_csv(AGREEMENT, col_types = cols(.default = "c"),
                              progress = FALSE) %>%
  filter(.data$source == "open_payments") %>%
  transmute(program_year = as.integer(.data$year),
            rebuilt_comparable_npi_years = as.integer(.data$n_comparable),
            rebuilt_agreement_pct = as.numeric(.data$pct_agree))

rebuilt_coverage <- read_csv(COVERAGE, col_types = cols(.default = "c"),
                             progress = FALSE) %>%
  filter(.data$source == "open_payments") %>%
  transmute(program_year = as.integer(.data$year),
            rebuilt_source_record_count = as.integer(.data$n_rows),
            rebuilt_cohort_npi_count = as.integer(.data$n_npis))

coverage_audit <- read_csv(AUDIT, col_types = cols(.default = "c"),
                           progress = FALSE) %>%
  transmute(program_year = as.integer(.data$program_year),
            validation_status = .data$validation_status,
            source_year_verified = .data$source_year_verified)

message(sprintf("  %d rebuilt agreement rows, %d rebuilt coverage rows",
                nrow(rebuilt_agreement), nrow(rebuilt_coverage)))

# A YEAR THE BUILD NEVER HAD AND A YEAR IT RECOMPUTED ARE DIFFERENT FINDINGS.
# 2021-2023 and 2025 were absent from the 2026-11-12 run entirely; 2024 was
# present and still moved, because the annual artifact was regenerated from the
# warehouse with CMS's own Program_Year as the year of record instead of the
# year in the filename. Those are two of the six classes the audit asks for,
# and they are not interchangeable.
classify <- function(program_year, delta) {
  recovered <- !program_year %in% BUILT_YEARS_2026_11_12
  ifelse(recovered,
         "1_missing_input_recovery + 2_source_vintage_correction",
         "2_source_vintage_correction")
}

explain <- function(program_year) {
  ifelse(!program_year %in% BUILT_YEARS_2026_11_12,
         paste("absent from the 2026-11-12 build (no annual input file on that",
               "machine); restored from the warehouse and re-verified against a",
               "full scan of the raw CMS file"),
         paste("present in the 2026-11-12 build; the annual artifact was",
               "regenerated from the warehouse and now takes its year from CMS's",
               "Program_Year column rather than from the filename"))
}

before_after <- PUBLISHED_2026_11_12 %>%
  full_join(rebuilt_agreement, by = "program_year") %>%
  left_join(rebuilt_coverage, by = "program_year") %>%
  left_join(coverage_audit, by = "program_year") %>%
  arrange(.data$program_year) %>%
  mutate(
    source_id = "open_payments",
    original_source_coverage = ifelse(
      .data$program_year %in% BUILT_YEARS_2026_11_12, "present", "absent"),
    rebuilt_source_coverage = "present",
    # Untracked and overwritten: there is no record of these, and saying so is
    # more useful than a plausible-looking reconstruction.
    original_source_record_count = NA_integer_,
    original_cohort_npi_count = NA_integer_,
    abs_pct_point_difference = round(
      abs(.data$rebuilt_agreement_pct - .data$original_agreement_pct), 1),
    difference_class = classify(.data$program_year, .data$abs_pct_point_difference),
    difference_reason = explain(.data$program_year)) %>%
  select(source_id, program_year,
         original_source_coverage, rebuilt_source_coverage,
         original_source_record_count, rebuilt_source_record_count,
         original_cohort_npi_count, rebuilt_cohort_npi_count,
         original_comparable_npi_years, rebuilt_comparable_npi_years,
         original_agreement_pct, rebuilt_agreement_pct,
         abs_pct_point_difference, difference_class, difference_reason,
         validation_status, source_year_verified)

stopifnot(nrow(before_after) == 5L,
          !any(is.na(before_after$rebuilt_agreement_pct)),
          !any(is.na(before_after$original_agreement_pct)))

message("Year-by-year movement in agreement with NPPES:")
for (i in seq_len(nrow(before_after))) {
  row <- before_after[i, ]
  message(sprintf("  %d  %5.1f%% -> %5.1f%%  (%+0.1f pt)  %s",
                  row$program_year, row$original_agreement_pct,
                  row$rebuilt_agreement_pct,
                  row$rebuilt_agreement_pct - row$original_agreement_pct,
                  row$original_source_coverage))
}
message(sprintf("Largest absolute movement: %.1f percentage points",
                max(before_after$abs_pct_point_difference)))

write_with_provenance(before_after, OUT, inputs = c(AGREEMENT, COVERAGE, AUDIT))
message(sprintf("Wrote %s (%d rows) and its provenance sidecar",
                OUT, nrow(before_after)))
