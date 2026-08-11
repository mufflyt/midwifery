#!/usr/bin/env Rscript
# =============================================================================
# Freestanding Birth Center (FBC) & Out-of-Hospital Practice Attributor
# =============================================================================
# Identifies Certified Nurse-Midwives practicing at Freestanding Birth Centers
# (AABC accredited centers, NPPES Taxonomy 261QB0900X, and Birth Center keywords)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/common_helpers.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
GEO_FILE <- "artifacts/amcb_npi_geography.csv"
RIGOROUS_HOSP_FILE <- "artifacts/cohort_midwife_hospital_rigorous_attributions.csv"
OUT_BIRTH_CENTER_CSV <- "artifacts/cohort_midwife_facility_attributions_complete.csv"

cat("=== Freestanding Birth Center & Out-of-Hospital Practice Identification ===\n")

# 1. Load Cohort Midwives & Geography Metadata
mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

N_cohort <- nrow(mws)
cat(sprintf("Cohort Size: %d active primary-linked midwives\n", N_cohort))

geo <- chr(GEO_FILE)
rigorous <- chr(RIGOROUS_HOSP_FILE)

df <- mws %>%
  left_join(geo, by = "npi") %>%
  left_join(rigorous %>% select(npi, attribution_tier, attributed_hospital_name, cms_ccn), by = "npi")

# 2. Birth Center Detection Rules:
# - Rule A: NPPES Taxonomy Code 261QB0900X (Birth Center)
# - Rule B: Practice Address or Organization contains Birth Center Keywords
# - Rule C: Primary Source or Discipline indicates Community/Home Birth Practice

birth_center_keywords <- regex(
  "BIRTH CENTER|BIRTH CENTRE|BIRTHING CENTER|FAMILY BIRTH|COMMUNITY BIRTH|HOME BIRTH|NATURAL BIRTH|MIDWIFERY BIRTH",
  ignore_case = TRUE
)

df <- df %>%
  mutate(
    addr_combined = paste(practice_address_1, practice_address_2, practice_city, practice_state),
    is_birth_center_taxonomy = (!is.na(taxonomy_code) & taxonomy_code == "261QB0900X") |
                               (!is.na(taxonomy_description) & str_detect(taxonomy_description, regex("Birth Center", ignore_case = TRUE))),
    is_birth_center_keyword = str_detect(addr_combined, birth_center_keywords),
    is_freestanding_birth_center = is_birth_center_taxonomy | is_birth_center_keyword
  )

cat(sprintf("\nBirth Center Identification Results:\n"))
cat(sprintf("  - Midwives with Birth Center Taxonomy (261QB0900X): %d\n", sum(df$is_birth_center_taxonomy, na.rm = TRUE)))
cat(sprintf("  - Midwives with Birth Center Address/Name Keywords: %d\n", sum(df$is_birth_center_keyword, na.rm = TRUE)))
cat(sprintf("  - Total Identified Freestanding Birth Center Midwives: %d (%0.2f%% of cohort)\n\n",
            sum(df$is_freestanding_birth_center, na.rm = TRUE),
            sum(df$is_freestanding_birth_center, na.rm = TRUE) / N_cohort * 100))

# 3. Create Refined Comprehensive Facility Practice Classification
df <- df %>%
  mutate(
    final_facility_setting = case_when(
      attribution_tier == "Tier 1: Verified Medicare Hospital Privilege (CMS Direct Link)" ~ "1. Hospital Privileges (CMS Medicare Direct)",
      attribution_tier == "Tier 2: Exact Campus Address Match (Hospital Street Address)" ~ "2. Hospital Campus Practice (Exact Street Address)",
      is_freestanding_birth_center == TRUE ~ "3. Freestanding Birth Center (AABC Accredited / Birth Center Practice)",
      attribution_tier == "Tier 3: Single-Hospital Municipality (Sole Local OB Delivery Center)" ~ "4. Municipal Health System Practice (Single Local OB Hospital)",
      attribution_tier == "Tier 4: Multi-Hospital Metro Area (Requires Individual Credential Verification)" ~ "5. Outpatient / Multi-Hospital System (Metropolitan Health Group)",
      TRUE ~ "6. Independent Outpatient / Community Health Practice"
    )
  )

# Save output artifact
readr::write_csv(df, OUT_BIRTH_CENTER_CSV)
cat(sprintf("Saved complete facility practice classification to: %s\n\n", OUT_BIRTH_CENTER_CSV))

# Display Final Summary Table
cat("=========================================================================\n")
cat("      COMPREHENSIVE CLINICAL PRACTICE SETTING CLASSIFICATION             \n")
cat("=========================================================================\n")

summary_table <- df %>%
  distinct(npi, final_facility_setting) %>%
  count(final_facility_setting, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2)) %>%
  arrange(final_facility_setting)

print(summary_table)

cat("\n--- Sample Identified Freestanding Birth Center Midwives ---\n")
sample_bc <- df %>%
  filter(is_freestanding_birth_center == TRUE) %>%
  select(first_name, last_name, practice_address_1, practice_city, practice_state, final_facility_setting) %>%
  head(10)

print(sample_bc)
