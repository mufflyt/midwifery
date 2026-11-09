#!/usr/bin/env Rscript
# =============================================================================
# Medicaid claims-billing activity for four procedures, canonical midwife
# cohort + ABOG Generalist/MFM OB-GYN cohort, 2018-2024
# =============================================================================
# Answers: of the canonical AMCB midwife cohort and the ABOG Generalist/MFM
# OB-GYN cohort (the two valid intrapartum-care comparators per
# load_obstetric_providers.R's documented rule -- REI/GO/FPMRS/MIGS/CFP/PAG
# excluded as non-intrapartum subspecialties), who actually BILLED Medicaid
# for a pap test, urodynamics, IUD insertion/removal, or a vaginal delivery,
# using the HHS Medicaid Provider Spending by HCPCS dataset
# (download_medicaid_provider_spending.py; NOT re-downloaded here).
#
# WHY THIS IS A DIFFERENT QUESTION FROM ENROLLMENT CONCORDANCE. Medicaid
# ENROLLMENT (analyze_medicaid_enrollment_concordance.R) is an administrative
# relationship with a state program -- "an enrolled NPI may never submit a
# claim" (that script's header). This script measures the opposite: actual
# billed claims, which is a stronger "did this provider really see Medicaid
# patients for X" signal, but still not clinical practice location or care
# quality, and claims data has its own gaps (see CAVEATS below).
#
# COHORT, NOT GEOCODED. load_obstetric_providers.R's load_generalists() joins
# the ABOG roster against three geocode sources and keeps only providers with
# usable coordinates (56.4% of generalists) -- a floor built for the
# TRAVEL-TIME analysis. That join is irrelevant and actively harmful here (it
# would silently drop ~44% of real NPIs from a billing-activity question that
# has nothing to do with geography), so this script reads the ABOG NPI roster
# directly and does NOT geocode. Likewise load_midwives() exposes
# certification_number as its join key, not npi, so it is not reused either;
# the midwife cohort is built the same way canonical_active_primary() already
# does, by calling that function directly.
#
# HCPCS CODES (verified 2026-10-26, current code sets -- see commit message
# for the research trail):
#   pap_test          Q0091, G0101
#                      (88141-88175 cytopathology-interpretation codes are
#                      typically billed by a LAB/pathologist, not the
#                      collecting clinician, and are deliberately excluded --
#                      see PROCEDURE_CODES below)
#   urodynamics        51725-51729, 51736, 51741, 51784, 51785, 51797, 51798
#   iud                 58300 (insertion), 58301 (removal)
#   vaginal_delivery    59400, 59409, 59410, 59610, 59612, 59614
#                      (VBAC codes included; antepartum-only code
#                      deliberately excluded -- that is not a delivery)
#
# CAVEATS (read before using this for anything consequential):
#   - Nov-Dec 2024 CLAIM_FROM_MONTH figures decline sharply relative to prior
#     months across the whole dataset (incomplete state submissions per
#     Milliman's analysis of this release) -- do not read a provider's
#     apparent 2024 drop-off as a real practice change without checking this.
#   - TOTAL_PAID has at least one observed row with an implausible value
#     (single NPI/HCPCS/month >$7 trillion) -- this is a known data-quality
#     issue in the raw HHS release, not a bug in this script. TOTAL_PAID is
#     reported here for completeness but TOTAL_CLAIM_LINES / TOTAL_PATIENTS
#     are the more trustworthy activity signals; do not trust TOTAL_PAID
#     sums without auditing for outlier rows first.
#   - BILLING_PROVIDER_NPI_NUM is sometimes blank (capitation/non-claim
#     lines); this script matches on SERVICING_PROVIDER_NPI_NUM only, which
#     is the clinician who actually performed the service.
#   - A provider's absence from this file for a given procedure is not proof
#     they never performed it on a Medicaid patient -- it is proof no claim
#     with a populated HCPCS code and that NPI as servicing provider appears
#     in 2018-2024 T-MSIS outpatient/professional claim lines.
#
# Input : artifacts/amcb_npi_linkage_FROZEN.csv (canonical cohort source)
#         ~/isochrones/artifacts/cohort_tracking_archive/20261012_182448_90267847/
#           abog_inputs/canonical_abog_npi_LATEST.csv (ABOG generalist roster)
#         ~/isochrones/artifacts/isochrones/step_2.5_final_cohort.rds
#           (ABOG subspecialist cohort, for MFM + for de-duplicating
#           generalists who are actually practicing a subspecialty)
#         <MufflySamsung>/DuckDB/medicaid_provider_spending_verified.duckdb
# Output: artifacts/medicaid_procedure_billing_by_npi.csv (person-level)
#         artifacts/medicaid_procedure_billing_summary.csv (group x procedure)
#         (+ .provenance.json beside each)
#
# @family diagnostics
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(DBI); library(duckdb); library(readr); library(tibble)
  library(tidyr); library(purrr)
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

cat("=== Medicaid procedure-billing activity: midwives + OB-GYN Generalist/MFM, 2018-2024 ===\n")

# -- Build the cohort (shared helper -- see R/lib/ob_midwife_cohort.R) --------

cohort <- build_ob_midwife_cohort()
dual_group_excluded <- attr(cohort, "dual_group_excluded")
cat(sprintf("[cohort] combined distinct NPI (dual-group NPI excluded): %s\n", nrow(cohort)))
if (nrow(dual_group_excluded) > 0) {
  cat(sprintf("[cohort] %d NPI excluded as ambiguous (appear in >1 provider_group):\n", nrow(dual_group_excluded) / 2))
  print(dual_group_excluded, n = Inf)
  write_with_provenance(dual_group_excluded,
                         "artifacts/medicaid_procedure_billing_dual_group_npi_excluded.csv",
                         inputs = unlist(OB_MIDWIFE_COHORT_SOURCES, use.names = FALSE))
}

# -- Connect to the spending warehouse ------------------------------------------

db_path <- samsung_volume_path(SPENDING_DUCKDB_RELATIVE)
cat(sprintf("[spending] warehouse: %s\n", db_path))
con <- duckdb_connect(dbdir = db_path, read_only = TRUE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

duckdb::duckdb_register(con, "cohort_npi", cohort)

code_lookup <- imap_dfr(PROCEDURE_CODES, function(codes, category) {
  tibble(hcpcs_code = codes, procedure_category = category)
})
duckdb::duckdb_register(con, "procedure_codes", code_lookup)

# -- Aggregate: NPI x procedure_category, summed across all matching months ----

query <- "
  SELECT
    s.SERVICING_PROVIDER_NPI_NUM AS npi,
    pc.procedure_category,
    COUNT(DISTINCT s.CLAIM_FROM_MONTH)                AS months_with_activity,
    MIN(s.CLAIM_FROM_MONTH)                           AS first_month,
    MAX(s.CLAIM_FROM_MONTH)                           AS last_month,
    SUM(TRY_CAST(s.TOTAL_PATIENTS AS BIGINT))         AS total_patients_summed,
    SUM(TRY_CAST(s.TOTAL_CLAIM_LINES AS BIGINT))      AS total_claim_lines,
    SUM(TRY_CAST(s.TOTAL_PAID AS DOUBLE))             AS total_paid_summed
  FROM spending s
  JOIN cohort_npi c  ON s.SERVICING_PROVIDER_NPI_NUM = c.npi
  JOIN procedure_codes pc ON s.HCPCS_CODE = pc.hcpcs_code
  GROUP BY s.SERVICING_PROVIDER_NPI_NUM, pc.procedure_category
"
billing <- DBI::dbGetQuery(con, query) %>% as_tibble()
cat(sprintf("[spending] NPI x procedure_category rows with billing activity: %s\n", nrow(billing)))

# -- Join cohort membership back in, including zero-activity providers --------

grid <- tidyr::crossing(npi = cohort$npi, procedure_category = names(PROCEDURE_CODES))
person_level <- grid %>%
  left_join(cohort %>% select(npi, provider_group, display_name), by = "npi") %>%
  left_join(billing, by = c("npi", "procedure_category")) %>%
  mutate(
    billed_this_procedure = !is.na(months_with_activity),
    months_with_activity = coalesce(months_with_activity, 0L),
    total_patients_summed = coalesce(total_patients_summed, 0),
    total_claim_lines = coalesce(total_claim_lines, 0),
    total_paid_summed = coalesce(total_paid_summed, 0)
  ) %>%
  arrange(provider_group, procedure_category, desc(total_claim_lines))

cohort_inputs <- unlist(OB_MIDWIFE_COHORT_SOURCES, use.names = FALSE)

out_person <- "artifacts/medicaid_procedure_billing_by_npi.csv"
write_with_provenance(person_level, out_person, inputs = c(cohort_inputs, db_path))
cat(sprintf("  Wrote: %s (%s rows)\n", out_person, nrow(person_level)))

summary_tbl <- person_level %>%
  group_by(provider_group, procedure_category) %>%
  summarise(
    n_cohort = n(),
    n_billed = sum(billed_this_procedure),
    pct_billed = round(100 * n_billed / n_cohort, 1),
    total_claim_lines = sum(total_claim_lines),
    total_patients_summed = sum(total_patients_summed),
    .groups = "drop"
  ) %>%
  arrange(procedure_category, provider_group)

out_summary <- "artifacts/medicaid_procedure_billing_summary.csv"
write_with_provenance(summary_tbl, out_summary, inputs = c(cohort_inputs, db_path))
cat(sprintf("  Wrote: %s (%s rows)\n", out_summary, nrow(summary_tbl)))

cat("=========================================================================\n")
print(summary_tbl, n = Inf)
cat("=========================================================================\n")
