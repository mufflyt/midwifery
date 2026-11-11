#!/usr/bin/env Rscript
# =============================================================================
# Medicaid documented activity by month and year (spec Workstream C)
# =============================================================================
# The DOGE Medicaid spending-by-NDC file carries CLAIM_FROM_MONTH, so it can
# say WHEN a midwife had a paid Medicaid claim -- not merely that she ever
# did. That distinction is the point of this workstream: enrolment is
# administrative presence, a claim is documented activity, and the two must
# not be collapsed.
#
# THE SPEC ASKS FOR 2013-2024. THE DATA STARTS 2018. CLAIM_FROM_MONTH runs
# 2018-01 to 2024-12 -- 84 distinct months, 21,515,000 rows, no month-level
# gaps. There is no 2013-2017 Medicaid spending to reconstruct, and emitting
# empty years would read as non-participation rather than as absence of
# data. The series is 2018-2024 and says so.
#
# TWO ROLES, KEPT APART. A midwife appears as PRESCRIBING_PROVIDER_NPI_NUM
# (she wrote it) or BILLING_PROVIDER_NPI_NUM (her NPI was billed under).
# They answer different questions and a provider can be either, both or
# neither in a month, so they are never summed into one "active" flag.
#
# WHAT ABSENCE MEANS. A midwife with no Medicaid claim in a year is not
# inactive, not retired, and not absent from practice. She may serve a
# commercial or Medicare caseload, practise in a state whose data is not in
# this extract, or bill under an organisation. Absence of a claim is absence
# of evidence in ONE program.
#
# NO MONTHLY CLAIM IS INVENTED FROM AN ANNUAL ONE. The source is monthly, so
# the monthly artifact is a direct observation; the annual artifact is a
# roll-up of observed months and records how many months each year rests on.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          <volume>/doge_opendata/medicaid_provider_spending_ndc_2026_07_24/
#            medicaid-provider-spending-ndc.parquet
# Outputs: artifacts/medicaid_midwife_activity_by_month.csv
#          artifacts/medicaid_midwife_activity_by_year.csv
#          artifacts/medicaid_activity_coverage.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
SPEND_REL <- file.path("doge_opendata",
                       "medicaid_provider_spending_ndc_2026_07_24",
                       "medicaid-provider-spending-ndc.parquet")

#' Cohort Medicaid claim activity, one row per NPI-month-role
#'
#' @param con [DBIConnection] DuckDB with `cohort_npi(npi)` present.
#' @param parquet [character] path to the spending file.
#' @return [data.frame] npi, claim_month ("YYYY-MM"), role
#'   ("prescribing"/"billing"), n_claim_lines, n_beneficiaries, total_paid.
#'   Distinct NPI-month-role; duplicate NDC lines are aggregated, so a
#'   provider with 400 drug rows in a month counts once as a provider.
medicaid_activity_by_month <- function(con, parquet) {
  q <- sprintf("
    WITH src AS (
      SELECT trim(CAST(s.PRESCRIBING_PROVIDER_NPI_NUM AS VARCHAR)) AS npi,
             'prescribing' AS role, s.CLAIM_FROM_MONTH AS claim_month,
             s.TOTAL_CLAIM_LINES AS lines, s.TOTAL_UNIQUE_BENEFICIARIES AS benes,
             s.TOTAL_PAID AS paid
        FROM read_parquet(%1$s) s
       WHERE s.PRESCRIBING_PROVIDER_NPI_NUM IS NOT NULL
      UNION ALL
      SELECT trim(CAST(s.BILLING_PROVIDER_NPI_NUM AS VARCHAR)) AS npi,
             'billing' AS role, s.CLAIM_FROM_MONTH AS claim_month,
             s.TOTAL_CLAIM_LINES AS lines, s.TOTAL_UNIQUE_BENEFICIARIES AS benes,
             s.TOTAL_PAID AS paid
        FROM read_parquet(%1$s) s
       WHERE s.BILLING_PROVIDER_NPI_NUM IS NOT NULL
    )
    SELECT src.npi, src.claim_month, src.role,
           SUM(src.lines) AS n_claim_lines,
           SUM(src.benes) AS n_beneficiaries,
           SUM(src.paid)  AS total_paid
      FROM src JOIN cohort_npi c ON c.npi = src.npi
     WHERE src.claim_month IS NOT NULL
       AND length(trim(src.claim_month)) > 0
     GROUP BY 1, 2, 3", DBI::dbQuoteString(con, parquet))
  DBI::dbGetQuery(con, q)
}

if (sys.nframe() == 0L) {
  cohort <- readr::read_csv(COHORT, col_types = readr::cols(.default = "c"),
                            progress = FALSE) %>%
    filter(cohort_member == "TRUE") %>%
    transmute(npi = trimws(npi)) %>%
    filter(!is.na(npi), nzchar(npi)) %>% distinct()
  base::message(sprintf("cohort NPIs: %s", format(nrow(cohort), big.mark = ",")))

  parquet <- samsung_volume_path(SPEND_REL, must_exist = FALSE)
  if (is.na(parquet)) stop("spending parquet not mounted", call. = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("SET temp_directory=%s",
                              DBI::dbQuoteString(con, tempdir())))
  DBI::dbWriteTable(con, "cohort_npi", as.data.frame(cohort), overwrite = TRUE)

  base::message("aggregating claim lines to NPI-month-role ...")
  m <- medicaid_activity_by_month(con, parquet)
  stopifnot(nrow(m) > 0)
  m$year <- as.integer(substr(m$claim_month, 1, 4))
  # Validate the date field rather than trusting it: every month must parse
  # and fall inside the range the file advertises.
  bad <- m[is.na(m$year) | m$year < 2000L | m$year > 2100L, , drop = FALSE]
  if (nrow(bad))
    stop(sprintf("%d rows carry an unparseable CLAIM_FROM_MONTH", nrow(bad)),
         call. = FALSE)

  y <- m %>% group_by(npi, year, role) %>%
    summarise(n_months_with_claims = dplyr::n_distinct(claim_month),
              n_claim_lines = sum(n_claim_lines, na.rm = TRUE),
              n_beneficiaries = sum(n_beneficiaries, na.rm = TRUE),
              total_paid = sum(total_paid, na.rm = TRUE),
              first_month = min(claim_month), last_month = max(claim_month),
              .groups = "drop") %>%
    mutate(evidence_type = "observed", activity_type = role)
  # Every annual row must rest on at least one real claim month.
  stopifnot(all(y$n_months_with_claims >= 1L))

  cov <- m %>% group_by(year, role) %>%
    summarise(n_midwives = dplyr::n_distinct(npi),
              n_months_observed = dplyr::n_distinct(claim_month),
              .groups = "drop") %>%
    mutate(pct_of_cohort = round(100 * n_midwives / nrow(cohort), 2))

  write_with_provenance(m, "artifacts/medicaid_midwife_activity_by_month.csv",
                        inputs = COHORT, na = "")
  write_with_provenance(y, "artifacts/medicaid_midwife_activity_by_year.csv",
                        inputs = COHORT, na = "")
  write_with_provenance(cov, "artifacts/medicaid_activity_coverage.csv",
                        inputs = COHORT, na = "")

  base::message(sprintf("\nmonthly: %s rows, %s midwives, %s..%s",
                        format(nrow(m), big.mark = ","),
                        format(dplyr::n_distinct(m$npi), big.mark = ","),
                        min(m$claim_month), max(m$claim_month)))
  print(as.data.frame(cov), row.names = FALSE)
}
