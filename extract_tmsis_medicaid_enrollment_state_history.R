#!/usr/bin/env Rscript
# =============================================================================
# Medicaid enrollment state, by year, from dated T-MSIS enrollment intervals
# =============================================================================
# A 4th truth-fusion source for build_truth_fusion_predictions.R, alongside
# NPPES / DAC+PECOS-combined / Open Payments. DISTINCT from
# extract_tmsis_medicaid_spending_history.R (billing activity -- claim
# lines, patients, dollars) and from analyze_address_lead_lag_and_
# freshness.R's own use of this same warehouse (which compares enrollment
# TIMING against NPPES panel moves via mysteryroster::enrollment_move_
# lead_lag(), never emits a per-year STATE claim). This script turns the
# same validated, merged enrollment INTERVALS into one of mysteryroster's
# expected (npi, year, state) claims -- the one genuinely new, properly
# dated source identified by a parallel mysteryroster-side source audit
# (2026-11-05): PPEF, Doximity/Healthgrades, hospital/facility affiliation,
# state boards, and Trilliant are all either already folded into the
# existing sources or current-snapshot-only with no real effective date.
#
# An NPI with intervals for TWO DIFFERENT states overlapping the SAME
# calendar year (a real mid-year state switch) yields TWO claim rows for
# that (npi, year) -- a genuine multi-value claim, never arbitrarily
# collapsed to one, same disposition every other source in this build
# gets (R/lib/truth_fusion_claims.R, attribute_truth_fusion()'s own
# on_source_conflict = "single_value").
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Output : artifacts/tmsis_medicaid_enrollment_state_by_year.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "medicaid_enrollment_intervals.R"))
source(file.path("R", "lib", "truth_fusion_claims.R"))

MEDICAID_DB <- samsung_duckdb_path("DuckDB/medicaid_provider_enrollment_segments.duckdb",
                                   "MEDICAID_ENROLLMENT_DB")
if (!file.exists(MEDICAID_DB))
  stop(sprintf("Medicaid enrollment-segment warehouse not found at %s. It lives on an external volume; mount it or adjust the path.", MEDICAID_DB), call. = FALSE)

YEARS <- 2013:2026

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(link), big.mark = ",")))

con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)", DBI::dbQuoteString(con, MEDICAID_DB)))

raw_segments <- tbl(con, "medicaid.enrollment_segments") %>%
  semi_join(link, by = c("NPI" = "npi"), copy = TRUE) %>%
  select(NPI, STATE_CD, ENRL_START_DT, ENRL_END_DT, ENRL_STATUS_CD, PRVDR_TYPE) %>%
  filter(PRVDR_TYPE == "03") %>%
  collect()
cat(sprintf("Raw qualifying-provider-type segments for cohort NPIs: %s\n", format(nrow(raw_segments), big.mark = ",")))

dates <- normalize_enrollment_dates(raw_segments$ENRL_START_DT, raw_segments$ENRL_END_DT)
qualifying <- raw_segments %>%
  mutate(start = dates$start, end = dates$end, date_issue = dates$date_issue) %>%
  filter(is_qualifying_enrollment_status(ENRL_STATUS_CD), is_valid_medicaid_state(STATE_CD), is.na(date_issue)) %>%
  transmute(npi = NPI, state = STATE_CD, start = start, end = end)
cat(sprintf("Qualifying enrollment segments (valid status, valid state, valid dates): %s\n", format(nrow(qualifying), big.mark = ",")))

merged <- merge_enrollment_intervals(qualifying)
cat(sprintf("Merged into %s non-overlapping (npi, state) intervals across %s distinct NPIs\n",
            format(nrow(merged), big.mark = ","), format(n_distinct(merged$npi), big.mark = ",")))

# --- expand each interval into one claim row per calendar year it overlaps ---
by_npi_year <- expand_intervals_to_year_claims(merged, YEARS)

n_multivalue <- by_npi_year %>% count(npi, year) %>% filter(n > 1) %>% nrow()
cat(sprintf("Expanded to %s (npi, year, state) claims across %s distinct npi-years (%d npi-years with >1 state -- a real mid-year switch, kept as 2 separate claims, not resolved)\n",
            format(nrow(by_npi_year), big.mark = ","), format(n_distinct(by_npi_year %>% select(npi, year)), big.mark = ","), n_multivalue))

write_csv(by_npi_year, "artifacts/tmsis_medicaid_enrollment_state_by_year.csv", na = "")
cat("written: artifacts/tmsis_medicaid_enrollment_state_by_year.csv\n")
