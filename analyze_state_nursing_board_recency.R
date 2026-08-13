#!/usr/bin/env Rscript
# =============================================================================
# State Board of Nursing (BON) CNM Licensure & Address Recency Audit
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Auditing State Board of Nursing (BON) CNM Practice Addresses ===\n")

bon <- read_csv("artifacts/state_nursing_board_cnm_addresses.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

v4 <- read_csv("artifacts/cohort_midwife_facility_attributions_final_v4.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

# Summarize State BON CNM Coverage by State
bon_summary <- bon %>%
  group_by(bon_state) %>%
  summarise(
    total_cnms = n(),
    active_licensed = sum(bon_license_status == "ACTIVE_LICENSED"),
    pct_active = round(mean(bon_license_status == "ACTIVE_LICENSED") * 100, 1),
    .groups = "drop"
  ) %>%
  arrange(desc(total_cnms))

cat(sprintf("Ingested State BON license records for %d states.\n", nrow(bon_summary)))
cat("Top 10 States by CNM Licensure Volume:\n")
print(head(bon_summary, 10))

write_csv(bon_summary, "artifacts/state_nursing_board_licensure_summary.csv")
cat("\nWritten State BON licensure summary to: artifacts/state_nursing_board_licensure_summary.csv\n")
