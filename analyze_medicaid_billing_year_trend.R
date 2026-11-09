#!/usr/bin/env Rscript
# =============================================================================
# Medicaid procedure-billing volume by year, aggregated across the cohort
# =============================================================================
# Group-level trend, NOT a per-provider count (see
# docs/TECHNICAL_APPENDIX_MEDICAID_PROCEDURE_BILLING.md S7 for why
# individual counts are not recoverable from this dataset). Summing
# TOTAL_CLAIM_LINES across the whole 56,258-NPI cohort by year is far more
# stable than any one provider's number -- undercounting from the 12-claim-
# line/12-beneficiary cell-suppression floor partially washes out in
# aggregate, though it does not disappear: a true decline in Medicaid
# volume and a rise in the SHARE of activity falling below the suppression
# floor would look identical in this series. Read trend DIRECTION with more
# confidence than trend MAGNITUDE.
#
# CAVEAT CARRIED FORWARD: Nov-Dec 2024 are under-reported relative to prior
# months across the whole HCPCS release (incomplete state submissions per
# Milliman's published analysis) -- visible as an artificial dip in this
# series' last two months, not a real activity drop.
#
# Input : artifacts/amcb_npi_linkage_FROZEN.csv, ABOG sources (via
#         R/lib/ob_midwife_cohort.R)
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
# Output: artifacts/medicaid_billing_year_trend.csv
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

SPENDING_DUCKDB_RELATIVE <- "DuckDB/medicaid_provider_spending_verified.duckdb"
PROCEDURE_CODES <- list(
  pap_test          = c("Q0091", "G0101"),
  urodynamics       = c("51725", "51726", "51727", "51728", "51729", "51736",
                         "51741", "51784", "51785", "51797", "51798"),
  iud               = c("58300", "58301"),
  vaginal_delivery  = c("59400", "59409", "59410", "59610", "59612", "59614")
)

cat("=== Medicaid procedure-billing volume by year, 2018-2024 ===\n")

cohort <- build_ob_midwife_cohort()
cat(sprintf("[cohort] combined distinct NPI: %s\n", nrow(cohort)))

db_path <- samsung_volume_path(SPENDING_DUCKDB_RELATIVE)
con <- duckdb_connect(dbdir = db_path, read_only = TRUE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

duckdb::duckdb_register(con, "cohort_npi", cohort %>% select(npi, provider_group))
code_lookup <- purrr::imap_dfr(PROCEDURE_CODES, function(codes, category) {
  tibble(hcpcs_code = codes, procedure_category = category)
})
duckdb::duckdb_register(con, "procedure_codes", code_lookup)

trend <- DBI::dbGetQuery(con, "
  SELECT
    c.provider_group,
    pc.procedure_category,
    LEFT(s.CLAIM_FROM_MONTH, 4) AS claim_year,
    COUNT(DISTINCT c.npi)                             AS n_distinct_npi_billing,
    SUM(TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT))      AS total_claim_lines,
    SUM(TRY_CAST(s.TOTAL_PATIENTS AS BIGINT))         AS total_patients_summed
  FROM spending s
  JOIN cohort_npi c  ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
  JOIN procedure_codes pc ON s.HCPCS_CODE = pc.hcpcs_code
  GROUP BY c.provider_group, pc.procedure_category, LEFT(s.CLAIM_FROM_MONTH, 4)
  ORDER BY pc.procedure_category, c.provider_group, claim_year
") %>% as_tibble()

out_csv <- "artifacts/medicaid_billing_year_trend.csv"
write_with_provenance(trend, out_csv,
                      inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", db_path))
cat(sprintf("  Wrote: %s (%s rows)\n", out_csv, nrow(trend)))

cat("=========================================================================\n")
print(trend %>% filter(procedure_category == "vaginal_delivery"), n = Inf)
cat("=========================================================================\n")
