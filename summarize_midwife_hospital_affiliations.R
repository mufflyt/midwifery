#!/usr/bin/env Rscript
# =============================================================================
# Summarize Midwife Hospital Affiliations & Healthcare System Linkages
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

AFFIL_FILE <- "artifacts/midwife_hospital_affiliations.csv"
MIDWIVES_FILE <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"

cat("=== Midwife Hospital & Healthcare System Affiliation Summary ===\n")

if (!file.exists(AFFIL_FILE)) {
  stop("Affiliation file not found.")
}

df <- read_csv(AFFIL_FILE, show_col_types = FALSE)

cat(sprintf("Total Linked Affiliation Records: %d\n", nrow(df)))
cat(sprintf("Unique Active Midwives Linked: %d\n", n_distinct(df$certification_number)))
cat(sprintf("Unique Hospitals Linked: %d\n\n", n_distinct(df$cms_ccn[df$cms_ccn != ""])))

cat("--- Top 10 Hospitals by Midwife Staff Count ---\n")
top_hospitals <- df %>%
  filter(hospital_name != "") %>%
  count(cms_ccn, hospital_name, hospital_city, hospital_state, name = "midwife_count") %>%
  arrange(desc(midwife_count)) %>%
  head(10)

print(top_hospitals)

cat("\n--- Distribution of Hospitals per Midwife ---\n")
hosp_per_mw <- df %>%
  filter(hospital_name != "") %>%
  group_by(certification_number) %>%
  summarise(n_hospitals = n_distinct(cms_ccn), .groups = "drop") %>%
  count(n_hospitals, name = "midwives")

print(hosp_per_mw)
