#!/usr/bin/env Rscript
# =============================================================================
# Final Integrated Facility Practice Setting Classifier (Including 221 CABC FBCs)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/common_helpers.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
RIGOROUS_HOSP_FILE <- "artifacts/cohort_midwife_hospital_rigorous_attributions.csv"
CABC_MATCHES_FILE <- "artifacts/cabc_matched_midwives_final.csv"
OUT_FINAL_CSV <- "artifacts/cohort_midwife_facility_attributions_final_v2.csv"

cat("=== Updating Final Cohort Facility & Practice Setting Classification ===\n")

mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

N_cohort <- nrow(mws)

rigorous <- chr(RIGOROUS_HOSP_FILE)
cabc_matches <- chr(CABC_MATCHES_FILE) %>%
  mutate(npi = as.character(npi)) %>%
  select(npi, matched_cabc_birth_center, cabc_address, cabc_zip)

df <- mws %>%
  left_join(rigorous %>% select(npi, attribution_tier, attributed_hospital_name, cms_ccn), by = "npi") %>%
  left_join(cabc_matches, by = "npi") %>%
  mutate(
    has_cabc_fbc = !is.na(matched_cabc_birth_center),
    final_facility_setting = case_when(
      attribution_tier == "Tier 1: Verified Medicare Hospital Privilege (CMS Direct Link)" ~ "1. Hospital Privileges (CMS Medicare Direct)",
      attribution_tier == "Tier 2: Exact Campus Address Match (Hospital Street Address)" ~ "2. Hospital Campus Practice (Exact Street Address)",
      has_cabc_fbc == TRUE ~ "3. Accredited Freestanding Birth Center (CABC Registry Match)",
      attribution_tier == "Tier 3: Single-Hospital Municipality (Sole Local OB Delivery Center)" ~ "4. Municipal Health System (Single OB Hospital)",
      attribution_tier == "Tier 4: Multi-Hospital Metro Area (Requires Individual Credential Verification)" ~ "5. Outpatient / Multi-Hospital System Group",
      TRUE ~ "6. Independent Outpatient / Community Health Practice"
    )
  )

readr::write_csv(df, OUT_FINAL_CSV)
cat(sprintf("Saved updated final classification to: %s\n\n", OUT_FINAL_CSV))

cat("=========================================================================\n")
cat("      FINAL COMPREHENSIVE CLINICAL PRACTICE SETTING DISTRIBUTION         \n")
cat("=========================================================================\n")

summary_table <- df %>%
  distinct(npi, final_facility_setting) %>%
  count(final_facility_setting, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2)) %>%
  arrange(final_facility_setting)

print(summary_table)
