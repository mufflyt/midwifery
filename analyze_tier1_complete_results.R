#!/usr/bin/env Rscript
# =============================================================================
# State-by-State Analysis for Tier 1 Complete Ingestion
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Analyzing Complete Tier 1 State Board of Nursing Ingestion ===\n")

df <- read_csv("artifacts/tier1_live_bon_all_states_complete.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

st_breakdown <- df %>%
  group_by(nppes_state) %>%
  summarise(
    n_midwives = n(),
    pct_of_tier1 = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    verified_hospitals = sum(str_detect(refined_clinical_setting, "1\\."), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(n_midwives))

cat("State-by-State Distribution for All 11 Tier 1 States:\n")
print(st_breakdown)

write_csv(st_breakdown, "artifacts/tier1_complete_state_breakdown.csv")
cat("\nWritten complete Tier 1 summary matrix to: artifacts/tier1_complete_state_breakdown.csv\n")
