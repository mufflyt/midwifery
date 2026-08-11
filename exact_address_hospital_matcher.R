#!/usr/bin/env Rscript
# =============================================================================
# Exact Street Address & Hospital System Attributor
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/common_helpers.R")
source("R/lib/match_npi_to_hospitals.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE <- "artifacts/amcb_npi_geography.csv"
HOSP_FILE <- "artifacts/ob_hospitals_geocoded.csv"

cat("=== Exact Physical Address Hospital Attributor ===\n")

mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

geo <- chr(GEO_FILE)

# Combine midwife practice address
mw_addr <- mws %>%
  left_join(geo, by = "npi") %>%
  mutate(
    addr1_clean = str_to_upper(trimws(practice_address_1)),
    city_clean  = str_to_upper(trimws(practice_city)),
    state_clean = str_to_upper(trimws(practice_state)),
    zip_clean   = str_sub(str_trim(practice_zip), 1, 5)
  )

hosps <- chr(HOSP_FILE) %>%
  mutate(
    cms_ccn    = pad_ccn(prvdr_num),
    hosp_name  = str_to_upper(trimws(fac_name)),
    hosp_addr1 = str_to_upper(trimws(geocode_address_1)),
    hosp_city  = str_to_upper(trimws(geocode_city)),
    hosp_state = str_to_upper(trimws(geocode_state)),
    hosp_zip   = str_sub(str_trim(geocode_zip), 1, 5)
  ) %>%
  filter(!is.na(cms_ccn))

cat(sprintf("Cohort Size: %d midwives\n", nrow(mw_addr)))
cat(sprintf("OB Hospital Master: %d hospitals\n\n", nrow(hosps)))

# 1. Exact Address Line 1 + Zip Match
addr_zip_matches <- mw_addr %>%
  inner_join(hosps, by = c("addr1_clean" = "hosp_addr1", "zip_clean" = "hosp_zip"))

cat(sprintf("Exact Street Address + ZIP Code Matches: %d records (%d unique midwives)\n",
            nrow(addr_zip_matches), n_distinct(addr_zip_matches$npi)))

# 2. Exact Address Line 1 + City + State Match
addr_city_matches <- mw_addr %>%
  inner_join(hosps, by = c("addr1_clean" = "hosp_addr1", "city_clean" = "hosp_city", "state_clean" = "hosp_state"))

cat(sprintf("Exact Street Address + City + State Matches: %d records (%d unique midwives)\n\n",
            nrow(addr_city_matches), n_distinct(addr_city_matches$npi)))

# Print sample Cleveland / Ohio address matches
oh_matches <- addr_city_matches %>%
  filter(state_clean == "OH") %>%
  select(first_name, last_name, practice_address_1, city_clean, hosp_name, cms_ccn) %>%
  head(10)

cat("Sample Exact Address Matches in Ohio:\n")
print(oh_matches)
