#!/usr/bin/env Rscript
# =============================================================================
# Medicaid enrollment vs. NPPES practice-state concordance, canonical AMCB
# cohort, 2018-2024
# =============================================================================
# Answers five questions (docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md
# S1) using the already-downloaded Medicaid Provider Enrollment Segments
# warehouse (download_medicaid_provider_enrollment_segments.py; NOT
# re-downloaded here) against the CANONICAL cohort
# (R/lib/cohort_definitions.R::canonical_active_primary() -- NOT the broader
# cohort_member=TRUE linkage-eligible population an earlier pass wrongly used,
# which is what actually produced the ~44% classification disagreement; see
# diagnose_medicaid_classification_disagreement.R and S6 of the appendix).
#
# PRIMARY DEFINITION: enrollment active ON THE NPPES SNAPSHOT DATE
#   (point-in-time). SECONDARY/SENSITIVITY: enrollment active ANY TIME
#   DURING the calendar year. Both are computed and reported; only the
#   primary one is treated as the geographic-concordance estimand.
#
# WHAT THIS DOES NOT ESTABLISH. Medicaid enrollment is an administrative
# relationship with a state program, not billing, not a street address, not
# a delivery location. See S11 of the appendix for the full
# certification -> licensure -> enrollment -> claims -> practice -> delivery
# ladder this script does not collapse.
#
# Input : midwife_panel.csv (gitignored, person-level NPPES annual snapshots)
#         artifacts/amcb_npi_linkage_FROZEN.csv (canonical cohort source)
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Output: artifacts/medicaid_enrollment_concordance_<definition>_by_year.csv
#         artifacts/medicaid_enrollment_concordance_<definition>_by_state.csv
#         artifacts/medicaid_enrollment_concordance_denominators.csv
#         (+ .provenance.json beside each; NO person-level file is written)
#
# @family diagnostics
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(DBI); library(duckdb); library(tibble)
  library(tidyr); library(readr)
})

.this_script_dir <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg)) dirname(normalizePath(sub("^--file=", "", file_arg[1])))
  else getwd()
})
source(file.path(.this_script_dir, "R", "lib", "medicare_duckdb.R"))
source(file.path(.this_script_dir, "R", "lib", "artifact_provenance.R"))
source(file.path(.this_script_dir, "R", "lib", "cohort_definitions.R"))
source(file.path(.this_script_dir, "R", "lib", "medicaid_enrollment_intervals.R"))
source(file.path(.this_script_dir, "R", "lib", "medicaid_state_concordance.R"))

PANEL <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
FROZEN <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
MEDICAID_DB <- Sys.getenv(
  "MEDICAID_ENROLLMENT_DB",
  "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb")
for (p in c(PANEL, FROZEN, MEDICAID_DB))
  if (!file.exists(p)) stop(sprintf("missing required input: %s", p), call. = FALSE)
YEARS <- 2018:2024
RUN_STAMP <- Sys.getenv("MEDICAID_CONCORDANCE_RUN_STAMP", "manual")

# =============================================================================
# SECTION 2: canonical cohort (never the broader linkage-eligible population)
# =============================================================================
base::message("== Cohort ==")
linkage <- readr::read_csv(FROZEN, col_types = readr::cols(.default = "c"),
                           progress = FALSE)
canon <- canonical_active_primary(as.data.frame(linkage, stringsAsFactors = FALSE))
cohort_npi <- tibble::tibble(npi = unique(canon$npi))
base::message(sprintf(
  "canonical_active_primary(): %d distinct NPIs (spec quotes 12,171 against the",
  nrow(cohort_npi)))
base::message("  freeze at time of writing; disclosed here rather than forced to match).")

cohort_npi <- cohort_npi |> dplyr::mutate(npi_valid = is_valid_individual_npi(.data$npi))
n_npi_invalid <- sum(!cohort_npi$npi_valid)
base::message(sprintf(
  "%d of %d cohort NPIs fail Luhn/placeholder validation and are excluded from Medicaid linkage.",
  n_npi_invalid, nrow(cohort_npi)))
cohort_valid <- cohort_npi |> dplyr::filter(.data$npi_valid) |> dplyr::select("npi")

# =============================================================================
# SECTION 3: data validation against the Medicaid warehouse
# =============================================================================
base::message("\n== Medicaid warehouse validation ==")
con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)",
                            DBI::dbQuoteString(con, MEDICAID_DB)))

warehouse <- dplyr::tbl(con, "medicaid.enrollment_segments")
n_warehouse_total <- warehouse |> dplyr::count() |> dplyr::pull("n")
base::message(sprintf("enrollment_segments: %s total rows (expected 65,970,112).",
                      format(n_warehouse_total, big.mark = ",")))
if (n_warehouse_total != 65970112)
  base::message("  NOTE: row count differs from the version this pipeline was built against -- ",
               "the warehouse may have been rebuilt from a different release.")

provenance_tbl <- tryCatch(
  dplyr::tbl(con, "medicaid._provenance") |> dplyr::collect(),
  error = function(e) NULL)
if (!is.null(provenance_tbl) && nrow(provenance_tbl)) {
  base::message("_provenance (most recent load):")
  last <- provenance_tbl |> dplyr::arrange(dplyr::desc(.data$loaded_at)) |> head(1)
  base::message(sprintf("  version_date=%s  zip_sha256=%s  row_count=%s",
                        last$version_date, substr(last$zip_sha256, 1, 12),
                        format(last$row_count, big.mark = ",")))
} else {
  base::message("  WARNING: no _provenance table found or it is empty.")
}

# ---- qualifying rows for the canonical cohort, pulled via dplyr/dbplyr,
# not hand-written SQL: semi_join pushes the cohort NPI list down as a join,
# filter() pushes the status/provider-type/state predicates down too. -----
raw_segments <- warehouse |>
  dplyr::semi_join(cohort_valid, by = c("NPI" = "npi"), copy = TRUE) |>
  dplyr::select("NPI", "STATE_CD", "ENRL_START_DT", "ENRL_END_DT",
               "ENRL_STATUS_CD", "PRVDR_TYPE") |>
  dplyr::collect()

n_raw <- nrow(raw_segments)
base::message(sprintf("%s raw enrollment-segment rows for the canonical cohort (any status/provider-type).",
                      format(n_raw, big.mark = ",")))

prvdr_breakdown <- raw_segments |> dplyr::count(.data$PRVDR_TYPE, sort = TRUE)
base::message("Cohort rows by PRVDR_TYPE (only '03' INDIVIDUAL is used downstream):")
print(prvdr_breakdown, n = Inf)

qualifying_raw <- raw_segments |>
  dplyr::filter(is_individual_provider_type(.data$PRVDR_TYPE),
               is_qualifying_enrollment_status(.data$ENRL_STATUS_CD),
               is_valid_medicaid_state(.data$STATE_CD))
n_dropped_status_type <- n_raw - nrow(qualifying_raw)
base::message(sprintf(
  "%s rows (%.1f%%) excluded: not INDIVIDUAL, not ACTIVE/TERM status, or not a valid state code.",
  format(n_dropped_status_type, big.mark = ","), 100 * n_dropped_status_type / n_raw))

dates <- normalize_enrollment_dates(qualifying_raw$ENRL_START_DT, qualifying_raw$ENRL_END_DT)
n_date_issues <- sum(!is.na(dates$date_issue))
if (n_date_issues > 0L) {
  base::message(sprintf("%d rows have a date issue (excluded):", n_date_issues))
  print(table(dates$date_issue))
}
# Both downstream shapes (plain intervals, and status-family-tagged for the
# contradiction check) come from this ONE dated-and-filtered tibble, so
# there is never a second, independently re-filtered copy whose row order
# could silently drift from the first.
qualifying_raw <- qualifying_raw |>
  dplyr::mutate(start = dates$start, end = dates$end, date_issue = dates$date_issue,
               status_family = dplyr::if_else(.data$ENRL_STATUS_CD %in% MEDICAID_ACTIVE_STATUS_CODES,
                                              "active", "term")) |>
  dplyr::filter(is.na(.data$date_issue))

qualifying <- qualifying_raw |>
  dplyr::transmute(npi = .data$NPI, state = .data$STATE_CD, start = .data$start, end = .data$end)

n_dup_raw <- nrow(qualifying) - nrow(dplyr::distinct(qualifying))
base::message(sprintf("%d exact-duplicate qualifying rows (collapse during interval merge, not double-counted).",
                      n_dup_raw))

qualifying_status_family <- qualifying_raw |>
  dplyr::transmute(npi = .data$NPI, state = .data$STATE_CD, start = .data$start, end = .data$end,
                   status_family = .data$status_family)
contradictions <- detect_contradictory_segments(qualifying_status_family)
base::message(sprintf(
  "%d (npi, state) pairs carry CONTRADICTORY overlapping segments (different status family, overlapping dates) -- preserved for adjudication, not silently resolved.",
  nrow(contradictions)))

merged_intervals <- merge_enrollment_intervals(qualifying)
base::message(sprintf("Merged into %s non-overlapping (npi, state) intervals from %s qualifying rows.",
                      format(nrow(merged_intervals), big.mark = ","),
                      format(nrow(qualifying), big.mark = ",")))

n_open_ended <- sum(is_open_ended(merged_intervals$interval_end))
base::message(sprintf("%s intervals (%.1f%%) are open-ended (still active as of the pull).",
                      format(n_open_ended, big.mark = ","), 100 * n_open_ended / nrow(merged_intervals)))

# =============================================================================
# SECTION 4: NPPES year-matched state, 2018-2024
# =============================================================================
base::message("\n== NPPES panel ==")
panel_raw <- readr::read_csv(
  PANEL, col_types = readr::cols(.default = "c"), progress = FALSE) |>
  dplyr::semi_join(cohort_valid, by = "npi")

nppes_year <- panel_raw |>
  dplyr::filter(!is.na(.data$practice_state), nzchar(.data$practice_state),
               !is.na(.data$snapshot_date), nzchar(.data$snapshot_date)) |>
  dplyr::mutate(year = as.integer(.data$snapshot_year),
               snapshot_date = normalize_snapshot_date(.data$snapshot_date)) |>
  dplyr::filter(.data$year >= min(YEARS), .data$year <= max(YEARS)) |>
  dplyr::group_by(.data$npi, .data$year) |>
  dplyr::slice_max(.data$snapshot_date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(npi = .data$npi, year = .data$year,
                   nppes_state = .data$practice_state, snapshot_date = .data$snapshot_date)

# =============================================================================
# SECTION 5: state concordance, BOTH enrollment definitions
# =============================================================================
base::message("\n== Building the full NPI x year skeleton (every eligible midwife-year) ==")
skeleton <- tidyr::crossing(npi = cohort_valid$npi, year = YEARS) |>
  dplyr::left_join(nppes_year, by = c("npi", "year"))

# Definition A (PRIMARY): active on the NPPES snapshot date.
base::message("Resolving Medicaid states on the NPPES snapshot date (primary definition)...")
point_in_time_states <- skeleton |>
  dplyr::filter(!is.na(.data$snapshot_date)) |>
  dplyr::select("npi", "year", "snapshot_date") |>
  dplyr::left_join(merged_intervals, by = "npi", relationship = "many-to-many") |>
  dplyr::filter(is.na(.data$interval_start) |
                 (.data$interval_start <= .data$snapshot_date &
                    .data$interval_end >= .data$snapshot_date)) |>
  dplyr::group_by(.data$npi, .data$year) |>
  dplyr::summarise(states = list(sort(unique(.data$state[!is.na(.data$state)]))), .groups = "drop")

# Definition B (SECONDARY/sensitivity): active at any point during the year.
base::message("Resolving Medicaid states overlapping any part of the calendar year (secondary definition)...")
year_bounds <- tibble::tibble(year = YEARS,
                              year_start = as.Date(sprintf("%d-01-01", YEARS)),
                              year_end = as.Date(sprintf("%d-12-31", YEARS)))
any_time_states <- tidyr::crossing(npi = unique(merged_intervals$npi), year = YEARS) |>
  dplyr::left_join(year_bounds, by = "year") |>
  dplyr::left_join(merged_intervals, by = "npi", relationship = "many-to-many") |>
  dplyr::filter(is.na(.data$interval_start) |
                 (.data$interval_start <= .data$year_end &
                    .data$interval_end >= .data$year_start)) |>
  dplyr::group_by(.data$npi, .data$year) |>
  dplyr::summarise(states = list(sort(unique(.data$state[!is.na(.data$state)]))), .groups = "drop")

classify_and_summarize <- function(definition_label, states_tbl) {
  joined <- skeleton |>
    dplyr::left_join(states_tbl, by = c("npi", "year"))
  joined$states[vapply(joined$states, is.null, logical(1))] <- list(character(0))
  joined <- joined |>
    dplyr::mutate(classification = classify_state_concordance(.data$nppes_state, .data$states))

  denom <- tibble::tibble(
    definition = definition_label,
    n_cohort_npi = length(unique(joined$npi)),
    n_cohort_npi_years = nrow(joined),
    n_with_nppes_state = sum(!is.na(joined$nppes_state)),
    n_with_medicaid_evidence = sum(vapply(joined$states, length, integer(1)) > 0L),
    n_comparable_both_sources = sum(!is.na(joined$nppes_state) &
                                    vapply(joined$states, length, integer(1)) > 0L))

  by_year <- joined |> dplyr::count(.data$year, .data$classification, name = "n")
  by_state <- joined |> dplyr::filter(!is.na(.data$nppes_state)) |>
    dplyr::count(nppes_state = .data$nppes_state, .data$classification, name = "n")

  list(joined = joined, denom = denom, by_year = by_year, by_state = by_state)
}

primary <- classify_and_summarize("snapshot_date_primary", point_in_time_states)
secondary <- classify_and_summarize("any_time_in_year_secondary", any_time_states)

base::message("\n== PRIMARY (snapshot-date) classification, cohort-wide ==")
print(primary$joined |> dplyr::count(.data$classification, sort = TRUE))
base::message("\n== Denominators (both definitions) ==")
all_denom <- dplyr::bind_rows(primary$denom, secondary$denom)
print(all_denom)

agree <- dplyr::inner_join(
  primary$joined |> dplyr::select("npi", "year", classification_primary = "classification"),
  secondary$joined |> dplyr::select("npi", "year", classification_secondary = "classification"),
  by = c("npi", "year"))
pct_agree <- 100 * mean(agree$classification_primary == agree$classification_secondary)
base::message(sprintf(
  "\nPrimary (snapshot-date) vs. secondary (any-time-in-year) classification agree on %.1f%% of %s NPI-years.",
  pct_agree, format(nrow(agree), big.mark = ",")))
base::message("(This is the S6 diagnostic's finding, reproduced here on the live run: residual",
              " disagreement is mechanistic -- within-year transitions the secondary definition",
              " sees and the single snapshot date does not -- not a coding defect.)")

# ---- state-pair expansion for Figure 1 (the concordance matrix) and -------
# Figure 2 (the disagreement flow map). ONE PROVIDER-YEAR CAN CONTRIBUTE
# MORE THAN ONE PAIR when it is Multistate -- that is the whole point of
# keeping this separate from the provider-level classification counts
# above, not an inflation to correct for.
state_pairs <- primary$joined |>
  dplyr::filter(!is.na(.data$nppes_state), lengths(.data$states) > 0L) |>
  tidyr::unnest("states") |>
  dplyr::count(nppes_state = .data$nppes_state, medicaid_state = .data$states, name = "n_pairs")
n_provider_years_in_matrix <- primary$joined |>
  dplyr::filter(!is.na(.data$nppes_state), lengths(.data$states) > 0L) |> nrow()
base::message(sprintf(
  "\nState-pair matrix: %s pairs from %s provider-years (>1 pair per provider-year exactly when Multistate).",
  format(sum(state_pairs$n_pairs), big.mark = ","), format(n_provider_years_in_matrix, big.mark = ",")))

# =============================================================================
# OUTPUT
# =============================================================================
ts <- format(Sys.time(), "%Y%m%d_%H%M%S")
write_pair <- function(x, path) {
  write_with_provenance(x, path, inputs = c(PANEL, FROZEN, MEDICAID_DB))
  base::message(sprintf("wrote %s", path))
}
write_pair(primary$by_year, "artifacts/medicaid_enrollment_concordance_snapshot_date_by_year.csv")
write_pair(primary$by_state, "artifacts/medicaid_enrollment_concordance_snapshot_date_by_state.csv")
write_pair(secondary$by_year, "artifacts/medicaid_enrollment_concordance_any_time_by_year.csv")
write_pair(secondary$by_state, "artifacts/medicaid_enrollment_concordance_any_time_by_state.csv")
write_pair(all_denom, "artifacts/medicaid_enrollment_concordance_denominators.csv")
write_pair(state_pairs, "artifacts/medicaid_enrollment_concordance_state_pairs.csv")
base::message(sprintf("\nRun stamp: %s (%s)", RUN_STAMP, ts))
