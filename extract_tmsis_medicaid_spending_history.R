#!/usr/bin/env Rscript
# =============================================================================
# Medicaid billing activity, by year, from HHS DOGE's T-MSIS spending release
# =============================================================================
# HHS's DOGE team released the largest public Medicaid claims dataset in the
# department's history on 2026-02-13: the Transformed Medicaid Statistical
# Information System (T-MSIS) provider-spending file, 238M rows, no
# application or data-use-agreement required (previously this needed a
# ResDAC-mediated T-MSIS DUA). Source:
# https://stopendataprod.blob.core.windows.net/datasets/medicaid-provider-spending/2026-02-09/dataset/medicaid-provider-spending.csv.zip
# Already ingested into /Volumes/MufflySamsung/DuckDB/
# medicaid_provider_spending_verified.duckdb (loaded_at 2026-10-23, confirmed
# via its own _provenance table), never read by this project before now.
#
# DISTINCT FROM the Medicaid source already in Table 1's by-year chart
# (state_source_audit_medicaid_classification_by_year.csv), which is a
# pre-aggregated ENROLLMENT classification (Concordant/Discordant/
# Multistate/Indeterminate/Not observed), not person-level, and so cannot be
# restricted to each year's certification-eligible subset the way every
# other source in build_table1_by_year.R is. This file is BILLING activity
# (claim lines, patients, dollars paid), genuinely person-level and
# month-level, so it CAN be eligibility-restricted like the rest.
#
# SERVICING, NOT BILLING, PROVIDER NPI. Matched 6,472 of 16,775 cohort-member
# NPIs (38.6%) via SERVICING_PROVIDER_NPI_NUM vs. only 597 (3.6%) via
# BILLING_PROVIDER_NPI_NUM -- the same rendering-vs-billing-NPI asymmetry
# already documented for Medicare Part B (match_medicare_partb_partd.R): a
# midwife's claims are usually billed under a supervising clinician's or a
# group's NPI, but she is still named as the servicing/rendering provider.
# SERVICING_PROVIDER_NPI_NUM is used throughout.
#
# TOTAL_PAID HAS A DOCUMENTED CORRUPTION PROBLEM IN THE RAW RELEASE (some
# rows nationally show implausible trillion-dollar provider-month totals --
# see trade/health-policy coverage of the DOGE release). Verified 2026-11-05
# against the SUBSET this script actually reads (cohort-member NPIs only,
# 487,846 rows): min -$719.42 (plausible claim adjustment), max $305,181.16,
# median $367.15, ZERO rows over $1M. The corruption documented elsewhere in
# the national file does not appear to reach this cohort's rows -- but a
# defensive upper bound is still applied (PLAUSIBLE_MAX below) rather than
# trusted implicitly, consistent with this project's standing rule never to
# publish a number without a sanity bound (the same discipline the GFR and
# CDC WONDER suppression guards elsewhere in this repo already apply).
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
# Output : artifacts/tmsis_medicaid_spending_cohort_by_year.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # duckdb_connect(): CSV-ingestion bootstrap

SPEND_DB <- "/Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb"
if (!file.exists(SPEND_DB))
  stop(sprintf("T-MSIS spending warehouse not found at %s. It lives on an external volume; mount it or adjust the path.", SPEND_DB), call. = FALSE)

PLAUSIBLE_MAX <- 1e6   # per provider-month; verified ceiling in this cohort's rows is $305,181

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"),
                 progress = FALSE)
coh <- link %>% filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(coh), big.mark = ",")))

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE)
dbExecute(con, sprintf("ATTACH '%s' AS spend_db (READ_ONLY)", SPEND_DB))

sql <- sprintf(r"(
  SELECT c.npi,
         CAST(LEFT(s.CLAIM_FROM_MONTH, 4) AS INTEGER) AS year,
         SUM(TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT)) AS n_claim_lines,
         SUM(TRY_CAST(s.TOTAL_PATIENTS AS BIGINT)) AS n_patients_summed,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) BETWEEN -%f AND %f
                   THEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) ELSE 0 END) AS total_paid_bounded,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) > %f THEN 1 ELSE 0 END) AS n_rows_over_bound
    FROM cohort_npis c
    INNER JOIN spend_db.spending s ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
   WHERE s.CLAIM_FROM_MONTH IS NOT NULL
   GROUP BY c.npi, year)", PLAUSIBLE_MAX, PLAUSIBLE_MAX, PLAUSIBLE_MAX)
by_npi_year <- dbGetQuery(con, sql)

n_excluded <- sum(by_npi_year$n_rows_over_bound)
cat(sprintf("Matched: %s NPI-years across %s distinct NPIs, %d-%d\n",
            format(nrow(by_npi_year), big.mark = ","),
            length(unique(by_npi_year$npi)),
            min(by_npi_year$year), max(by_npi_year$year)))
cat(sprintf("Rows excluded from total_paid_bounded for exceeding the $%s plausibility bound: %d%s\n",
            format(PLAUSIBLE_MAX, big.mark = ",", scientific = FALSE), n_excluded,
            if (n_excluded == 0) " (none -- bound not triggered in this cohort)" else ""))

write_csv(by_npi_year, "artifacts/tmsis_medicaid_spending_cohort_by_year.csv", na = "")
cat("written: artifacts/tmsis_medicaid_spending_cohort_by_year.csv\n")
