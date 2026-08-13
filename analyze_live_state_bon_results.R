#!/usr/bin/env Rscript
# =============================================================================
# Live State Board of Nursing (BON) Ingestion Analysis
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Analyzing Live State BON Ingestion Results ===\n")

df <- read_csv("artifacts/live_washington_bon_ingested_midwives.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

summary_stat <- df %>%
  group_by(live_bon_match_status) %>%
  summarise(
    n_midwives = n(),
    pct_total = round(n() / nrow(df) * 100, 1),
    cpt_attenders = sum(has_cpt_delivery_claim == TRUE, na.rm = TRUE),
    .groups = "drop"
  )

cat("Live Washington State BON Match Rate & Clinical Depth:\n")
print(summary_stat)

license_status_dist <- df %>%
  filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
  group_by(live_bon_status) %>%
  summarise(n = n(), .groups = "drop")

cat("\nLive License Status Distribution for Verified Midwives:\n")
print(license_status_dist)

write_csv(summary_stat, "artifacts/live_wa_bon_summary_matrix.csv")
cat("\nWritten live BON summary matrix to: artifacts/live_wa_bon_summary_matrix.csv\n")
