#!/usr/bin/env Rscript
# =============================================================================
# Rigorous Individual-Level Midwife Hospital Attribution Pipeline
# =============================================================================
# Avoids naive spatial joins in multi-hospital metropolitan cities (e.g. Cleveland,
# Chicago, New York). Classifies hospital affiliations into rigorous tiers:
#
# Tier 1: Verified Direct CMS Medicare Privilege (100% Exact NPI Link)
# Tier 2: Exact Physical Street Address Match (100% Exact Hospital Campus Address)
# Tier 3: Single-Hospital Municipal Practice (100% Single Local OB Hospital)
# Tier 4: Multi-Hospital Metropolitan Area (Flagged: Cleveland Clinic / UH / MetroHealth)
# Tier 5: Outpatient / Community Clinic / Independent Practice
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/common_helpers.R")
source("R/lib/match_npi_to_hospitals.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE <- "artifacts/amcb_npi_geography.csv"
HOSP_FILE <- "artifacts/ob_hospitals_geocoded.csv"
OUT_RIGOROUS_CSV <- "artifacts/cohort_midwife_hospital_rigorous_attributions.csv"

cat("=== Executing Rigorous Hospital Attribution Engine ===\n")

# 1. Load Cohort Midwives & Address Metadata
mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

N_cohort <- nrow(mws)
cat(sprintf("Cohort size: %s active primary-linked midwives\n", format(N_cohort, big.mark = ",")))

norm_addr <- function(x) {
  x <- str_to_upper(trimws(x))
  x <- str_replace_all(x, "\\bAVENUE\\b", "AVE")
  x <- str_replace_all(x, "\\bSTREET\\b", "ST")
  x <- str_replace_all(x, "\\bROAD\\b", "RD")
  x <- str_replace_all(x, "\\bBOULEVARD\\b", "BLVD")
  x <- str_replace_all(x, "\\bDRIVE\\b", "DR")
  x <- str_replace_all(x, "\\bPARKWAY\\b", "PKWY")
  x <- str_replace_all(x, "\\bSUITE\\b.*|\\bSTE\\b.*|#.*", "")
  str_trim(x)
}

geo <- chr(GEO_FILE)
mw_addr <- mws %>%
  left_join(geo, by = "npi") %>%
  mutate(
    addr1_raw   = practice_address_1,
    addr1_clean = norm_addr(practice_address_1),
    city_clean  = str_to_upper(trimws(practice_city)),
    state_clean = str_to_upper(trimws(practice_state)),
    zip_clean   = str_sub(str_trim(practice_zip), 1, 5)
  )

# 2. Load OB Hospitals
hosps <- chr(HOSP_FILE) %>%
  mutate(
    cms_ccn    = pad_ccn(prvdr_num),
    hosp_name  = str_to_upper(trimws(fac_name)),
    hosp_addr1 = norm_addr(geocode_address_1),
    hosp_city  = str_to_upper(trimws(geocode_city)),
    hosp_state = str_to_upper(trimws(geocode_state)),
    hosp_zip   = str_sub(str_trim(geocode_zip), 1, 5)
  ) %>%
  filter(!is.na(cms_ccn))

# Count OB hospitals per city to detect multi-hospital metro areas
city_hosp_counts <- hosps %>%
  filter(hosp_city != "" & hosp_state != "") %>%
  group_by(city_clean = hosp_city, state_clean = hosp_state) %>%
  summarise(
    n_city_ob_hosp = n_distinct(cms_ccn),
    single_hosp_name = if (n_distinct(cms_ccn) == 1) hosp_name[1] else NA_character_,
    single_hosp_ccn  = if (n_distinct(cms_ccn) == 1) cms_ccn[1] else NA_character_,
    .groups = "drop"
  )

# 3. Tier 1: CMS Direct DAC Matches
cms_affils <- match_npi_to_hospitals(mws$npi, include_unmatched = TRUE) %>%
  select(npi, is_enrolled_dac, has_hospital_privilege, n_hospitals, cms_ccn, facility_type, hospital_name, hospital_city, hospital_state)

# 4. Tier 2: Exact Street Address Matches
exact_addr_matches <- mw_addr %>%
  inner_join(hosps, by = c("addr1_clean" = "hosp_addr1", "city_clean" = "hosp_city", "state_clean" = "hosp_state")) %>%
  select(npi, exact_addr_ccn = cms_ccn, exact_addr_hosp = hosp_name) %>%
  distinct(npi, .keep_all = TRUE)

# Assemble multi-method attribution hierarchy
attr_df <- mw_addr %>%
  left_join(cms_affils, by = "npi") %>%
  left_join(exact_addr_matches, by = "npi") %>%
  left_join(city_hosp_counts, by = c("city_clean", "state_clean")) %>%
  mutate(
    n_city_ob_hosp = dplyr::coalesce(n_city_ob_hosp, 0L),
    attribution_tier = case_when(
      has_hospital_privilege == TRUE ~ "Tier 1: Verified Medicare Hospital Privilege (CMS Direct Link)",
      !is.na(exact_addr_hosp) ~ "Tier 2: Exact Campus Address Match (Hospital Street Address)",
      n_city_ob_hosp == 1 ~ "Tier 3: Single-Hospital Municipality (Sole Local OB Delivery Center)",
      n_city_ob_hosp > 1 ~ "Tier 4: Multi-Hospital Metro Area (Requires Individual Credential Verification)",
      TRUE ~ "Tier 5: Outpatient / Community Health Center / Non-Hospital Practice"
    ),
    attributed_hospital_name = case_when(
      has_hospital_privilege == TRUE ~ hospital_name,
      !is.na(exact_addr_hosp) ~ exact_addr_hosp,
      n_city_ob_hosp == 1 ~ single_hosp_name,
      n_city_ob_hosp > 1 ~ paste0("Multi-Hospital Area (", n_city_ob_hosp, " OB Hospitals in ", city_clean, ")"),
      TRUE ~ "No Local OB Hospital"
    ),
    attributed_ccn = case_when(
      has_hospital_privilege == TRUE ~ cms_ccn,
      !is.na(exact_addr_ccn) ~ exact_addr_ccn,
      n_city_ob_hosp == 1 ~ single_hosp_ccn,
      TRUE ~ NA_character_
    )
  )

# Save output
readr::write_csv(attr_df, OUT_RIGOROUS_CSV)
cat(sprintf("Saved rigorous hospital attribution dataset to: %s\n\n", OUT_RIGOROUS_CSV))

# Display Rigorous Tier Distribution
cat("=========================================================================\n")
cat("            RIGOROUS HOSPITAL ATTRIBUTION TIER DISTRIBUTION              \n")
cat("=========================================================================\n")

summary_table <- attr_df %>%
  distinct(npi, attribution_tier) %>%
  count(attribution_tier, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2)) %>%
  arrange(attribution_tier)

print(summary_table)

cat("\n--- Example: Cleveland, OH Midwife Attribution Breakdown ---\n")
cleveland_summary <- attr_df %>%
  filter(city_clean == "CLEVELAND" & state_clean == "OH") %>%
  select(first_name, last_name, practice_address_1, attribution_tier, attributed_hospital_name) %>%
  head(10)

print(cleveland_summary)
