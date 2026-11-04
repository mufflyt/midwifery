#!/usr/bin/env Rscript
# =============================================================================
# State-name pairwise agreement, every viable source pair, not just vs NPPES
# =============================================================================
# build_state_source_audit.R only ever compares each source against NPPES --
# documented in its own header as a deliberate scope choice, and flagged in
# the published audit as Limitation #01 ("none of the other 45 possible
# source-pairs... have been compared to each other"). That leaves real
# overlap unexamined: Open Payments and PECOS revalidation both carry
# 2021-2025 per-NPI-year state, and eight sources (DAC, PECOS revalidation,
# Facility Affiliation, Healthgrades, Doximity, State Boards of Nursing,
# CMS NDH, NPPES) all have a 2026 row for the same cohort -- a same-year
# cross-section C(8,2) = 28 pairs wide that NPPES-anchoring never surfaces.
#
# This script builds the exact same per-source (npi, year, state) frames
# build_state_source_audit.R does (single-snapshot sources get year = 2026L,
# matching how that script already treats them as "current only"), then
# hands ALL of them at once to mysterymroster::attribute_agreement(), which
# compares every pair via combn() rather than one source against a fixed
# anchor. Medicaid is excluded here, same as upstream: it already has its
# own richer Concordant/Discordant/Multistate/Indeterminate classification
# (R/lib/medicaid_state_concordance.R) that a flat agree/disagree percentage
# would be a step backward from.
#
# attribute_agreement() merges by (npi, year) -- it only ever compares two
# sources' records for the SAME year, same as build_state_source_audit.R's
# own same_year/current_only split. It does not invent a finer-grained
# freshness signal than any of these sources actually carries at the
# per-record level (see Limitation #03 on NPPES's own un-extracted
# last_update_date).
#
# Output: artifacts/state_source_audit_pairwise_agreement.csv --
#   source_a, source_b, year, n_compared, n_agree, pct_agree, involves_nppes,
#   trace (TRUE if n_compared < 30, mysteryroster's own "below reportability"
#   bar, matching this audit's existing legend).
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})
devtools::load_all("~/Documents/GitHub/mysteryroster", quiet = TRUE)

source(file.path("R", "lib", "clean_state.R"))

# --- NPPES --------------------------------------------------------------
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi))

# --- DAC / Physician Compare, 2013-2016 + 2026 ---------------------------
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi))

# --- Open Payments, 2015-2025 --------------------------------------------
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "\\d{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi))

# --- PECOS revalidation/reassignment, 2021-2026 --------------------------
pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv",
                   col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state))

# --- Facility Affiliation / CCN-NPI, current (2026) only -----------------
fa <- read_csv("artifacts/dac_facility_affiliations.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(state)) %>% filter(!is.na(npi)) %>%
  group_by(npi, year) %>% slice(1) %>% ungroup()

# --- Healthgrades, current scrape only -----------------------------------
hg <- read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(hg_npi), year = 2026L, state = clean_state(hg_state)) %>%
  filter(!is.na(npi), nzchar(npi))

# --- Doximity -------------------------------------------------------------
dox <- read_csv("artifacts/doximity_public_matched.csv", col_types = cols(.default = "c"), progress = FALSE)
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(certification_number, npi = trimws(npi))
dox <- dox %>% left_join(link, by = "certification_number", relationship = "many-to-one") %>%
  transmute(npi = trimws(npi), year = as.integer(substr(date_modified, 1, 4)), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(year))

# --- State Boards of Nursing: 7 states, current snapshot only -----------
bon_files <- Sys.glob("artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv")
bon <- bind_rows(lapply(bon_files, function(f) read_csv(f, col_types = cols(.default = "c"), progress = FALSE))) %>%
  filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(live_bon_state)) %>%
  filter(!is.na(npi), nzchar(npi))

# --- FHIR / CMS National Directory of Healthcare Providers, current only -
ndh <- read_csv("artifacts/cms_ndh_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(toupper(ndh_found) %in% c("TRUE", "1")) %>%
  mutate(state = clean_state(str_match(ndh_addresses, "\\b([A-Z]{2})\\s+\\d{5}")[, 2])) %>%
  transmute(npi = trimws(npi), year = 2026L, state) %>% filter(!is.na(npi), !is.na(state))

sources <- list(
  nppes = nppes, dac_physician_compare = dac_all, open_payments = op_all,
  pecos_revalidation = pecos, facility_affiliation_ccn = fa, healthgrades = hg,
  doximity = dox, state_boards_of_nursing = bon, cms_ndh_fhir = ndh
)

ag <- attribute_agreement(sources, attribute = "state", id = "npi", year = "year")
summ <- attribute_agreement_summary(ag) %>%
  mutate(involves_nppes = source_a == "nppes" | source_b == "nppes",
         trace = n_compared < 30) %>%
  arrange(desc(involves_nppes), year, source_a, source_b)

write_csv(summ, "artifacts/state_source_audit_pairwise_agreement.csv")

cat(sprintf("Pairwise rows: %d total (%d involve NPPES, %d are source-vs-source only; %d below the 30-NPI trace bar)\n",
            nrow(summ), sum(summ$involves_nppes), sum(!summ$involves_nppes), sum(summ$trace)))
cat("\n=== Non-NPPES pairs, real (n_compared >= 30) ===\n")
print(as.data.frame(summ %>% filter(!involves_nppes, !trace)), row.names = FALSE)
cat("\n=== Non-NPPES pairs, trace only (n_compared < 30, excluded from the write-up) ===\n")
print(as.data.frame(summ %>% filter(!involves_nppes, trace) %>% select(source_a, source_b, year, n_compared)), row.names = FALSE)

cat("\n=== Sanity check: NPPES pairs here vs. build_state_source_audit.R's own numbers ===\n")
print(as.data.frame(summ %>% filter(involves_nppes, !trace) %>%
                       select(source_a, source_b, year, n_compared, pct_agree)), row.names = FALSE)
