#!/usr/bin/env Rscript
# =============================================================================
# Empirical Analysis of Specialized State BON Comparison Fields
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Analyzing Specialized State BON Comparison Fields ===\n")

df <- read_csv("artifacts/scraped_20_state_bons_with_all_specialized_fields.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

summary_matrix <- df %>%
  group_by(scraped_bon_state) %>%
  summarise(
    total_midwives = n(),
    rxn_prescriptive_auth = sum(str_detect(rxn_prescriptive_authority_status, "Active")),
    cpa_physician_filings = sum(str_detect(supervising_physician_cpa_name, "Filed CPA")),
    autonomous_practice = sum(str_detect(supervising_physician_cpa_name, "Full Autonomous")),
    attributed_hospitals = sum(bon_attributed_hospital_privileges != "Outpatient Community Practice"),
    .groups = "drop"
  ) %>%
  arrange(desc(total_midwives))

cat("State-by-State Specialized Field Breakdown:\n")
print(head(summary_matrix, 10))

write_csv(summary_matrix, "artifacts/specialized_bon_fields_summary.csv")
cat("\nWritten specialized BON fields summary to: artifacts/specialized_bon_fields_summary.csv\n")
