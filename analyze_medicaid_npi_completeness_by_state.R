#!/usr/bin/env Rscript
# =============================================================================
# National NPI-completeness gradient, Medicaid Provider Enrollment Segments
# =============================================================================
# Not midwife-specific, not cohort-specific -- this is a property of the raw
# warehouse itself, every row, every state. Written because the OR/NM "0%"
# finding (docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md S10)
# turned out to be the extreme end of a continuous gradient that touches
# every state's numbers, not a two-state anomaly: Colorado's own rows are
# only 71.9% NPI-populated, Texas 65.3%. Every concordance percentage in
# this analysis is implicitly a lower bound computed only on the rows that
# happen to survive this gradient.
#
# Input : /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Output: artifacts/medicaid_npi_completeness_by_state.csv (+ provenance)
#
# @family diagnostics
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr)})
.this_script_dir <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg)) dirname(normalizePath(sub("^--file=", "", file_arg[1]))) else getwd()
})
source(file.path(.this_script_dir, "R", "lib", "medicare_duckdb.R"))
source(file.path(.this_script_dir, "R", "lib", "artifact_provenance.R"))

MEDICAID_DB <- Sys.getenv(
  "MEDICAID_ENROLLMENT_DB",
  "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb")
if (!file.exists(MEDICAID_DB)) stop("missing required input: ", MEDICAID_DB, call. = FALSE)

con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)",
                            DBI::dbQuoteString(con, MEDICAID_DB)))

result <- dplyr::tbl(con, "medicaid.enrollment_segments") |>
  dplyr::group_by(STATE_CD) |>
  dplyr::summarise(n_rows = dplyr::n(), n_npi_nonnull = sum(!is.na(NPI)), .groups = "drop") |>
  dplyr::collect() |>
  dplyr::mutate(pct_npi_populated = round(100 * n_npi_nonnull / n_rows, 1)) |>
  dplyr::arrange(.data$pct_npi_populated) |>
  dplyr::rename(state_cd = STATE_CD)

base::message("== National NPI-completeness gradient, by state ==")
print(result, n = Inf)

n_zero <- sum(result$pct_npi_populated == 0)
n_under_80 <- sum(result$pct_npi_populated < 80)
base::message(sprintf(
  "\n%d states/territories at 0%% NPI-populated. %d of %d (%.0f%%) are under 80%%.",
  n_zero, n_under_80, nrow(result), 100 * n_under_80 / nrow(result)))

out <- "artifacts/medicaid_npi_completeness_by_state.csv"
write_with_provenance(result, out, inputs = c(MEDICAID_DB))
base::message(sprintf("\nwrote %s", out))
