#!/usr/bin/env Rscript
# =============================================================================
# §11 before/after audit: one row per (source, year) describing what the
# reconstruction knows about it
# =============================================================================
# The spec asked for an 11-column per-source-year audit so a reader can see,
# for every cell of the longitudinal surface, how much evidence it carries
# and where that evidence came from. Built over the canonical table plus the
# producers' own validation artifacts -- nothing here is recomputed from
# scratch, so the audit cannot drift from the series it describes.
#
# Columns:
#   source, year, n_rows, n_npis, coverage_pct (of frozen cohort),
#   n_distinct_states, evidence_types, vintage, usable_for_trend_pct,
#   n_usable_for_trend, year_validation_status, n_with_source_record_id
#
# Twelve, not the spec's eleven: n_usable_for_trend is the numerator of
# usable_for_trend_pct, added so the percentage can be recomputed from the
# row beside it rather than taken on faith.
#
# Input : artifacts/canonical_source_records.csv (person-level, gitignored)
#         artifacts/open_payments_year_validation.csv
#         artifacts/medicare_claims_year_validation.csv
#         artifacts/ppef_vintage_validation.csv (vintage grain, not year)
# Output: artifacts/longitudinal_reconstruction_audit.csv (aggregate)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

RECORDS_CSV <- Sys.getenv("CANONICAL_RECORDS_CSV",
                          "artifacts/canonical_source_records.csv")
OP_VAL_CSV  <- Sys.getenv("OP_YEAR_VALIDATION_CSV",
                          "artifacts/open_payments_year_validation.csv")
MC_VAL_CSV  <- Sys.getenv("MC_YEAR_VALIDATION_CSV",
                          "artifacts/medicare_claims_year_validation.csv")
OUT <- Sys.getenv("RECONSTRUCTION_AUDIT_CSV",
                  "artifacts/longitudinal_reconstruction_audit.csv")

records <- read_csv(RECORDS_CSV,
                    col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(year = as.integer(year), usable_for_trend = usable_for_trend == "TRUE")
n_cohort <- dplyr::n_distinct(records$npi)

audit <- records %>%
  group_by(source, year) %>%
  summarise(
    n_rows = dplyr::n(),
    n_npis = dplyr::n_distinct(npi),
    coverage_pct = round(100 * n_npis / n_cohort, 1),
    n_distinct_states = dplyr::n_distinct(state),
    evidence_types = paste(sort(unique(evidence_type)), collapse = ";"),
    vintage = paste(sort(unique(vintage)), collapse = ";"),
    # n_usable_for_trend IS THE NUMERATOR OF THE COLUMN ABOVE IT, and it was
    # missing. usable_for_trend_pct is 100 * mean(usable_for_trend), so the
    # count that produces it is sum(usable_for_trend) -- and without that
    # count published beside it, the percentage is unverifiable: no reader can
    # recompute it, and ci_science_nightly.R's SCN1/SCN2 could not either.
    # Lacking the real numerator, SCN2 fitted the only pair that reproduced
    # the column -- itself, usable_for_trend_pct / usable_for_trend_pct -- and
    # then read the 13 source-years where the share is 0 as rates on an empty
    # denominator. The denominator was never empty; n_rows is 6226 on the
    # first of them. Publishing the count makes the real formula findable.
    usable_for_trend_pct = round(100 * mean(usable_for_trend), 1),
    n_usable_for_trend = sum(usable_for_trend),
    n_with_source_record_id = sum(!is.na(source_record_id)),
    .groups = "drop")

# Join whatever year-validation the producers emitted. A source-year with no
# validation row gets "not_validated", an honest status -- Open Payments is
# in_file_date for all usable years, Medicare is release_id/unverified, and
# NPPES/PPEF/T-MSIS carry their vintage in the artifact itself.
val <- bind_rows(
  read_csv(OP_VAL_CSV,
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(source = "open_payments", year = as.integer(program_year),
              year_validation_status = status),
  read_csv(MC_VAL_CSV,
           col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(source = "medicare_claims", year = as.integer(year),
              year_validation_status = status)) %>%
  # Medicare writes one row per PART (B warehouse = release_id, D csv =
  # unverified); the audit is per (source, year), so collapse the two legs
  # into one semicolon-joined status rather than duplicating the row.
  group_by(source, year) %>%
  summarise(year_validation_status =
              paste(sort(unique(year_validation_status)), collapse = ";"),
            .groups = "drop")
audit <- audit %>%
  left_join(val, by = c("source", "year")) %>%
  mutate(year_validation_status =
           dplyr::coalesce(year_validation_status,
                           dplyr::if_else(source == "nppes",
                                          "release_id", "not_validated"))) %>%
  arrange(source, year)

write_with_provenance(audit, OUT,
                      inputs = c(OP_VAL_CSV, MC_VAL_CSV),
                      na = "")
print(as.data.frame(audit), row.names = FALSE)
