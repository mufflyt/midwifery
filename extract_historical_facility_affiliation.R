#!/usr/bin/env Rscript
# =============================================================================
# Historical facility affiliation, 2013-2022, from the DAC's own embedded CCNs
# =============================================================================
# CMS's current "Facility Affiliation" product (extract_dac_facility_affiliations.R)
# is a single always-current snapshot -- confirmed 2026-11-04 against CMS's own
# metastore API (one dataset entry, no year in the title, one distribution,
# modified 2026-10-02). CMS does not archive it.
#
# But the historical Physician Compare / DAC vintages extracted by
# extract_physician_compare_historical_midwives.R already carry hospital
# affiliation embedded in the file itself -- "Claims based hospital affiliation
# CCN 1-5" (2013-2016, NBER) / hosp_afl_1..5 (2017-2022, nber_my_duckdb.duckdb)
# -- as ccn_1..ccn_5 in artifacts/physician_compare_historical_midwives.csv.
# CMS dropped the field from the file itself starting 2023 (confirmed: 0% fill
# 2023-2025). Fill rate among the years it exists: 83.2% (2013) declining to
# ~26-31% (2019-2022) -- a real decline in how often CMS's own data carries a
# reported hospital affiliation at all, not a processing artifact; reported as
# observed; not explained further here.
#
# Same CCN -> cms_hospital_info join as extract_dac_facility_affiliations.R
# (a hospital's CCN and state don't change year to year, so resolving a
# HISTORICAL CCN against the CURRENT registry is safe), PLUS a prefix fallback
# for the CCNs that registry has never held.
#
# THE REGISTRY IS HOSPITALS; FACILITY AFFILIATION IS NOT. cms_hospital_info
# holds 5,421 hospitals, while a CCN here may belong to a hospice, home health
# agency, nursing home, dialysis facility or inpatient rehab unit. Measured on
# the 2026-10 facility-affiliation snapshot, the registry join alone resolves
# 4,528 of 41,034 distinct CCNs -- 11.0%. The remaining 89% were never missing
# a state: a CCN's first two characters ARE its state code. Adding that
# fallback takes state resolution to 87.8% and leaves 5,000 CCNs with prefixes
# no hospital uses, which stay NA and are counted. Validated on the 4,528 CCNs
# where both routes answer: they agree on 4,528, 100.0%. See R/lib/ccn_state.R,
# which derives the prefix map from the registry rather than hardcoding CMS's
# list, and refuses to return one that is not 1:1.
#
# A named facility and a known state are now reported separately, because they
# are different questions and only the first needs the registry.
#
# ONE STATE PER NPI-YEAR, CHOSEN DETERMINISTICALLY. This used to take her FIRST
# resolved CCN's state -- row order from the source file, arbitrary -- so
# reordering the input silently changed her state. It is now the MODAL state
# (most CCNs that year, ties alphabetical), the same rule the Medicaid source
# in build_cross_source_comparison.R uses. n_states_this_year is written
# alongside so multiplicity is a column rather than an inference.
#
# Inputs : artifacts/physician_compare_historical_midwives.csv
#          cms_hospital_info (MEDICARE_DUCKDB)
# Outputs: artifacts/historical_facility_affiliation_ccn_level.csv (NPI-year-CCN level, gitignored)
#          artifacts/historical_facility_affiliation_cohort_state_by_year.csv (one row per NPI-year, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr); library(DBI); library(duckdb)})
source("R/lib/common_helpers.R")
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "ccn_state.R"))  # resolve_ccn_state(): registry first, CCN prefix second

hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), vintage,
            ccn_1, ccn_2, ccn_3, ccn_4, ccn_5)

long_ccn <- hist_dac %>%
  pivot_longer(cols = starts_with("ccn_"), names_to = "ccn_slot", values_to = "ccn") %>%
  mutate(ccn = pad_ccn(ccn)) %>%
  filter(!is.na(ccn), !is.na(npi))
cat(sprintf("Historical DAC vintages 2013-2022: %s CCN-level rows, %s distinct NPI-years with at least one CCN\n",
            format(nrow(long_ccn), big.mark = ","),
            format(nrow(distinct(long_ccn, npi, year)), big.mark = ",")))

DB <- resolve_midwifery_duckdb()
con <- duckdb_connect(DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
hosp <- dbGetQuery(con, "
  SELECT facility_id, facility_name, state, hospital_type, hospital_ownership,
         meets_criteria_for_birthing_friendly_designation AS birthing_friendly
    FROM cms_hospital_info") %>%
  mutate(ccn = pad_ccn(facility_id)) %>%
  arrange(ccn, facility_name) %>%
  distinct(ccn, .keep_all = TRUE)

ccn_level <- long_ccn %>% left_join(hosp, by = "ccn")

# NAMING A FACILITY AND NAMING ITS STATE ARE TWO QUESTIONS, and conflating them
# cost this script most of its rows. cms_hospital_info is 5,421 HOSPITALS; a
# CCN belonging to a hospice, home health agency, nursing home or dialysis
# facility is not in it, so the left join above returns NA for both the name
# and the state -- and the state was never missing. It is the first two
# characters of the CCN. See R/lib/ccn_state.R for the derivation and for why
# the registry still wins wherever it has an answer.
cw <- ccn_state_crosswalk(hosp, ccn_col = "ccn", state_col = "state")
ccn_level <- ccn_level %>%
  mutate(state_method = resolve_ccn_state_method(ccn, cw),
         state = ifelse(is.na(state), resolve_ccn_state(ccn, cw), state))

unresolved <- sum(is.na(ccn_level$facility_name))
cat(sprintf("resolved to a named hospital: %s / %s (%.1f%%)\n",
            format(sum(!is.na(ccn_level$facility_name)), big.mark = ","),
            format(nrow(ccn_level), big.mark = ","),
            100 * mean(!is.na(ccn_level$facility_name))))
cat(sprintf("resolved to a STATE: %s / %s (%.1f%%) -- %s by registry, %s by CCN prefix, %s unresolved\n",
            format(sum(!is.na(ccn_level$state)), big.mark = ","),
            format(nrow(ccn_level), big.mark = ","),
            100 * mean(!is.na(ccn_level$state)),
            format(sum(ccn_level$state_method == "registry"), big.mark = ","),
            format(sum(ccn_level$state_method == "prefix"), big.mark = ","),
            format(sum(ccn_level$state_method == "unresolved"), big.mark = ",")))
write_csv(ccn_level, "artifacts/historical_facility_affiliation_ccn_level.csv", na = "")

# WAS first(state) -- "row order from the source file, arbitrary", as this
# script's own header admitted. A midwife with CCNs in two states got whichever
# the file happened to list first, so a reordered input silently changed her
# state. The modal state (most CCNs, ties alphabetical) is the same kind of
# deterministic choice the Medicaid source in build_cross_source_comparison.R
# makes, and for the same reason: an arbitrary pick among several true answers
# books the rest as disagreement. n_states_this_year makes the multiplicity
# visible rather than leaving it implied by n_ccns_resolved.
by_npi_year <- ccn_level %>%
  filter(!is.na(state)) %>%
  count(npi, year, state, name = "n_ccns_in_state") %>%
  arrange(npi, year, desc(n_ccns_in_state), state) %>%
  group_by(npi, year) %>%
  # n_distinct(state) is computed BEFORE state is overwritten: summarise()
  # evaluates its arguments in order, so putting state = first(state) first
  # would make every n_states_this_year read 1.
  summarise(n_states_this_year = n_distinct(state),
            n_ccns_resolved = sum(n_ccns_in_state),
            state = first(state), .groups = "drop") %>%
  select(npi, year, state, n_states_this_year, n_ccns_resolved)
write_csv(by_npi_year, "artifacts/historical_facility_affiliation_cohort_state_by_year.csv", na = "")
cat(sprintf("wrote %s NPI-year rows (%s distinct NPIs, years %d-%d) -> artifacts/historical_facility_affiliation_cohort_state_by_year.csv\n",
            format(nrow(by_npi_year), big.mark = ","), length(unique(by_npi_year$npi)),
            min(by_npi_year$year), max(by_npi_year$year)))
