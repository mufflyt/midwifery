#!/usr/bin/env Rscript
# =============================================================================
# Medicaid participation confidence tier: enrollment x spending, 2018-2024
# =============================================================================
# Cross-references the already-downloaded Enrollment Segments warehouse
# (who CAN bill Medicaid -- an administrative relationship) against the
# Provider Spending by HCPCS warehouse (who DEFINITELY billed, at real
# claim-line volume) to produce a defensible 3-level confidence variable,
# rather than treating either source alone as "accepts Medicaid":
#
#   enrolled_and_billed    strongest evidence of active Medicaid practice
#   enrolled_only          administrative relationship; practice activity
#                          unknown (may never have submitted a claim, or
#                          billed below the 12-claim-line/12-beneficiary
#                          cell-suppression floor -- see
#                          docs/TECHNICAL_APPENDIX_MEDICAID_PROCEDURE_BILLING.md
#                          S7 for why that floor matters)
#   neither                either genuinely does not see Medicaid patients,
#                          or a data gap in one or both sources
#
# "Billed" here means ANY of the four target procedures
# (PROCEDURE_CODES, same set as analyze_medicaid_procedure_billing_ob_midwife.R)
# in ANY month 2018-2024 -- a provider who billed a different Medicaid
# service entirely (routine prenatal visits, etc.) that is outside this
# script's four-procedure scope would be misclassified as enrolled_only.
# This is a scope choice, not an oversight: broadening to all HCPCS codes
# would answer a different, broader question ("any Medicaid billing
# activity") rather than the specific procedures this project cares about.
#
# "Enrolled" uses the SAME any-time qualifying-status definition the
# enrollment-concordance work already established
# (is_qualifying_enrollment_status(), R/lib/medicaid_enrollment_intervals.R)
# -- ACTIVE or TERM status overlapping 2018-2024 -- not the point-in-time
# NPPES-snapshot definition that script's PRIMARY estimand uses, since there
# is no single snapshot date to anchor to here.
#
# Input : artifacts/amcb_npi_linkage_FROZEN.csv, ABOG sources (via
#         R/lib/ob_midwife_cohort.R)
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
# Output: artifacts/medicaid_enrollment_spending_tier_by_npi.csv
#         artifacts/medicaid_enrollment_spending_tier_summary.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(DBI); library(duckdb); library(readr); library(tibble)
})

.this_script_dir <- dirname(sub("--file=", "", grep("--file=", commandArgs(trailingOnly = FALSE), value = TRUE)))
if (length(.this_script_dir) == 0 || !nzchar(.this_script_dir)) .this_script_dir <- "."
source(file.path(.this_script_dir, "R", "lib", "cohort_definitions.R"))
source(file.path(.this_script_dir, "R", "lib", "medicare_duckdb.R"))
source(file.path(.this_script_dir, "R", "lib", "artifact_provenance.R"))
source(file.path(.this_script_dir, "R", "lib", "ob_midwife_cohort.R"))
source(file.path(.this_script_dir, "R", "lib", "medicaid_enrollment_intervals.R"))

ENROLLMENT_DB <- "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb"
SPENDING_DUCKDB_RELATIVE <- "DuckDB/medicaid_provider_spending_verified.duckdb"
PROCEDURE_CODES <- c("Q0091", "G0101",
                      "51725", "51726", "51727", "51728", "51729", "51736",
                      "51741", "51784", "51785", "51797", "51798",
                      "58300", "58301",
                      "59400", "59409", "59410", "59610", "59612", "59614")

cat("=== Medicaid enrollment x spending confidence tier, 2018-2024 ===\n")

cohort <- build_ob_midwife_cohort()
cat(sprintf("[cohort] combined distinct NPI: %s\n", nrow(cohort)))

con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH '%s' AS enrollment (READ_ONLY)", ENROLLMENT_DB))
DBI::dbExecute(con, sprintf("ATTACH '%s' AS spending (READ_ONLY)", samsung_volume_path(SPENDING_DUCKDB_RELATIVE)))

duckdb::duckdb_register(con, "cohort_npi", cohort %>% select(npi, provider_group))
duckdb::duckdb_register(con, "procedure_codes", tibble(hcpcs_code = PROCEDURE_CODES))

enrolled_npi <- dplyr::tbl(con, "enrollment.enrollment_segments") %>%
  select(NPI, ENRL_STATUS_CD) %>%
  collect() %>%
  mutate(qualifying = is_qualifying_enrollment_status(ENRL_STATUS_CD)) %>%
  filter(qualifying) %>%
  distinct(NPI) %>%
  pull(NPI)
cat(sprintf("[enrollment] distinct NPIs with a qualifying (ACTIVE/TERM) segment, any time 2018-2024: %s\n",
            length(enrolled_npi)))
duckdb::duckdb_register(con, "enrolled_npi", tibble(npi = as.character(enrolled_npi)))

billed_npi <- DBI::dbGetQuery(con, "
  SELECT DISTINCT s.SERVICING_PROVIDER_NPI_NUM AS npi
  FROM spending.spending s
  JOIN cohort_npi c ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
  JOIN procedure_codes pc ON s.HCPCS_CODE = pc.hcpcs_code
")$npi
cat(sprintf("[spending] cohort NPIs billing any of the 4 target procedures: %s\n", length(billed_npi)))

tier <- cohort %>%
  mutate(
    is_enrolled = npi %in% enrolled_npi,
    is_billed = npi %in% billed_npi,
    tier = case_when(
      is_enrolled & is_billed ~ "enrolled_and_billed",
      is_enrolled & !is_billed ~ "enrolled_only",
      TRUE ~ "neither"
    )
  )

out_npi <- "artifacts/medicaid_enrollment_spending_tier_by_npi.csv"
write_with_provenance(tier, out_npi,
                      inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", ENROLLMENT_DB,
                                 samsung_volume_path(SPENDING_DUCKDB_RELATIVE)))
cat(sprintf("  Wrote: %s (%s rows)\n", out_npi, nrow(tier)))

summary_tbl <- tier %>%
  count(provider_group, tier, name = "n") %>%
  group_by(provider_group) %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  ungroup() %>%
  arrange(provider_group, desc(n))

out_summary <- "artifacts/medicaid_enrollment_spending_tier_summary.csv"
write_with_provenance(summary_tbl, out_summary,
                      inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", ENROLLMENT_DB,
                                 samsung_volume_path(SPENDING_DUCKDB_RELATIVE)))
cat(sprintf("  Wrote: %s (%s rows)\n", out_summary, nrow(summary_tbl)))

cat("=========================================================================\n")
print(summary_tbl, n = Inf)
cat("=========================================================================\n")
