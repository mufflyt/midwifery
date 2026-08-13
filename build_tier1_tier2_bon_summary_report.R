#!/usr/bin/env Rscript
# =============================================================================
# Summary Analysis Report for Tier 1 and Tier 2 BON Ingestion
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Generating Tier 1 and Tier 2 BON Ingestion Report ===\n")

df <- read_csv("artifacts/cohort_midwives_tier1_tier2_bon_validated.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

tier_summary <- df %>%
  group_by(bon_ingestion_tier) %>%
  summarise(
    n_midwives = n(),
    pct_cohort = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    verified_hospitals = sum(str_detect(refined_clinical_setting, "1\\."), na.rm = TRUE),
    .groups = "drop"
  )

cat("\nSummary by BON Ingestion Tier:\n")
print(tier_summary)

state_tier_breakdown <- df %>%
  group_by(nppes_state, bon_ingestion_tier) %>%
  summarise(n_midwives = n(), .groups = "drop") %>%
  arrange(desc(n_midwives))

write_csv(tier_summary, "artifacts/tier1_tier2_bon_summary_matrix.csv")
write_csv(state_tier_breakdown, "artifacts/tier1_tier2_bon_state_breakdown.csv")

cat("\nWritten summary reports to:\n")
cat("  - artifacts/tier1_tier2_bon_summary_matrix.csv\n")
cat("  - artifacts/tier1_tier2_bon_state_breakdown.csv\n")
