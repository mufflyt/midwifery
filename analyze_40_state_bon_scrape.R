#!/usr/bin/env Rscript
# =============================================================================
# State-by-State Analysis for Complete 40-State Board of Nursing Scrape
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Analyzing Complete 40-State Board of Nursing (BON) Scrape Results ===\n")

df <- read_csv("artifacts/scraped_40_state_bons_midwives_master.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

st_breakdown <- df %>%
  group_by(scraped_bon_state, wave2_scraping_batch) %>%
  summarise(
    scraped_midwives = n(),
    pct_of_40_states = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(scraped_midwives))

cat("State-by-State Breakdown for All 40 Scraped State BONs (Total N = 11,355):\n")
print(head(st_breakdown, 15))

write_csv(st_breakdown, "artifacts/scraped_40_state_bon_summary_matrix.csv")
cat("\nWritten 40-state BON summary matrix to: artifacts/scraped_40_state_bon_summary_matrix.csv\n")
