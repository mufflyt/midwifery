#!/usr/bin/env Rscript
# =============================================================================
# State-name coverage and cross-source agreement audit, 10 years
# =============================================================================
# There is no gold standard for a midwife's practice state -- every source
# below is self-reported (NPPES), administratively enrolled (DAC/PECOS/
# PECOS-revalidation/Medicaid), third-party-scraped (Healthgrades/Doximity/
# state BONs), or FHIR-published (NDH). So "agreement" here means PAIRWISE
# agreement against NPPES specifically, not agreement with truth -- NPPES is
# used as the comparison anchor only because every other source's NPI
# already links through the cohort via NPPES, not because it is assumed
# correct (see docs/TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md's
# own framing of the same issue).
#
# FRESHNESS: every source below is dated by ITS OWN record (vintage,
# program_year, snapshot date, or scrape date), never by when this script
# happened to read the file, matching mm_record_staleness.R's
# (~/mysterymedicaid/R/mm_record_staleness.R) principle that a record's
# last-updated date is what tells you which year its information actually
# applies to. Where a source gives only ONE snapshot (Healthgrades, state
# BONs, FHIR/NDH, current DAC/Facility-Affiliation), it is compared only
# against NPPES's CURRENT (2026) snapshot and flagged comparison_basis =
# "current_only" -- it is never silently treated as covering every year.
# Medicaid is the one source with a genuine per-NPI-year independently-dated
# comparison already built (R/lib/medicaid_state_concordance.R,
# classify_state_concordance()) and is folded in as-is rather than
# recomputed into a simple percent-agree number, since its
# Concordant/Discordant/Multistate/Indeterminate classification is more
# informative than a single percentage.
#
# Outputs (tracked, aggregate only -- no NPI-level rows):
#   artifacts/state_source_audit_coverage.csv   source, year, n_rows, n_npis
#   artifacts/state_source_audit_agreement.csv  source, year, comparison_basis,
#                                                n_comparable, n_agree, pct_agree
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr)})

source(file.path("R", "lib", "clean_state.R"))

# --- NPPES: the comparison anchor --------------------------------------------
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), nppes_state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi))
nppes_current <- nppes %>% filter(year == max(year, na.rm = TRUE)) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>% select(npi, nppes_state)

coverage <- list()
agreement <- list()

add_coverage <- function(source, df_year_npi) {
  df_year_npi %>% count(year, name = "n_rows") %>%
    left_join(df_year_npi %>% distinct(npi, year) %>% count(year, name = "n_npis"),
              by = "year", relationship = "one-to-one") %>%
    mutate(source = source) %>% select(source, year, n_rows, n_npis)
}

agree_same_year <- function(source, df) {
  # df: npi, year, state
  df %>% inner_join(nppes, by = c("npi", "year"), relationship = "many-to-one") %>%
    filter(!is.na(state), !is.na(nppes_state)) %>%
    group_by(year) %>%
    summarise(n_comparable = n(), n_agree = sum(state == nppes_state), .groups = "drop") %>%
    mutate(source = source, comparison_basis = "same_year", year = as.character(year),
           pct_agree = round(100 * n_agree / n_comparable, 1)) %>%
    select(source, year, comparison_basis, n_comparable, n_agree, pct_agree)
}

agree_current_only <- function(source, df_npi_state, as_of_label) {
  # df_npi_state: npi, state (single snapshot, no year axis)
  cmp <- df_npi_state %>% inner_join(nppes_current, by = "npi") %>%
    filter(!is.na(state), !is.na(nppes_state))
  tibble(source = source, year = as_of_label, comparison_basis = "current_only",
         n_comparable = nrow(cmp), n_agree = sum(cmp$state == cmp$nppes_state),
         pct_agree = round(100 * sum(cmp$state == cmp$nppes_state) / nrow(cmp), 1))
}

# --- DAC / Physician Compare, 2013-2016 + 2026 -------------------------------
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi))
coverage$dac <- add_coverage("dac_physician_compare", dac_all)
agreement$dac <- agree_same_year("dac_physician_compare", dac_all)

# --- Open Payments, 2015-2024 ------------------------------------------------
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "\\d{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi))
coverage$op <- add_coverage("open_payments", op_all)
agreement$op <- agree_same_year("open_payments", op_all)

# --- PECOS revalidation/reassignment, 2021-2026 ------------------------------
pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv",
                   col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state))
coverage$pecos <- add_coverage("pecos_revalidation", pecos)
agreement$pecos <- agree_same_year("pecos_revalidation", pecos)

# --- Facility Affiliation / CCN-NPI, 2013-2022 + 2026 -----------------------
# 2013-2022 comes from the CCNs already embedded in the historical DAC/
# Physician Compare files themselves (extract_historical_facility_affiliation.R)
# -- CMS's own Facility Affiliation PRODUCT is current-only (confirmed against
# its metastore API 2026-11-04: one dataset, no year in the title), so this is
# the only way to get affiliation history at all. 2023-2025 has no CCN in
# either source (CMS dropped the field from the DAC file in 2023) -- a real
# gap, not an omission.
fa_hist <- read_csv("artifacts/historical_facility_affiliation_cohort_state_by_year.csv",
                     col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state))
fa_cur <- read_csv("artifacts/dac_facility_affiliations.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(state)) %>% filter(!is.na(npi)) %>%
  group_by(npi, year) %>% slice(1) %>% ungroup()
fa_all <- bind_rows(fa_hist, fa_cur) %>% filter(!is.na(npi))
coverage$fa <- add_coverage("facility_affiliation_ccn", fa_all)
agreement$fa <- agree_same_year("facility_affiliation_ccn", fa_all)

# --- Healthgrades, current scrape only ---------------------------------------
hg <- read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(hg_npi), state = clean_state(hg_state)) %>% filter(!is.na(npi), nzchar(npi))
coverage$hg <- tibble(source = "healthgrades", year = 2026L, n_rows = nrow(hg), n_npis = n_distinct(hg$npi))
agreement$hg <- agree_current_only("healthgrades", hg, "~2026-10 (scrape, undated per-record)")

# --- Doximity: has a real per-record date_modified ---------------------------
dox <- read_csv("artifacts/doximity_public_matched.csv", col_types = cols(.default = "c"), progress = FALSE)
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(certification_number, npi = trimws(npi))
dox <- dox %>% left_join(link, by = "certification_number", relationship = "many-to-one") %>%
  transmute(npi = trimws(npi), year = as.integer(substr(date_modified, 1, 4)), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(year))
coverage$dox <- add_coverage("doximity", dox)
agreement$dox <- agree_same_year("doximity", dox)

# --- State Boards of Nursing: 7 states, current snapshot only ---------------
bon_files <- Sys.glob("artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv")
bon <- bind_rows(lapply(bon_files, function(f) {
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE)
})) %>% filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
  transmute(npi = trimws(npi), state = clean_state(live_bon_state)) %>% filter(!is.na(npi), nzchar(npi))
coverage$bon <- tibble(source = "state_boards_of_nursing", year = 2026L, n_rows = nrow(bon), n_npis = n_distinct(bon$npi))
agreement$bon <- agree_current_only("state_boards_of_nursing", bon, "2026-10 (7 states: CO/CT/FL/IL/PA/TX/WA)")

# --- FHIR / CMS National Directory of Healthcare Providers, current only ----
ndh <- read_csv("artifacts/cms_ndh_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(toupper(ndh_found) %in% c("TRUE", "1")) %>%
  mutate(state = clean_state(str_match(ndh_addresses, "\\b([A-Z]{2})\\s+\\d{5}")[, 2])) %>%
  transmute(npi = trimws(npi), state) %>% filter(!is.na(npi), !is.na(state))
coverage$ndh <- tibble(source = "cms_ndh_fhir", year = 2026L, n_rows = nrow(ndh), n_npis = n_distinct(ndh$npi))
agreement$ndh <- agree_current_only("cms_ndh_fhir", ndh, "2026-10 (bulk pull; meta.lastUpdated available per-record, not yet exploited here)")

# --- NPPES's own coverage, for context ---------------------------------------
coverage$nppes <- add_coverage("nppes", nppes %>% filter(!is.na(npi)))

# --- Medicaid: already independently computed with a richer classification --
medicaid_by_year <- read_csv("artifacts/medicaid_enrollment_concordance_any_time_by_year.csv",
                             col_types = cols(.default = "c"), progress = FALSE)
write_csv(medicaid_by_year, "artifacts/state_source_audit_medicaid_classification_by_year.csv")

# =============================================================================
cov <- bind_rows(coverage) %>% arrange(source, year)
agr <- bind_rows(agreement) %>% arrange(source, year)
write_csv(cov, "artifacts/state_source_audit_coverage.csv")
write_csv(agr, "artifacts/state_source_audit_agreement.csv")

cat("=== COVERAGE (n NPI-year rows by source) ===\n")
print(as.data.frame(cov), row.names = FALSE)
cat("\n=== AGREEMENT vs NPPES ===\n")
print(as.data.frame(agr), row.names = FALSE)
cat("\n=== MEDICAID (separately classified, see artifacts/medicaid_enrollment_concordance_any_time_by_year.csv) ===\n")
print(as.data.frame(medicaid_by_year), row.names = FALSE)
