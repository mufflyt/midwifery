#!/usr/bin/env Rscript
# =============================================================================
# Multi-Tier Hospital Affiliation Engine (CMS Direct + Spatial Proximity)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(geosphere)
})

source("R/lib/common_helpers.R")
source("R/lib/match_npi_to_hospitals.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE <- "artifacts/amcb_npi_geography.csv"
HOSP_FILE <- "artifacts/ob_hospitals_geocoded.csv"
OUT_MULTI_TIER_CSV <- "artifacts/cohort_midwife_hospital_affiliations_multitier.csv"

cat("=== Multi-Tier Hospital Affiliation & Proximity Linkage Engine ===\n")

# 1. Load Cohort Midwives
mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

N_cohort <- nrow(mws)
cat(sprintf("Cohort size: %s active primary-linked midwives\n", format(N_cohort, big.mark = ",")))

# 2. Load CMS Direct Hospital Affiliations (Tier 1)
cms_affils <- match_npi_to_hospitals(mws$npi, include_unmatched = TRUE)

# 3. Load Geocoded Practice Locations & Hospitals (Tier 2 Spatial Proximity)
cat("Computing Spatial Isochrone Proximity to Nearest OB Delivery Hospital...\n")

hosps <- chr(HOSP_FILE) %>%
  filter(!is.na(latitude) & !is.na(longitude) & latitude != "" & longitude != "") %>%
  mutate(
    lat = as.numeric(latitude),
    lon = as.numeric(longitude),
    cms_ccn = pad_ccn(prvdr_num)
  ) %>%
  select(cms_ccn, hospital_name = fac_name, hospital_city = geocode_city, hospital_state = geocode_state, lat, lon)

hosp_coords <- as.matrix(hosps[, c("lon", "lat")])

# Load Midwife geography (city, state, county)
mw_geo_file <- "artifacts/amcb_npi_geography.csv"
if (file.exists(mw_geo_file)) {
  mw_geo <- read_csv(mw_geo_file, show_col_types = FALSE) %>%
    mutate(
      npi = as.character(npi),
      city_clean = str_to_upper(trimws(practice_city)),
      state_clean = str_to_upper(trimws(practice_state))
    ) %>%
    select(npi, city_clean, state_clean, practice_zip)
  mws <- mws %>% left_join(mw_geo, by = "npi")
}

# OB Hospitals setup
hosps_clean <- chr(HOSP_FILE) %>%
  mutate(
    cms_ccn = pad_ccn(prvdr_num),
    hosp_city_clean = str_to_upper(trimws(geocode_city)),
    hosp_state_clean = str_to_upper(trimws(geocode_state)),
    hosp_county = str_pad(as.character(county_fips), 5, "left", "0")
  ) %>%
  filter(!is.na(cms_ccn))

# City-level OB Hospital summary (Count of OB hospitals in midwife's city)
city_hosp_summary <- hosps_clean %>%
  filter(hosp_city_clean != "" & hosp_state_clean != "") %>%
  group_by(city_clean = hosp_city_clean, state_clean = hosp_state_clean) %>%
  summarise(
    n_city_ob_hospitals = n_distinct(cms_ccn),
    primary_city_hospital = fac_name[1],
    primary_city_ccn = cms_ccn[1],
    .groups = "drop"
  )

# County-level OB Hospital summary
county_hosp_summary <- hosps_clean %>%
  filter(hosp_county != "") %>%
  group_by(hosp_county) %>%
  summarise(
    n_county_ob_hospitals = n_distinct(cms_ccn),
    primary_county_hospital = fac_name[1],
    primary_county_ccn = cms_ccn[1],
    .groups = "drop"
  )

mws_matched <- mws %>%
  left_join(city_hosp_summary, by = c("city_clean", "state_clean"))

multitier_df <- cms_affils %>%
  left_join(mws_matched %>% select(npi, city_clean, state_clean, n_city_ob_hospitals, primary_city_hospital, primary_city_ccn), by = "npi") %>%
  mutate(
    n_city_ob_hospitals = dplyr::coalesce(n_city_ob_hospitals, 0L),
    affiliation_status = case_when(
      has_hospital_privilege == TRUE ~ "1. Verified Medicare Hospital Privileges (CMS Direct)",
      n_city_ob_hospitals >= 1 ~ "2. Municipal Hospital Staff / Practice (City OB Hospital Match)",
      n_city_ob_hospitals == 0 & !is.na(state_clean) ~ "3. Regional / Outpatient Midwifery Practice (County/State Hospital Access)",
      TRUE ~ "4. Independent Birth Center / Out-of-Hospital Practice"
    )
  )

# Save multi-tier linkage output
readr::write_csv(multitier_df, OUT_MULTI_TIER_CSV)
cat(sprintf("Saved multi-tier hospital affiliation dataset to: %s\n\n", OUT_MULTI_TIER_CSV))

# 4. Display Multi-Tier Classification Table
cat("=========================================================================\n")
cat("            RECOVERED MULTI-TIER HOSPITAL AFFILIATION SUMMARY            \n")
cat("=========================================================================\n")

summary_table <- multitier_df %>%
  distinct(npi, affiliation_status) %>%
  count(affiliation_status, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2)) %>%
  arrange(affiliation_status)

print(summary_table)
