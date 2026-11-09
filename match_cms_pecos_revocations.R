#!/usr/bin/env Rscript
# =============================================================================
# CMS PECOS Medicare revocation cross-reference (NPI-keyed, no name matching)
# =============================================================================
# CMS's public "Revoked Medicare Providers and Suppliers" file (opendata.hhs.gov,
# this snapshot updated 2026-03-02) is a PECOS re-enrollment bar list,
# Medicare-specific (not Medicaid): providers CMS barred from re-enrolling
# after revoking their billing privileges. NPI-keyed, so this is a direct join
# rather than a name-matching problem, and the revocation reason and dates are
# CMS's own administrative-action record rather than an inferred signal --
# higher-confidence than the CMS NDH hhs_in_exclusion_list flag
# (docs/TECHNICAL_APPENDIX_CMS_NDH.md s5: only 10/153 of THAT flag verified
# against the real public LEIE by NPI).
#
# One row per analytic-cohort NPI (cohort_member == TRUE in the frozen
# linkage) -- the SAME population cms_ndh_midwives.csv covers, so the two
# sources combine cleanly in build_federal_adverse_action_flags.R.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (cohort_member == TRUE)
#          DuckDB table cms_pecos_revoked_providers (load_cms_pecos_revocations_
#          to_duckdb.R; the raw CMS file lives outside the repo)
# Output : artifacts/cms_pecos_revoked_providers_cohort.csv (tracked, no names:
#          npi + flag + reason/dates only -- names add nothing a join needs)
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr)
})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "join_safety.R"))

FROZEN <- "artifacts/amcb_npi_linkage_FROZEN.csv"
OUT    <- "artifacts/cms_pecos_revoked_providers_cohort.csv"

coh <- read_csv(FROZEN, col_types = cols(.default = "c"), show_col_types = FALSE,
                 progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>%
  mutate(npi = as.character(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  distinct(npi)
cat(sprintf("cohort NPIs (analytic cohort, cohort_member == TRUE): %s\n",
            format(nrow(coh), big.mark = ",")))

DB <- resolve_midwifery_duckdb()
con <- tryCatch(
  duckdb_connect(DB, read_only = TRUE),
  error = function(e) stop(sprintf(
    "Could not open the DuckDB warehouse at %s: %s", DB, conditionMessage(e)),
    call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
if (!"cms_pecos_revoked_providers" %in% dbListTables(con)) {
  stop(paste0("Table cms_pecos_revoked_providers not found in the warehouse.\n",
              "  Run load_cms_pecos_revocations_to_duckdb.R first."), call. = FALSE)
}

# Collapse to one row per NPI. A real minority of NPIs carry more than one
# revocation event (distinct enrollment IDs, e.g. different reasons/dates);
# concatenating rather than picking one with distinct() silently keeps every
# fact instead of dropping whichever row happened to sort first.
pecos <- dbGetQuery(con, "
  SELECT npi,
         string_agg(DISTINCT revocation_rsn, '; ')      AS revocation_reason,
         string_agg(DISTINCT revocation_efctv_dt, '; ')  AS revocation_effective_date,
         string_agg(DISTINCT reenrollment_bar_exprtn_dt, '; ') AS reenrollment_bar_expiration_date,
         string_agg(DISTINCT provider_type_desc, '; ')   AS provider_type_desc
    FROM cms_pecos_revoked_providers
   WHERE npi IS NOT NULL AND npi <> ''
   GROUP BY npi") %>%
  assert_unique_keys("npi", label = "CMS PECOS revocation table, by NPI")

out <- coh %>%
  left_join(pecos, by = "npi") %>%
  mutate(pecos_revoked = !is.na(revocation_reason)) %>%
  select(npi, pecos_revoked, revocation_reason, revocation_effective_date,
         reenrollment_bar_expiration_date, provider_type_desc)

write_with_provenance(out, OUT, inputs = FROZEN)
cat(sprintf("cohort NPIs checked: %s\nmatched in CMS PECOS revocation file: %s\n",
            format(nrow(out), big.mark = ","), format(sum(out$pecos_revoked), big.mark = ",")))
