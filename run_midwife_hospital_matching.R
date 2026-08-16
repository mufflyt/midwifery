#!/usr/bin/env Rscript
# =============================================================================
# Run match_npi_to_hospitals() on National Active Cohort Midwives
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/match_npi_to_hospitals.R")

MW_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
OUT_SUMMARY_CSV <- "artifacts/cohort_midwife_hospital_matches.csv"

cat("=== Executing match_npi_to_hospitals() on National Cohort Midwives ===\n")

if (!file.exists(MW_FILE)) {
  stop("Active cohort midwife file not found.", call. = FALSE)
}

# 1. Load active cohort midwives
mws <- chr(MW_FILE) %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)

N_cohort <- nrow(mws)
cat(sprintf("Cohort size: %s active primary-linked midwives\n\n", format(N_cohort, big.mark = ",")))

# The enrollment register, loaded by the canonical helper in
# R/lib/match_npi_to_hospitals.R (sourced above).
DAC_NATIONAL_NPIS <- load_dac_national_npis()

results <- match_npi_to_hospitals(mws$npi, include_unmatched = TRUE,
                                  dac_national_npis = DAC_NATIONAL_NPIS)

# Join midwife metadata (name, cert, state)
state_col <- names(mws)[str_detect(names(mws), "nppes_state|^state$")][1]
mws_meta <- mws %>%
  select(npi, certification_number, first_name, last_name, nppes_state = !!sym(state_col), certification)

full_results <- results %>%
  left_join(mws_meta, by = "npi")

# Save output artifact
readr::write_csv(full_results, OUT_SUMMARY_CSV)
cat(sprintf("Saved matched cohort dataset to: %s\n\n", OUT_SUMMARY_CSV))

# 3. Compute Summary Statistics
cat("=========================================================\n")
cat("            COHORT HOSPITAL AFFILIATION RESULTS           \n")
cat("=========================================================\n")

n_enrolled_dac <- n_distinct(full_results$npi[full_results$is_enrolled_dac])
pct_enrolled_dac <- round(100 * n_enrolled_dac / N_cohort, 2)

n_privileges <- n_distinct(full_results$npi[full_results$has_hospital_privilege])
pct_privileges <- round(100 * n_privileges / N_cohort, 2)

n_records <- nrow(full_results %>% filter(!is.na(cms_ccn)))
n_unique_hospitals <- n_distinct(full_results$cms_ccn[!is.na(full_results$cms_ccn)])

cat(sprintf("1. Total Active Cohort Midwives: %s\n", format(N_cohort, big.mark = ",")))
cat(sprintf("2. Enrolled in CMS Provider Data Catalog (DAC): %s (%s%%)\n", format(n_enrolled_dac, big.mark = ","), pct_enrolled_dac))
cat(sprintf("3. Verified Hospital Privileges Recorded: %s (%s%%)\n", format(n_privileges, big.mark = ","), pct_privileges))
cat(sprintf("4. Enrolled in DAC, but No Hospital Privileges Recorded: %s (%s%%)\n", format(n_enrolled_dac - n_privileges, big.mark = ","), round(100 * (n_enrolled_dac - n_privileges) / N_cohort, 2)))
cat(sprintf("5. Total Individual Hospital Linkage Records: %s\n", format(n_records, big.mark = ",")))
cat(sprintf("6. Total Unique Hospitals & Facilities Linked: %s\n\n", format(n_unique_hospitals, big.mark = ",")))

cat("--- Privileges per Midwife Distribution ---\n")
hosp_counts <- full_results %>%
  distinct(npi, n_hospitals, has_hospital_privilege) %>%
  count(n_hospitals, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2))

print(hosp_counts)

cat("\n--- Top 15 US Hospitals by Midwife Staff Count ---\n")
top_hosp <- full_results %>%
  filter(!is.na(hospital_name) & hospital_name != "") %>%
  count(cms_ccn, hospital_name, hospital_city, hospital_state, name = "cnm_staff_count") %>%
  arrange(desc(cnm_staff_count)) %>%
  head(15)

print(top_hosp)

cat("\n--- State Breakdown: Top 10 States by Midwife Hospital Affiliations ---\n")
state_breakdown <- full_results %>%
  filter(has_hospital_privilege) %>%
  distinct(npi, nppes_state) %>%
  count(nppes_state, name = "midwives_with_privileges") %>%
  arrange(desc(midwives_with_privileges)) %>%
  head(10)

print(state_breakdown)
