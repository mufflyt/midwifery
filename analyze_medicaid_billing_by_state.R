#!/usr/bin/env Rscript
# =============================================================================
# Medicaid procedure-billing volume by state: midwife vs. OB-GYN comparison
# =============================================================================
# State-level aggregation crosses the 12-claim-line/12-beneficiary cell-
# suppression floor far more easily than a per-provider figure (see
# docs/TECHNICAL_APPENDIX_MEDICAID_PROCEDURE_BILLING.md S7), so this is a
# genuinely usable workforce-distribution signal -- midwife vs. OB-GYN
# Medicaid-billed volume BY STATE -- even though the same source data
# cannot give a reliable per-provider count WITHIN a state.
#
# State is the provider's reported NPPES (midwife) or ABOG (OB-GYN) practice
# state, NOT a state derived from the claim itself (the spending dataset has
# no state field at all -- see Section 3.1-3.2 of the appendix). A provider
# billing a state's Medicaid program while practicing in a different state
# (rare, but real for border/telehealth practice) would be attributed to
# their REPORTED practice state here, not the paying state's program.
#
# Input : artifacts/amcb_npi_linkage_FROZEN.csv, ABOG sources (via
#         R/lib/ob_midwife_cohort.R, include_state = TRUE)
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
# Output: artifacts/medicaid_billing_by_state.csv
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

cat("=== Medicaid procedure-billing volume by state, 2018-2024 ===\n")

cohort <- build_ob_midwife_cohort(include_state = TRUE)
n_no_state <- sum(is.na(cohort$state) | cohort$state == "")
cat(sprintf("[cohort] combined distinct NPI: %s (%s missing a practice state)\n",
            nrow(cohort), n_no_state))

db_path <- samsung_volume_path(SPENDING_DUCKDB_RELATIVE)
con <- duckdb_connect(dbdir = db_path, read_only = TRUE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

duckdb::duckdb_register(con, "cohort_npi", cohort %>% select(npi, provider_group, state))
code_lookup <- purrr::imap_dfr(PROCEDURE_CODES, function(codes, category) {
  tibble(hcpcs_code = codes, procedure_category = category)
})
duckdb::duckdb_register(con, "procedure_codes", code_lookup)

by_state <- DBI::dbGetQuery(con, "
  SELECT
    c.state AS practice_state,
    c.provider_group,
    pc.procedure_category,
    COUNT(DISTINCT c.npi)                             AS n_distinct_npi_billing,
    SUM(TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT))      AS total_claim_lines
  FROM spending s
  JOIN cohort_npi c  ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
  JOIN procedure_codes pc ON s.HCPCS_CODE = pc.hcpcs_code
  WHERE c.state IS NOT NULL AND c.state != ''
  GROUP BY c.state, c.provider_group, pc.procedure_category
  ORDER BY pc.procedure_category, practice_state, c.provider_group
") %>% as_tibble()

cohort_n_by_state <- cohort %>% filter(!is.na(state), state != "") %>%
  count(state, provider_group, name = "n_cohort")

by_state_full <- by_state %>%
  left_join(cohort_n_by_state, by = c("practice_state" = "state", "provider_group")) %>%
  mutate(pct_billing = round(100 * n_distinct_npi_billing / n_cohort, 1))

out_csv <- "artifacts/medicaid_billing_by_state.csv"
write_with_provenance(by_state_full, out_csv,
                      inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", db_path))
cat(sprintf("  Wrote: %s (%s rows)\n", out_csv, nrow(by_state_full)))

cat("=========================================================================\n")
cat("Top 10 states by vaginal_delivery billing NPI count (midwife):\n")
print(by_state_full %>% filter(procedure_category == "vaginal_delivery", provider_group == "midwife") %>%
        arrange(desc(n_distinct_npi_billing)) %>% head(10))
cat("=========================================================================\n")
