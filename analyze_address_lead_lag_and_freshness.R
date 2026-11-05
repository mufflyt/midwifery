#!/usr/bin/env Rscript
# =============================================================================
# Lead-Lag, NPPES Record Freshness, and Medicaid Enrollment Timing Diagnostics
# =============================================================================
# Uses the exported functions in the `mysteryroster` package:
#   - mysteryroster::attribute_spell_age()
#   - mysteryroster::attribute_lead_lag_matrix()
#   - mysteryroster::attribute_agreement_by_spell_age()
#   - mysteryroster::enrollment_move_lead_lag()
#   - mysteryroster::format_no_gold_standard_prose()
#
# Inputs : midwife_panel.csv
#          dac_midwives.csv
#          artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/cohort_midwives_open_payments_general_<year>.csv
#          /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Outputs: artifacts/address_lead_lag_openpayments_nppes.csv
#          artifacts/address_agreement_by_nppes_freshness.csv
#          artifacts/address_lead_lag_medicaid_nppes_moves.csv
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
  library(purrr)
  library(DBI)
  library(duckdb)
  library(lubridate)
  library(cli)
  library(mysteryroster)
})

source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "trilliant_org_bridge.R"))
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "medicaid_enrollment_intervals.R"))
source(file.path("R", "join_safety.R"))

PANEL_PATH  <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
DAC_PATH    <- Sys.getenv("DAC_MIDWIVES", "dac_midwives.csv")
FROZEN_PATH <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
MEDICAID_DB <- Sys.getenv(
  "MEDICAID_ENROLLMENT_DB",
  "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb"
)

for (p in c(PANEL_PATH, DAC_PATH, FROZEN_PATH, MEDICAID_DB)) {
  if (!file.exists(p)) stop(sprintf("Missing required input: %s", p), call. = FALSE)
}

OUT_LEAD_LAG  <- "artifacts/address_lead_lag_openpayments_nppes.csv"
OUT_FRESHNESS <- "artifacts/address_agreement_by_nppes_freshness.csv"
OUT_MEDICAID  <- "artifacts/address_lead_lag_medicaid_nppes_moves.csv"

cli::cli_h1("Loading Cohort, DAC, Open Payments, and Longitudinal NPPES Panel")

linkage <- read_csv(FROZEN_PATH, col_types = cols(.default = "c"), progress = FALSE)
canon <- canonical_active_primary(as.data.frame(linkage, stringsAsFactors = FALSE)) %>%
  filter(is_valid_individual_npi(npi)) %>%
  mutate(cert_year = as.integer(str_sub(certification_date, -4))) %>%
  select(npi, certification_date, cert_year) %>%
  arrange(npi, cert_year) %>%
  group_by(npi) %>%
  slice(1L) %>%
  ungroup()

dac <- read_csv(DAC_PATH, col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(
    npi,
    state  = str_to_upper(str_squish(practice_state)),
    city   = str_to_upper(str_squish(practice_city)),
    zip5   = str_sub(practice_zip, 1, 5),
    street = norm_street(practice_address)
  )

op_files <- sort(Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv"))
op_all <- map_dfr(op_files, function(f) {
  yr <- as.integer(str_extract(basename(f), "(?<=general_)[0-9]{4}"))
  d <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE)
  if (nrow(d) == 0L || !"recipient_address" %in% names(d)) return(tibble())
  d_modal <- d %>%
    count(npi, recipient_state, recipient_city, recipient_zip, recipient_address, name = "n_txn") %>%
    arrange(npi, desc(n_txn), recipient_state, recipient_city, recipient_zip, recipient_address) %>%
    group_by(npi) %>%
    slice(1L) %>%
    ungroup()
  tibble(
    npi    = d_modal$npi,
    year   = yr,
    state  = str_to_upper(str_squish(d_modal$recipient_state)),
    city   = str_to_upper(str_squish(d_modal$recipient_city)),
    zip5   = str_sub(d_modal$recipient_zip, 1, 5),
    street = norm_street(d_modal$recipient_address)
  )
})

target_npis <- unique(c(canon$npi, dac$npi, op_all$npi))
cli::cli_alert_info("Target NPIs across AMCB cohort, DAC, and Open Payments: {length(target_npis)}")

panel <- read_csv(PANEL_PATH, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(npi %in% target_npis) %>%
  mutate(
    year   = as.integer(snapshot_year),
    state  = str_to_upper(str_squish(practice_state)),
    city   = str_to_upper(str_squish(practice_city)),
    zip5   = str_sub(practice_zip, 1, 5),
    street = norm_street(practice_address)
  ) %>%
  arrange(npi, year, desc(snapshot_date)) %>%
  group_by(npi, year) %>%
  slice(1L) %>%
  ungroup() %>%
  select(npi, year, state, city, zip5, street) %>%
  mysteryroster::attribute_spell_age(attribute = "street")

attrs <- c("state", "city", "zip5", "street")

cli::cli_h1("Analysis 1: Lead-Lag Panel Matrix (Open Payments vs. NPPES)")
lead_lag_table <- mysteryroster::attribute_lead_lag_matrix(
  source_a           = op_all,
  source_b           = panel,
  attributes         = attrs,
  base_year          = 2022L,
  cross_section      = dac,
  cross_section_year = 2026L
)
print(as.data.frame(lead_lag_table), row.names = FALSE)

cli::cli_h1("Analysis 2: Agreement by NPPES Address Freshness & Career Stage")
dac_fresh <- mysteryroster::attribute_agreement_by_spell_age(
  source_a             = dac,
  panel_b              = panel,
  attributes           = attrs,
  target_year          = 2026L,
  comparison_label     = "DAC (2026) vs NPPES (2026)",
  stratification_label = "nppes_street_spell_age"
)

op_fresh <- mysteryroster::attribute_agreement_by_spell_age(
  source_a             = op_all %>% filter(year %in% 2022:2025),
  panel_b              = panel,
  attributes           = attrs,
  comparison_label     = "Open Payments (2022-2025 pooled) vs NPPES (same yr)",
  stratification_label = "nppes_street_spell_age"
)

career_levels <- c(
  "0-2 yrs post-AMCB cert",
  "3-5 yrs post-AMCB cert",
  "6-10 yrs post-AMCB cert",
  "11-20 yrs post-AMCB cert",
  "21+ yrs post-AMCB cert",
  "Not in AMCB canonical cohort"
)
dac_by_career <- dac %>%
  inner_join(
    panel %>% filter(year == 2026L),
    by = "npi",
    suffix = c("_dac", "_np")
  ) %>%
  left_join(canon, by = "npi") %>%
  mutate(
    career_years = 2026L - cert_year,
    stratum = case_when(
      is.na(career_years)     ~ career_levels[6],
      career_years <= 2L      ~ career_levels[1],
      career_years %in% 3:5   ~ career_levels[2],
      career_years %in% 6:10  ~ career_levels[3],
      career_years %in% 11:20 ~ career_levels[4],
      career_years > 20L      ~ career_levels[5]
    )
  ) %>%
  group_by(stratum) %>%
  summarise(
    comparison       = "DAC (2026) vs NPPES (2026)",
    stratification   = "amcb_career_tenure",
    n                = n(),
    state_agree_pct  = round(100 * mean(state_dac == state_np, na.rm = TRUE), 1),
    city_agree_pct   = round(100 * mean(city_dac == city_np, na.rm = TRUE), 1),
    zip5_agree_pct   = round(100 * mean(zip5_dac == zip5_np, na.rm = TRUE), 1),
    street_agree_pct = round(100 * mean(street_dac == street_np, na.rm = TRUE), 1),
    .groups = "drop"
  ) %>%
  mutate(stratum = factor(stratum, levels = career_levels)) %>%
  arrange(stratum) %>%
  mutate(stratum = as.character(stratum))

freshness_table <- bind_rows(dac_fresh, op_fresh, dac_by_career)
print(as.data.frame(freshness_table), row.names = FALSE)

cli::cli_h1("Analysis 3: Medicaid Enrollment Exact Lead/Lag Timing vs. NPPES Moves")
con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)", DBI::dbQuoteString(con, MEDICAID_DB)))

warehouse <- tbl(con, "medicaid.enrollment_segments")
raw_segments <- warehouse %>%
  semi_join(canon %>% select(npi), by = c("NPI" = "npi"), copy = TRUE) %>%
  select(NPI, STATE_CD, ENRL_START_DT, ENRL_END_DT, ENRL_STATUS_CD, PRVDR_TYPE) %>%
  filter(PRVDR_TYPE == "03") %>%
  collect()

dates <- normalize_enrollment_dates(raw_segments$ENRL_START_DT, raw_segments$ENRL_END_DT)
qualifying <- raw_segments %>%
  mutate(start = dates$start, end = dates$end, date_issue = dates$date_issue) %>%
  filter(
    is_qualifying_enrollment_status(ENRL_STATUS_CD),
    is_valid_medicaid_state(STATE_CD),
    is.na(date_issue)
  ) %>%
  transmute(npi = NPI, state = STATE_CD, start = start, end = end)

merged_intervals <- merge_enrollment_intervals(qualifying)
medicaid_timing_table <- mysteryroster::enrollment_move_lead_lag(
  panel     = panel %>% semi_join(canon, by = "npi"),
  intervals = merged_intervals
)
print(as.data.frame(medicaid_timing_table), row.names = FALSE)

cli::cli_h1("Programmatic Manuscript Text (from mysteryroster::format_no_gold_standard_prose)")
prose <- mysteryroster::format_no_gold_standard_prose(
  lead_lag_table,
  freshness_table,
  medicaid_timing_table
)
cat(prose$combined_text, "\n")

all_inputs <- c(PANEL_PATH, DAC_PATH, FROZEN_PATH, MEDICAID_DB, op_files)
write_with_provenance(lead_lag_table, OUT_LEAD_LAG, inputs = all_inputs)
write_with_provenance(freshness_table, OUT_FRESHNESS, inputs = all_inputs)
write_with_provenance(medicaid_timing_table, OUT_MEDICAID, inputs = all_inputs)
cli::cli_alert_success("Wrote {OUT_LEAD_LAG}, {OUT_FRESHNESS}, and {OUT_MEDICAID}")
