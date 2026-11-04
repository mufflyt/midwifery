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
# Same CCN -> cms_hospital_info join as extract_dac_facility_affiliations.R,
# reused as-is (a hospital's CCN and state don't change year to year, so using
# the CURRENT hospital registry to resolve a HISTORICAL CCN is safe; a hospital
# that closed before the current registry snapshot would resolve to NA, same
# "unattributed" handling as the current-year script).
#
# ONE STATE PER NPI-YEAR, NOT COLLAPSED PER MIDWIFE. A midwife with CCNs in two
# different states in the same year-vintage gets her FIRST resolved CCN's state
# (row order from the source file, arbitrary) -- unlike
# dac_hospital_affiliation_person.csv's any-flags, this audit's state-comparison
# tables need exactly one value per NPI-year, so an arbitrary tie-break is
# unavoidable here. n_ccns_resolved is kept alongside so that multiplicity is
# visible rather than hidden.
#
# Inputs : artifacts/physician_compare_historical_midwives.csv
#          cms_hospital_info (MEDICARE_DUCKDB)
# Outputs: artifacts/historical_facility_affiliation_ccn_level.csv (NPI-year-CCN level, gitignored)
#          artifacts/historical_facility_affiliation_cohort_state_by_year.csv (one row per NPI-year, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr); library(DBI); library(duckdb)})
source("R/lib/common_helpers.R")
source(file.path("R", "lib", "medicare_duckdb.R"))

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
  distinct(ccn, .keep_all = TRUE)

ccn_level <- long_ccn %>% left_join(hosp, by = "ccn")
unresolved <- sum(is.na(ccn_level$facility_name))
cat(sprintf("resolved to a named hospital: %s / %s (%.1f%%)\n",
            format(sum(!is.na(ccn_level$facility_name)), big.mark = ","),
            format(nrow(ccn_level), big.mark = ","),
            100 * mean(!is.na(ccn_level$facility_name))))
write_csv(ccn_level, "artifacts/historical_facility_affiliation_ccn_level.csv", na = "")

by_npi_year <- ccn_level %>%
  filter(!is.na(state)) %>%
  group_by(npi, year) %>%
  summarise(state = first(state), n_ccns_resolved = n_distinct(ccn), .groups = "drop")
write_csv(by_npi_year, "artifacts/historical_facility_affiliation_cohort_state_by_year.csv", na = "")
cat(sprintf("wrote %s NPI-year rows (%s distinct NPIs, years %d-%d) -> artifacts/historical_facility_affiliation_cohort_state_by_year.csv\n",
            format(nrow(by_npi_year), big.mark = ","), length(unique(by_npi_year$npi)),
            min(by_npi_year$year), max(by_npi_year$year)))
