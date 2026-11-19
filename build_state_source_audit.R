#!/usr/bin/env Rscript
# =============================================================================
# State-name coverage and cross-source agreement audit, 2007-2026
# =============================================================================
# THE WINDOW IS PER SOURCE, AND "10 YEARS" STOOD HERE UNTIL 2026-11-18. It was
# true when this script was written and quietly stopped being true as the NPPES
# panel grew backwards: the anchor now spans 2007-2026 (20 years) and the DAC
# series 2013-2026 (14). No single source covers the whole window, four of the
# eleven are a single current snapshot, and each source is compared only in the
# years it actually carries a state -- so one number in a title was never going
# to describe this and is not replaced by a better one. The declared window per
# source is config/state_source_audit_sources.csv, which the block below
# validates before anything is read; restating it here would be the second
# inventory that file exists to prevent.
#
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
source(file.path("R", "lib", "source_coverage.R"))

# --- every input is declared before any of it is read ------------------------
# WHY THIS BLOCK IS FIRST. Until 2026-11-18 only Open Payments and the Boards
# of Nursing were under the coverage contract; the other eight sources were
# read from path literals in this script, and their expected windows existed
# only as prose in the technical appendix. So a missing NPPES year, a PECOS
# file that stopped at 2024, or a re-scrape that widened Doximity's window
# would all have changed a published figure without failing anything -- the
# same class of defect as the Open Payments glob, just without a glob.
#
# The paths below now come from config/state_source_audit_sources.csv through
# declared_path(), which returns only inputs the coverage audit accepted. A
# literal here would be a second inventory: one this script trusts and nothing
# validates. No input of an audited source is named by a literal in this file
# any more -- what remains is the frozen AMCB linkage, which is a cohort
# definition rather than a state source, and this script's own outputs.
#
# A source split across two files is asked for by year, because that is what
# decides which file: DAC's historical vintages are declared for 2013-2025 and
# its current CMS pull for 2026, so asking for 2025 IS the request for the
# historical panel; declared_path() errors rather than guessing if a two-file
# source is asked for without a year.
#
# `panel` sources keep every year in one file and are checked against the
# years that file actually holds, in both directions -- a declared year the
# panel lost is refuted, a year nobody declared is refused. See
# R/lib/source_coverage.R.
AUDITED_SOURCES <- c("nppes", "dac_physician_compare", "pecos_revalidation",
                     "facility_affiliation_ccn", "healthgrades", "doximity",
                     "cms_ndh_fhir", "medicaid_enrollment", "medicare_claims")
audit_coverage <- validate_source_coverage(read_source_manifest(),
                                           publication_mode = TRUE,
                                           source_ids = AUDITED_SOURCES)
NPPES_PANEL <- declared_path(audit_coverage, "nppes")
DAC_HISTORY <- declared_path(audit_coverage, "dac_physician_compare", 2025L)
DAC_CURRENT <- declared_path(audit_coverage, "dac_physician_compare", 2026L)
PECOS_HISTORY <- declared_path(audit_coverage, "pecos_revalidation")
FA_HISTORY <- declared_path(audit_coverage, "facility_affiliation_ccn", 2022L)
FA_CURRENT <- declared_path(audit_coverage, "facility_affiliation_ccn", 2026L)
HEALTHGRADES_SCRAPE <- declared_path(audit_coverage, "healthgrades")
DOXIMITY_MATCHED <- declared_path(audit_coverage, "doximity")
NDH_FHIR <- declared_path(audit_coverage, "cms_ndh_fhir")
MEDICAID_BY_YEAR <- declared_path(audit_coverage, "medicaid_enrollment")
MEDICARE_CLAIMS <- declared_path(audit_coverage, "medicare_claims")

# --- NPPES: the comparison anchor --------------------------------------------
nppes_raw <- read_csv(NPPES_PANEL, col_types = cols(.default = "c"),
                      progress = FALSE)
# WHAT STATE CLEANING THREW AWAY, SAID OUT LOUD. clean_state() maps anything
# it does not recognise to NA, which is correct and was silent. The 2026
# panel carries 456 providers with a military postal code (AE, AP, AA) plus
# base names and Canadian provinces; none is a United States practice state,
# all of them leave this comparison, and until now none was counted. The
# guard also stops the build if a source ever loses ALL of its states, which
# is a format change rather than an empty source.
report_state_cleaning(nppes_raw$practice_state, "nppes practice_state")
nppes <- nppes_raw %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year),
            nppes_state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi))
# THE YEAR TRAVELS WITH THE SNAPSHOT. select(npi, nppes_state) used to drop
# it here, which left state_agreement_current_only() unable to check what it
# was comparing against -- see R/lib/state_agreement.R.
nppes_current <- nppes %>% filter(year == max(year, na.rm = TRUE)) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>% select(npi, nppes_state, year)

coverage <- list()
agreement <- list()

# The three functions that compute every published percentage used to live
# here, closed over `nppes` and `nppes_current` from this script, which meant
# nothing could call them without running the whole audit. They now take the
# comparison target as an argument and are tested directly; see
# R/lib/state_agreement.R and tests/test_state_agreement_saboteurs.R.
source(file.path("R", "lib", "state_agreement.R"))
agree_same_year <- function(source, df) {
  state_agreement_same_year(source, df, nppes)
}
# `source_year` is stated per source rather than defaulted, because a default
# is the thing that went wrong: every current-only source here happens to be a
# 2026 snapshot today, and a default would keep saying 2026 after one of them
# stopped being re-harvested.
agree_current_only <- function(source, df_npi_state, as_of_label, source_year) {
  state_agreement_current_only(source, df_npi_state, nppes_current,
                               as_of_label, source_year)
}

# --- DAC / Physician Compare, 2013-2016 + 2026 -------------------------------
hist_dac <- read_csv(DAC_HISTORY,
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv(DAC_CURRENT,
                    col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi))
coverage$dac <- add_coverage("dac_physician_compare", dac_all)
agreement$dac <- agree_same_year("dac_physician_compare", dac_all)

# --- Open Payments, declared window 2021-2025 --------------------------------
# Window and year both come from the declared-coverage contract, not from a
# glob and not from the filename -- see R/lib/open_payments_state_series.R
# for the two defects that cost the 2026-11-12 build four of its five years.
# 2015-2020 are present but declared ineligible: CNMs only became reportable
# covered recipients in program year 2021.
source(file.path("R", "lib", "open_payments_state_series.R"))
op_all <- read_open_payments_state_series(publication_mode = TRUE)$rows
coverage$op <- add_coverage("open_payments", op_all)
agreement$op <- agree_same_year("open_payments", op_all)

# --- PECOS revalidation/reassignment, 2021-2026 ------------------------------
pecos <- read_csv(PECOS_HISTORY,
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
fa_hist <- read_csv(FA_HISTORY,
                     col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state))
fa_cur <- read_csv(FA_CURRENT,
                   col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(state)) %>% filter(!is.na(npi)) %>%
  group_by(npi, year) %>% slice(1) %>% ungroup()
fa_all <- bind_rows(fa_hist, fa_cur) %>% filter(!is.na(npi))
coverage$fa <- add_coverage("facility_affiliation_ccn", fa_all)
agreement$fa <- agree_same_year("facility_affiliation_ccn", fa_all)

# --- Healthgrades, current scrape only ---------------------------------------
hg <- read_csv(HEALTHGRADES_SCRAPE,
               col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(hg_npi), state = clean_state(hg_state)) %>% filter(!is.na(npi), nzchar(npi))
coverage$hg <- tibble(source = "healthgrades", year = 2026L, n_rows = nrow(hg), n_npis = n_distinct(hg$npi))
agreement$hg <- agree_current_only("healthgrades", hg, "~2026-10 (scrape, undated per-record)", 2026L)

# --- Doximity: has a real per-record date_modified ---------------------------
dox <- read_csv(DOXIMITY_MATCHED,
                col_types = cols(.default = "c"), progress = FALSE)
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(certification_number, npi = trimws(npi))
dox <- dox %>% left_join(link, by = "certification_number", relationship = "many-to-one") %>%
  transmute(npi = trimws(npi), year = as.integer(substr(date_modified, 1, 4)), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(year))
coverage$dox <- add_coverage("doximity", dox)
agreement$dox <- agree_same_year("doximity", dox)

# --- State Boards of Nursing: declared boards, current snapshot only --------
# THE LABEL IS COMPUTED, NOT ASSERTED, and the reader is shared with the two
# other producers that consume these files -- see R/lib/bon_state_snapshot.R
# for why all three stopped globbing. The agreement number this produces is
# address concordance within a state-matched sample, NOT independent
# agreement: every board harvester selects its candidates with nppes_state ==
# its own state, so a high value is close to structurally guaranteed and must
# not be ranked against the genuinely independent pairs.
source(file.path("R", "lib", "bon_state_snapshot.R"))
bon_snapshot <- read_bon_state_snapshot(publication_mode = TRUE)

coverage$bon <- tibble(source = "state_boards_of_nursing", year = 2026L,
                       n_rows = nrow(bon_snapshot$comparable),
                       n_npis = n_distinct(bon_snapshot$comparable$npi))
agreement$bon <- agree_current_only("state_boards_of_nursing",
                                    bon_snapshot$comparable,
                                    bon_snapshot$label, 2026L)

# --- FHIR / CMS National Directory of Healthcare Providers, current only ----
ndh <- read_csv(NDH_FHIR,
                col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(toupper(ndh_found) %in% c("TRUE", "1")) %>%
  mutate(state = clean_state(str_match(ndh_addresses, "\\b([A-Z]{2})\\s+\\d{5}")[, 2])) %>%
  transmute(npi = trimws(npi), state) %>% filter(!is.na(npi), !is.na(state))
coverage$ndh <- tibble(source = "cms_ndh_fhir", year = 2026L, n_rows = nrow(ndh), n_npis = n_distinct(ndh$npi))
agreement$ndh <- agree_current_only("cms_ndh_fhir", ndh, "2026-10 (bulk pull; meta.lastUpdated available per-record, not yet exploited here)", 2026L)

# --- Medicare claims, Part B + Part D collapsed to one claim per NPI-year ----
# The two products share one claims lineage and measured zero state conflicts
# on 41,953 NPI-years, so they enter as a single family rather than as two
# votes -- see build_medicare_claims_state_series.R and
# artifacts/cohort_midwives_medicare_claims_collapse_audit.csv.
medicare_claims <- read_csv(MEDICARE_CLAIMS,
                            col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(year))
coverage$mc <- add_coverage("medicare_claims", medicare_claims)
agreement$mc <- agree_same_year("medicare_claims", medicare_claims)

# --- NPPES's own coverage, for context ---------------------------------------
coverage$nppes <- add_coverage("nppes", nppes %>% filter(!is.na(npi)))

# --- Medicaid: already independently computed with a richer classification --
medicaid_by_year <- read_csv(MEDICAID_BY_YEAR,
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
