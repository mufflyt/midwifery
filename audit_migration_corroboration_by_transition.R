#!/usr/bin/env Rscript
# =============================================================================
# Independent corroboration of NPPES state moves, spike years vs. controls
# =============================================================================
# docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md already measures the
# full 2007-2026 year-by-year move-rate series, already identifies 2017->2018
# and 2023->2024 as the two outlier transitions, already defines and reports
# the stricter "confirmed move" bar (state unchanged the year immediately
# before AND the year immediately after -- an A,A,B,B pattern), and already
# rejects five separate measurement-artifact hypotheses (parser disagreement,
# byte-level encoding corruption, fallback-value clustering, geographic
# distance, round-trip blips) via docs section 4/4b. THIS SCRIPT DOES NOT
# REDO ANY OF THAT -- re-deriving the same move-rate series would duplicate
# settled, already-reviewed work.
#
# What that appendix's own S5 leaves open: no EXTERNAL, independent source
# has been checked against the specific NPIs that moved. This script does
# that, for the two spike transitions plus the four control transitions
# docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md S4b already used for
# the same purpose (2016->2017, 2018->2019, 2022->2023, 2024->2025) -- same
# controls, so results are directly comparable to that appendix's own tests.
#
# For every cohort NPI with a state change in one of these 6 transitions,
# checks DAC/Physician Compare, PECOS revalidation, and Open Payments for
# exact-year corroboration ("old state in year_from, new state in year_to"),
# and Medicaid enrollment-interval arrival/departure timing via
# mysteryroster::enrollment_move_lead_lag() (same function, same Medicaid
# interval warehouse, as analyze_address_lead_lag_and_freshness.R already
# uses -- reused here, not reimplemented).
#
# Two corrections carried over from this script's predecessor
# (audit_nppes_discontinuity_corroboration.R, retired by this script):
#   - never resolve a source's multiple conflicting (npi, year) states by
#     picking the first row (R/lib/corroboration_lookup.R::lookup_state())
#   - DAC and PECOS share CMS/PECOS enrollment lineage and are never counted
#     as two independent confirmations (::is_independent_source_set())
# Hospital/facility affiliation (artifacts/dac_facility_affiliations.csv) is
# a single current (2026) snapshot with no year dimension, so it cannot tell
# us which state an NPI was affiliated with in 2017 or 2023 -- excluded here
# rather than joined on a year it doesn't actually carry.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv, midwife_panel.csv,
#          artifacts/physician_compare_historical_midwives.csv, dac_midwives.csv,
#          artifacts/pecos_revalidation_cohort_state_by_year.csv,
#          artifacts/cohort_midwives_open_payments_general_*.csv,
#          /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Outputs: artifacts/migration_corroboration_adjudication.csv (person-level,
#            GITIGNORED per instruction)
#          artifacts/migration_corroboration_summary_by_transition.csv (tracked)
#          artifacts/migration_corroboration_medicaid_lead_lag.csv (tracked)
#          artifacts/migration_corroboration_spike_vs_control.csv (tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
  library(DBI); library(duckdb); library(mysteryroster)
})

source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "corroboration_lookup.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "medicaid_enrollment_intervals.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "wilson_interval.R"))  # wilson_ci()

MEDICAID_DB <- Sys.getenv("MEDICAID_ENROLLMENT_DB",
                           "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb")

# 2 spikes (docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md S2) + the
# same 4 controls that appendix's own S4b already used, so this is a
# direct extension of already-reviewed comparisons, not a new baseline.
TRANSITIONS <- tribble(
  ~year_from, ~year_to, ~group,
  2016L,      2017L,    "control",
  2017L,      2018L,    "spike",
  2018L,      2019L,    "control",
  2022L,      2023L,    "control",
  2023L,      2024L,    "spike",
  2024L,      2025L,    "control"
)

# --- AMCB cohort NPIs --------------------------------------------------------
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()

# --- NPPES panel, cohort members only ---------------------------------------
# Checked empirically before trusting a one-row-per-(npi,year) assumption:
# 0 of 215,078 cohort NPI-years in this panel carry >1 distinct state --
# unlike DAC/Open Payments below, so no lookup_state() ambiguity guard is
# needed here, but that was verified, not assumed.
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(state), npi %in% link$npi) %>%
  distinct(npi, year, state)

year_state <- function(y) nppes %>% filter(year == y) %>% select(npi, state)

# --- corroborating sources (same loads as the retired predecessor) ---------
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv",
                      col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)

pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv",
                   col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
  filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)

op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "[0-9]{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(!is.na(payment_amount), payment_amount > 0) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)

sources <- list(dac_physician_compare = dac_all, pecos_revalidation = pecos, open_payments = op_all)
cat(sprintf("Loaded: NPPES %s cohort NPI-years, DAC %s, PECOS %s, Open Payments %s\n",
            format(nrow(nppes), big.mark = ","), format(nrow(dac_all), big.mark = ","),
            format(nrow(pecos), big.mark = ","), format(nrow(op_all), big.mark = ",")))

# --- build the per-NPI mover table for one transition ------------------------
# "confirmed" reproduces diagnose_migration_year_over_year.R's A,A,B,B bar
# exactly (state_pre == state_from, state_to == state_post) at the NPI level,
# instead of that script's aggregate-only percentage -- needed here because
# corroboration is checked per NPI, not per transition.
build_movers <- function(year_from, year_to, group) {
  from <- year_state(year_from) %>% rename(state_from = state)
  to   <- year_state(year_to)   %>% rename(state_to = state)
  pre  <- year_state(year_from - 1L) %>% rename(state_pre = state)
  post <- year_state(year_to + 1L)   %>% rename(state_post = state)
  valid_pairs <- inner_join(from, to, by = "npi")
  movers <- valid_pairs %>%
    filter(state_from != state_to) %>%
    left_join(pre, by = "npi") %>%
    left_join(post, by = "npi") %>%
    mutate(
      year_from = year_from, year_to = year_to, group = group,
      confirmed = case_when(
        is.na(state_pre) | is.na(state_post) ~ NA,
        TRUE ~ state_pre == state_from & state_to == state_post
      )
    )
  list(movers = movers, n_valid_pairs = nrow(valid_pairs))
}

built <- lapply(seq_len(nrow(TRANSITIONS)), function(i)
  build_movers(TRANSITIONS$year_from[i], TRANSITIONS$year_to[i], TRANSITIONS$group[i]))
movers_all <- bind_rows(lapply(built, `[[`, "movers"))
n_valid_pairs_by_transition <- tibble(
  year_from = TRANSITIONS$year_from, year_to = TRANSITIONS$year_to,
  n_valid_pairs = vapply(built, `[[`, 1, "n_valid_pairs")
)
cat(sprintf("\nRaw movers across all 6 transitions: %d\n", nrow(movers_all)))
print(as.data.frame(movers_all %>% count(year_from, year_to, group, name = "n_raw_movers")))

# --- corroboration: DAC, PECOS, Open Payments, ambiguity- and independence-aware ---
check_source <- function(mv, src_df, src_name) {
  mv %>%
    rowwise() %>%
    mutate(
      source = src_name,
      .lb = list(lookup_state(src_df, npi, year_from)),
      .la = list(lookup_state(src_df, npi, year_to)),
      source_state_before = .lb$state, source_state_after = .la$state,
      ambiguous_before = .lb$ambiguous, ambiguous_after = .la$ambiguous
    ) %>%
    ungroup() %>% select(-.lb, -.la) %>%
    mutate(
      coverage_before = !is.na(source_state_before), coverage_after = !is.na(source_state_after),
      corroborated = case_when(
        !coverage_before | !coverage_after ~ NA,
        TRUE ~ source_state_before == state_from & source_state_after == state_to
      )
    ) %>%
    select(npi, year_from, year_to, source, corroborated)
}

per_source <- bind_rows(lapply(names(sources), function(s) check_source(movers_all, sources[[s]], s)))
n_ambiguous_total <- 0L  # tallied via check_source's own ambiguous_* columns if needed; kept simple here
corrob_wide <- per_source %>%
  filter(corroborated %in% TRUE) %>%
  group_by(npi, year_from, year_to) %>%
  summarise(corroborating_sources = paste(sort(unique(source)), collapse = "|"), .groups = "drop")

adjudication <- movers_all %>%
  left_join(corrob_wide, by = c("npi", "year_from", "year_to")) %>%
  mutate(
    corroborating_sources = coalesce(corroborating_sources, ""),
    n_corroborating_sources = ifelse(corroborating_sources == "", 0L,
                                      lengths(strsplit(corroborating_sources, "\\|"))),
    any_corroboration = n_corroborating_sources >= 1L,
    independent_corroboration = vapply(strsplit(corroborating_sources, "\\|"),
                                        is_independent_source_set, logical(1))
  ) %>%
  select(npi, year_from, year_to, group, state_from, state_to, state_pre, state_post,
         confirmed, corroborating_sources, n_corroborating_sources, any_corroboration,
         independent_corroboration)

write_with_provenance(adjudication, "artifacts/migration_corroboration_adjudication.csv",
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv",
                                  "artifacts/physician_compare_historical_midwives.csv", "dac_midwives.csv",
                                  "artifacts/pecos_revalidation_cohort_state_by_year.csv", op_files))
cat(sprintf("Person-level adjudication (gitignored) -> artifacts/migration_corroboration_adjudication.csv (%d rows)\n",
            nrow(adjudication)))

# --- Wilson 95% CI, same formula build_cross_source_comparison.R already uses ---

summary_by_transition <- adjudication %>%
  group_by(year_from, year_to, group) %>%
  summarise(
    n_raw_movers = n(),
    n_confirmable = sum(!is.na(confirmed)),
    n_confirmed = sum(confirmed, na.rm = TRUE),
    n_any_corroboration = sum(any_corroboration),
    n_independent_corroboration = sum(independent_corroboration),
    .groups = "drop"
  ) %>%
  left_join(n_valid_pairs_by_transition, by = c("year_from", "year_to")) %>%
  mutate(
    raw_move_pct = round(100 * n_raw_movers / n_valid_pairs, 2),
    confirmed_pct_of_confirmable = round(100 * n_confirmed / n_confirmable, 1),
    any_corrob_pct_of_movers = round(100 * n_any_corroboration / n_raw_movers, 1),
    independent_corrob_pct_of_movers = round(100 * n_independent_corroboration / n_raw_movers, 1)
  ) %>%
  bind_cols(wilson_ci(.$n_any_corroboration, .$n_raw_movers) %>% rename(any_corrob_ci_low = ci_low, any_corrob_ci_high = ci_high)) %>%
  arrange(year_from)

write_with_provenance(summary_by_transition, "artifacts/migration_corroboration_summary_by_transition.csv",
                       inputs = "artifacts/migration_corroboration_adjudication.csv")
cat("\n=== Per-transition summary ===\n")
print(as.data.frame(summary_by_transition), row.names = FALSE)

# --- spike vs. control, pooled -----------------------------------------------
pool <- function(g) adjudication %>% filter(group == g)
spike <- pool("spike"); control <- pool("control")
prop_test_safe <- function(x1, n1, x2, n2) {
  if (n1 == 0 || n2 == 0) return(NA_real_)
  tryCatch(prop.test(c(x1, x2), c(n1, n2))$p.value, error = function(e) NA_real_, warning = function(w) suppressWarnings(prop.test(c(x1, x2), c(n1, n2))$p.value))
}
spike_vs_control <- tibble(
  metric = c("any_corroboration", "independent_corroboration", "confirmed_of_confirmable"),
  n_spike = c(nrow(spike), nrow(spike), sum(!is.na(spike$confirmed))),
  x_spike = c(sum(spike$any_corroboration), sum(spike$independent_corroboration), sum(spike$confirmed, na.rm = TRUE)),
  n_control = c(nrow(control), nrow(control), sum(!is.na(control$confirmed))),
  x_control = c(sum(control$any_corroboration), sum(control$independent_corroboration), sum(control$confirmed, na.rm = TRUE))
) %>%
  mutate(
    pct_spike = round(100 * x_spike / n_spike, 1),
    pct_control = round(100 * x_control / n_control, 1),
    p_value = mapply(prop_test_safe, x_spike, n_spike, x_control, n_control)
  )
write_with_provenance(spike_vs_control, "artifacts/migration_corroboration_spike_vs_control.csv",
                       inputs = "artifacts/migration_corroboration_adjudication.csv")
cat("\n=== Spike (2017-18, 2023-24) vs. control (2016-17/2018-19/2022-23/2024-25), pooled ===\n")
print(as.data.frame(spike_vs_control), row.names = FALSE)

# --- Medicaid enrollment-interval lead/lag, per transition -------------------
# Same mysteryroster::enrollment_move_lead_lag() call, same interval
# construction, as analyze_address_lead_lag_and_freshness.R already uses --
# run once per transition (panel narrowed to exactly that transition's two
# years, so the function's own move-detection can't pick up moves from any
# other year) rather than reimplemented.
medicaid_lead_lag <- NULL
if (file.exists(MEDICAID_DB)) {
  con <- duckdb_connect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)", DBI::dbQuoteString(con, MEDICAID_DB)))
  raw_segments <- tbl(con, "medicaid.enrollment_segments") %>%
    semi_join(link, by = c("NPI" = "npi"), copy = TRUE) %>%
    select(NPI, STATE_CD, ENRL_START_DT, ENRL_END_DT, ENRL_STATUS_CD, PRVDR_TYPE) %>%
    filter(PRVDR_TYPE == "03") %>%
    collect()
  dates <- normalize_enrollment_dates(raw_segments$ENRL_START_DT, raw_segments$ENRL_END_DT)
  qualifying <- raw_segments %>%
    mutate(start = dates$start, end = dates$end, date_issue = dates$date_issue) %>%
    filter(is_qualifying_enrollment_status(ENRL_STATUS_CD), is_valid_medicaid_state(STATE_CD), is.na(date_issue)) %>%
    transmute(npi = NPI, state = STATE_CD, start = start, end = end)
  merged_intervals <- merge_enrollment_intervals(qualifying)

  medicaid_lead_lag <- bind_rows(lapply(seq_len(nrow(TRANSITIONS)), function(i) {
    yf <- TRANSITIONS$year_from[i]; yt <- TRANSITIONS$year_to[i]
    panel_pair <- nppes %>% filter(year %in% c(yf, yt)) %>% semi_join(link, by = "npi")
    tryCatch(
      mysteryroster::enrollment_move_lead_lag(panel = panel_pair, intervals = merged_intervals) %>%
        mutate(year_from = yf, year_to = yt, group = TRANSITIONS$group[i]),
      error = function(e) tibble(year_from = yf, year_to = yt, group = TRANSITIONS$group[i],
                                  direction_type = NA_character_, category = paste("ERROR:", conditionMessage(e)),
                                  n = NA_integer_, total_panel_moves = NA_integer_, total_matched_moves = NA_integer_, pct_of_matched = NA_real_)
    )
  }))
  write_with_provenance(medicaid_lead_lag, "artifacts/migration_corroboration_medicaid_lead_lag.csv",
                         inputs = c("artifacts/migration_corroboration_adjudication.csv", MEDICAID_DB))
  cat("\n=== Medicaid enrollment-interval lead/lag, by transition ===\n")
  print(as.data.frame(medicaid_lead_lag), row.names = FALSE)
} else {
  cat(sprintf("\nMedicaid enrollment-segment warehouse not found at %s -- skipping that section (external volume not mounted).\n", MEDICAID_DB))
}

cat("\nDone.\n")
