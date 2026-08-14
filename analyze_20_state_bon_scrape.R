#!/usr/bin/env Rscript
# =============================================================================
# State-by-State Analysis for Overnight 20-State BON Scrape
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Analyzing Overnight 20-State Board of Nursing (BON) Scrape Results ===\n")

df <- read_csv("artifacts/scraped_20_state_bons_midwives_master.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

st_breakdown <- df %>%
  group_by(scraped_bon_state) %>%
  summarise(
    scraped_midwives = n(),
    pct_of_20_states = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    verified_hospitals = sum(str_detect(refined_clinical_setting, "1\\."), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(scraped_midwives))

cat("State-by-State Breakdown for All 20 Scraped State BONs:\n")
print(st_breakdown)

write_csv(st_breakdown, "artifacts/scraped_20_state_bon_summary_matrix.csv")
cat("\nWritten 20-state BON summary matrix to: artifacts/scraped_20_state_bon_summary_matrix.csv\n")
