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
# WHERE THAT CORRUPTION LIVES, located 2026-11-09. It is not diffuse: in the
# published national file it concentrates in two HCPCS codes, '20' (34 rows,
# median $1.78bn) and 'Z9525' (84 rows, median $1.02bn) -- neither a valid
# HCPCS code, and together 99%+ of the file's dollars. The sibling NDC release
# (Medicaid Provider Spending by NDC, 2026-07-24) has the same defect under a
# different name: NATIONAL_DRUG_CODE '88888888888' is a sentinel bucket
# holding 99.6% of that file's $20.4 TRILLION reported total across 762,468
# rows. Anyone summing either file without a bound is reporting the sentinel.
#
# The bounds below therefore cover all three measures, not just dollars: a
# 'Z9525' row carries 1.2M claim lines and 596K patients, so a dollars-only
# guard let the counts through untouched. See PLAUSIBLE_LINES /
# PLAUSIBLE_PATIENTS / MIN_CODE_CHARS for what each one is for and why the
# code-shape test is a minimum length rather than an equality.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
# Output : artifacts/tmsis_medicaid_spending_cohort_by_year.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # duckdb_connect(): CSV-ingestion bootstrap

SPEND_DB <- samsung_duckdb_path("DuckDB/medicaid_provider_spending_verified.duckdb",
                                "MEDICAID_SPENDING_DB")
if (!file.exists(SPEND_DB))
  stop(sprintf("T-MSIS spending warehouse not found at %s. It lives on an external volume; mount it or adjust the path.", SPEND_DB), call. = FALSE)

PLAUSIBLE_MAX <- 1e6   # per provider-month; verified ceiling in this cohort's rows is $305,181

# THE DOLLAR BOUND GUARDED ONLY DOLLARS. TOTAL_CLAIM_LINES and TOTAL_PATIENTS
# were summed unconditionally below, so a row whose TOTAL_PAID the bound
# rejects still contributed its line and patient counts in full. Measured in
# the published national file (2026-02-09), that is not hypothetical:
#
#   HCPCS_CODE 'Z9525'  84 rows, median $1,017,504,976, median 1,229,770 claim
#                       lines and 596,231 patients PER PROVIDER-MONTH. Every
#                       one sits outside PLAUSIBLE_MAX, so its dollars were
#                       already dropped -- and its 1.2M claim lines were not.
#   HCPCS_CODE '20'     34 rows, median $1,778,140,761, of which 13 fall
#                       INSIDE PLAUSIBLE_MAX and were counted in every metric.
#
# Neither code reaches this cohort today (checked: zero cohort rows carry
# either), so no published number changes. These bounds are a guard against
# the next vintage, not a correction.
#
# SHAPE IS NOT THE TEST, AND A LENGTH FILTER WOULD DESTROY REAL DATA. 163
# cohort rows carry a code that is not 5 characters, and almost all of them
# are legitimate: 0510 (clinic), 0760 (treatment/observation room), 0500
# (outpatient services), 0521 (FQHC clinic visit) are four-digit UB-04 REVENUE
# codes, which T-MSIS carries alongside HCPCS. Those 93 FQHC/clinic rows are
# exactly where midwives practise. Only the two-character fragments ('18',
# '20') are junk, so the shape test is a minimum length, not an equality.
# 'Z9525' passes any shape test -- letter plus four digits is the valid HCPCS
# Level II form -- which is why magnitude, not shape, has to catch it.
# MEASURED EFFECT OF THIS WHOLE GUARD, 2026-11-09, against the published
# national file joined to the cohort NPI list (551,826 rows before):
#
#   rows      551,826 -> 551,816   (10 rows, all HCPCS '18')
#   paid      $822,143,232.12 -> unchanged   (the junk rows carry $0)
#   lines     18,019,752 -> 18,016,282       (-3,470 phantom claim lines)
#   patients  14,098,020 -> 14,097,029       (-991 phantom patient-counts)
#
# So: small, real, and dollars-neutral. 'Z9525' never reaches a cohort at all
# -- all 84 of its rows carry a NULL servicing AND billing NPI, so the INNER
# JOIN already drops them -- and all 34 '20' rows belong to 5200000300, which
# is not a valid NPI (NPIs begin 1 or 2). The count bounds below are therefore
# insurance against a future vintage attaching such rows to a real NPI, while
# MIN_CODE_CHARS is what does the work today.
MIN_CODE_CHARS   <- 3      # excludes '18'/'20'; keeps 4-digit revenue codes
PLAUSIBLE_LINES  <- 1e5    # per provider-month; this cohort's real ceiling is 13,581 (p99.9 = 331)
PLAUSIBLE_PATIENTS <- 5e4  # per provider-month; this cohort's real ceiling is 2,118 (p99.9 = 202)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"),
                 progress = FALSE)
coh <- link %>% filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(coh), big.mark = ",")))

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE)
dbExecute(con, sprintf("ATTACH '%s' AS spend_db (READ_ONLY)", SPEND_DB))

# Every metric is bounded by its own ceiling, and every exclusion is counted
# rather than silently zeroed -- a row dropped without a tally is the thing
# this whole guard exists to prevent.
sql <- sprintf(r"(
  SELECT c.npi,
         CAST(LEFT(s.CLAIM_FROM_MONTH, 4) AS INTEGER) AS year,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT) BETWEEN 0 AND %f
                   THEN TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT) ELSE 0 END) AS n_claim_lines,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PATIENTS AS BIGINT) BETWEEN 0 AND %f
                   THEN TRY_CAST(s.TOTAL_PATIENTS AS BIGINT) ELSE 0 END) AS n_patients_summed,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) BETWEEN -%f AND %f
                   THEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) ELSE 0 END) AS total_paid_bounded,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PAID AS DOUBLE) > %f THEN 1 ELSE 0 END) AS n_rows_over_bound,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT) > %f THEN 1 ELSE 0 END) AS n_rows_over_line_bound,
         SUM(CASE WHEN TRY_CAST(s.TOTAL_PATIENTS AS BIGINT) > %f THEN 1 ELSE 0 END) AS n_rows_over_patient_bound
    FROM cohort_npis c
    INNER JOIN spend_db.spending s ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
   WHERE s.CLAIM_FROM_MONTH IS NOT NULL
     AND s.HCPCS_CODE IS NOT NULL
     AND length(trim(s.HCPCS_CODE)) >= %d
   GROUP BY c.npi, year)",
   PLAUSIBLE_LINES, PLAUSIBLE_PATIENTS, PLAUSIBLE_MAX, PLAUSIBLE_MAX,
   PLAUSIBLE_MAX, PLAUSIBLE_LINES, PLAUSIBLE_PATIENTS, MIN_CODE_CHARS)
by_npi_year <- dbGetQuery(con, sql)

# What the shape filter removed, named rather than assumed. If this ever
# reports a large number, the codes being dropped need looking at before the
# run is trusted -- four-digit revenue codes are legitimate and must survive.
dropped <- dbGetQuery(con, sprintf(r"(
  SELECT coalesce(s.HCPCS_CODE, '<NULL>') AS hcpcs_code, count(*) AS rows
    FROM cohort_npis c
    INNER JOIN spend_db.spending s ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
   WHERE s.CLAIM_FROM_MONTH IS NOT NULL
     AND (s.HCPCS_CODE IS NULL OR length(trim(s.HCPCS_CODE)) < %d)
   GROUP BY 1 ORDER BY rows DESC)", MIN_CODE_CHARS))
if (nrow(dropped)) {
  cat(sprintf("Excluded %s row(s) on HCPCS code shape (<%d chars): %s\n",
              format(sum(dropped$rows), big.mark = ","), MIN_CODE_CHARS,
              paste(sprintf("%s=%d", dropped$hcpcs_code, dropped$rows), collapse = ", ")))
} else {
  cat(sprintf("Excluded 0 rows on HCPCS code shape (<%d chars)\n", MIN_CODE_CHARS))
}

n_excluded <- sum(by_npi_year$n_rows_over_bound)
cat(sprintf("Matched: %s NPI-years across %s distinct NPIs, %d-%d\n",
            format(nrow(by_npi_year), big.mark = ","),
            length(unique(by_npi_year$npi)),
            min(by_npi_year$year), max(by_npi_year$year)))
report_bound <- function(label, n, ceiling, unit = "") {
  cat(sprintf("Rows excluded from %s for exceeding the %s%s plausibility bound: %d%s\n",
              label, unit, format(ceiling, big.mark = ",", scientific = FALSE), n,
              if (n == 0) " (none -- bound not triggered in this cohort)" else ""))
}
report_bound("total_paid_bounded",  n_excluded,                                  PLAUSIBLE_MAX,      "$")
report_bound("n_claim_lines",       sum(by_npi_year$n_rows_over_line_bound),     PLAUSIBLE_LINES)
report_bound("n_patients_summed",   sum(by_npi_year$n_rows_over_patient_bound),  PLAUSIBLE_PATIENTS)

write_csv(by_npi_year, "artifacts/tmsis_medicaid_spending_cohort_by_year.csv", na = "")
cat("written: artifacts/tmsis_medicaid_spending_cohort_by_year.csv\n")
