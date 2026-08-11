#!/usr/bin/env Rscript
# =============================================================================
# Integrated Open Payments (Sunshine Act) & Practice Setting Master Engine v4
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

source("R/lib/common_helpers.R")

MASTER_V3_FILE <- "artifacts/cohort_midwife_facility_attributions_final_v3.csv"
OP_PROFILE_FILE <- "artifacts/cohort_midwives_open_payments_employers.csv"
OP_GEN_FILE <- "artifacts/cohort_midwives_open_payments_general_2024.csv"
OUT_MASTER_V4 <- "artifacts/cohort_midwife_facility_attributions_final_v4.csv"

cat("=== Integrating CMS Open Payments Sunshine Act Data into Master v4 ===\n")

# 1. Load Master v3
mws_v3 <- chr(MASTER_V3_FILE) %>%
  mutate(npi = as.character(npi))

N_cohort <- nrow(mws_v3)
cat(sprintf("Cohort Size: %s active primary-linked midwives\n", format(N_cohort, big.mark = ",")))

# 2. Load Open Payments Profile Matches (N = 7,039)
op_profile <- chr(OP_PROFILE_FILE) %>%
  mutate(npi = as.character(npi)) %>%
  distinct(npi, .keep_all = TRUE) %>%
  select(npi, op_profile_match = open_payments_employer_name, op_city, op_state)

# 3. Load Open Payments 2024 General Payments Matches (N = 3,996)
op_gen <- chr(OP_GEN_FILE) %>%
  mutate(npi = as.character(npi)) %>%
  group_by(npi) %>%
  summarise(
    n_op_payments = n(),
    op_total_amount = sum(as.numeric(payment_amount), na.rm = TRUE),
    op_manufacturers = paste(unique(payer_manufacturer), collapse = "; "),
    .groups = "drop"
  )

# Combine into Master v4
master_v4 <- mws_v3 %>%
  left_join(op_profile %>% select(npi, op_profile_match), by = "npi") %>%
  mutate(has_op_profile = !is.na(op_profile_match)) %>%
  left_join(op_gen, by = "npi") %>%
  mutate(
    has_op_general = !is.na(n_op_payments),
    has_open_payments_record = has_op_profile | has_op_general,
    n_op_payments = dplyr::coalesce(n_op_payments, 0L),
    open_payments_status = case_when(
      has_open_payments_record == TRUE ~ "Verified Open Payments Covered Recipient (CMS Sunshine Act Linked)",
      TRUE ~ "No Open Payments Record (Unlinked)"
    )
  )

# Save Master v4
readr::write_csv(master_v4, OUT_MASTER_V4)
cat(sprintf("Saved updated master dataset to: %s\n\n", OUT_MASTER_V4))

cat("=========================================================================\n")
cat("      CMS OPEN PAYMENTS SUNSHINE ACT SUMMARY (N = 11,920 MIDWIVES)       \n")
cat("=========================================================================\n")

op_summary <- master_v4 %>%
  distinct(npi, open_payments_status) %>%
  count(open_payments_status, name = "midwife_count") %>%
  mutate(percent = round(100 * midwife_count / N_cohort, 2))

print(op_summary)

cat("\n--- Open Payments Coverage by Refined Facility Practice Setting ---\n")
setting_op_summary <- master_v4 %>%
  group_by(refined_clinical_setting) %>%
  summarise(
    total_midwives = n(),
    n_open_payments = sum(has_open_payments_record),
    pct_open_payments = round(100 * n_open_payments / total_midwives, 2),
    .groups = "drop"
  )

print(setting_op_summary)
