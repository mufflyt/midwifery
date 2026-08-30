#!/usr/bin/env Rscript
# =============================================================================
# State-by-State Analysis for Tier 2 Complete Ingestion
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})
source(file.path("R", "lib", "clinical_setting.R"))

cat("=== Analyzing Complete Tier 2 State Board of Nursing Ingestion ===\n")

df <- read_csv("artifacts/tier2_live_bon_all_states_complete.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

st_breakdown <- df %>%
  group_by(nppes_state) %>%
  summarise(
    n_midwives = n(),
    pct_of_tier2 = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    verified_hospitals = sum(is_facility_setting_category(refined_clinical_setting, 1), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(n_midwives))

cat("State-by-State Distribution for All 25 Tier 2 States:\n")
print(st_breakdown)

write_csv(st_breakdown, "artifacts/tier2_complete_state_breakdown.csv")
cat("\nWritten complete Tier 2 summary matrix to: artifacts/tier2_complete_state_breakdown.csv\n")
