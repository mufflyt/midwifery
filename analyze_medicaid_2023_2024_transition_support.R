#!/usr/bin/env Rscript
# =============================================================================
# 2023->2024 NPPES interstate moves: does Medicaid enrollment corroborate
# them, and is corroboration enriched among movers vs. stayers?
# =============================================================================
# Six-category transition-support classification (R/lib/medicaid_state_
# concordance.R::classify_transition_support()), applied to every FROZEN
# canonical-cohort NPPES interstate mover between the 2023 and 2024
# snapshots, with NPPES stayers as the comparison group.
#
# THIS IS SUPPORTING EVIDENCE, NOT PROOF OF A PHYSICAL MOVE. A midwife can
# hold multi-state Medicaid enrollment, or change enrollment without moving,
# or move without any Medicaid enrollment change in either state. Each
# classification category says exactly what it found, no more. Association
# with NPPES-reported moves (reported below as absolute risk, risk
# difference, and risk ratio) is NOT interpreted causally.
#
# NO REPEATED-OBSERVATION ADJUSTMENT IS NEEDED HERE: this analysis is
# inherently one row per NPI (one 2023->2024 transition each), not a panel
# of repeated measures -- there is nothing to cluster on.
#
# Input : midwife_panel.csv, artifacts/amcb_npi_linkage_FROZEN.csv,
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Output: artifacts/medicaid_2023_2024_transition_support_by_category.csv
#         artifacts/medicaid_2023_2024_transition_support_risk_comparison.csv
#
# @family diagnostics
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(DBI); library(duckdb); library(tibble); library(readr)
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

WINDOW_START <- as.Date("2023-01-01")
WINDOW_END <- as.Date("2024-12-31")

# ---- canonical cohort -------------------------------------------------------
base::message("== Cohort ==")
linkage <- readr::read_csv(FROZEN, col_types = readr::cols(.default = "c"), progress = FALSE)
canon <- canonical_active_primary(as.data.frame(linkage, stringsAsFactors = FALSE))
cohort_npi <- tibble::tibble(npi = unique(canon$npi)) |>
  dplyr::filter(is_valid_individual_npi(.data$npi))
base::message(sprintf("Canonical, NPI-valid cohort: %d NPIs.", nrow(cohort_npi)))

# ---- NPPES 2023 and 2024 practice state, deduped --------------------------
panel_raw <- readr::read_csv(PANEL, col_types = readr::cols(.default = "c"), progress = FALSE) |>
  dplyr::semi_join(cohort_npi, by = "npi") |>
  dplyr::filter(.data$snapshot_year %in% c("2023", "2024"),
               !is.na(.data$practice_state), nzchar(.data$practice_state))
nppes_2324 <- panel_raw |>
  dplyr::mutate(snapshot_date = normalize_snapshot_date(.data$snapshot_date)) |>
  dplyr::group_by(.data$npi, .data$snapshot_year) |>
  dplyr::slice_max(.data$snapshot_date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup() |>
  dplyr::transmute(npi = .data$npi, year = .data$snapshot_year, state = .data$practice_state) |>
  tidyr::pivot_wider(names_from = "year", values_from = "state", names_prefix = "state_")

n_missing_either_year <- sum(is.na(nppes_2324$state_2023) | is.na(nppes_2324$state_2024))
base::message(sprintf("%d cohort NPIs have an NPPES state in both 2023 and 2024 (%d excluded: missing one or both years).",
                      sum(!is.na(nppes_2324$state_2023) & !is.na(nppes_2324$state_2024)), n_missing_either_year))

nppes_2324 <- nppes_2324 |> dplyr::filter(!is.na(.data$state_2023), !is.na(.data$state_2024)) |>
  dplyr::mutate(group = dplyr::if_else(.data$state_2023 == .data$state_2024, "stayer", "mover"))
base::message(sprintf("Movers: %d. Stayers: %d.",
                      sum(nppes_2324$group == "mover"), sum(nppes_2324$group == "stayer")))

# ---- qualifying Medicaid segments, merged into intervals -------------------
base::message("\n== Medicaid warehouse ==")
con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con, sprintf("ATTACH %s AS medicaid (READ_ONLY)",
                            DBI::dbQuoteString(con, MEDICAID_DB)))
warehouse <- dplyr::tbl(con, "medicaid.enrollment_segments")
raw_segments <- warehouse |>
  dplyr::semi_join(nppes_2324 |> dplyr::select("npi"), by = c("NPI" = "npi"), copy = TRUE) |>
  dplyr::select("NPI", "STATE_CD", "ENRL_START_DT", "ENRL_END_DT",
               "ENRL_STATUS_CD", "PRVDR_TYPE") |>
  dplyr::filter(PRVDR_TYPE == "03") |>
  dplyr::collect()

dates <- normalize_enrollment_dates(raw_segments$ENRL_START_DT, raw_segments$ENRL_END_DT)
qualifying <- raw_segments |>
  dplyr::mutate(start = dates$start, end = dates$end, date_issue = dates$date_issue) |>
  dplyr::filter(is_qualifying_enrollment_status(.data$ENRL_STATUS_CD),
               is_valid_medicaid_state(.data$STATE_CD), is.na(.data$date_issue)) |>
  dplyr::transmute(npi = .data$NPI, state = .data$STATE_CD, start = .data$start, end = .data$end)
base::message(sprintf("%s qualifying segment rows for movers/stayers.", format(nrow(qualifying), big.mark = ",")))

merged_intervals <- merge_enrollment_intervals(qualifying)
base::message(sprintf("Merged into %s (npi, state) intervals.", format(nrow(merged_intervals), big.mark = ",")))

# ---- evidence summary + classification, per NPI ---------------------------
evidence_for <- function(npi, state) {
  ivals <- merged_intervals[merged_intervals$npi == npi, , drop = FALSE]
  summarize_state_window_evidence(ivals, state, WINDOW_START, WINDOW_END)
}

base::message("\nClassifying each mover's and stayer's transition-support evidence...")
nppes_2324 <- nppes_2324 |>
  dplyr::rowwise() |>
  dplyr::mutate(
    origin_state = .data$state_2023,
    destination_state = dplyr::if_else(.data$group == "mover", .data$state_2024, .data$state_2023),
    .evidence_dest = list(evidence_for(.data$npi, .data$destination_state)),
    .evidence_orig = list(evidence_for(.data$npi, .data$origin_state))
  ) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    destination_preexisting = vapply(.data$.evidence_dest, `[[`, logical(1), "preexisting"),
    destination_starts_in_window = vapply(.data$.evidence_dest, `[[`, logical(1), "starts_in_window"),
    destination_any_in_window = vapply(.data$.evidence_dest, `[[`, logical(1), "any_in_window"),
    origin_ends_in_window = vapply(.data$.evidence_orig, `[[`, logical(1), "ends_in_window"),
    origin_persists_in_window = vapply(.data$.evidence_orig, `[[`, logical(1), "persists_at_window_end"),
    origin_any_in_window = vapply(.data$.evidence_orig, `[[`, logical(1), "any_in_window")
  ) |>
  dplyr::select(-".evidence_dest", -".evidence_orig")

# For STAYERS, "destination" is a stand-in (their one constant state) --
# classify_transition_support() would always see destination_preexisting=TRUE
# for a true stayer (their state never changed, so it necessarily predates
# the window), which correctly reports "Preexisting destination enrollment"
# for them, not a spurious "Strong"/"Partial" support signal.
nppes_2324$transition_support <- classify_transition_support(
  destination_preexisting = nppes_2324$destination_preexisting,
  destination_starts_in_window = nppes_2324$destination_starts_in_window,
  origin_ends_in_window = nppes_2324$origin_ends_in_window,
  origin_persists_in_window = nppes_2324$origin_persists_in_window,
  destination_any_in_window = nppes_2324$destination_any_in_window,
  origin_any_in_window = nppes_2324$origin_any_in_window)

base::message("\n== Transition-support category, movers vs. stayers ==")
by_category <- nppes_2324 |> dplyr::count(.data$group, .data$transition_support, name = "n")
print(by_category, n = Inf)

# ---- enrichment: a NEW non-origin-state enrollment starting in-window -----
# (Strong or Partial support both require this; Preexisting/Contradictory/
# No-info/Indeterminate do not.) This is the SAME binary signal for movers
# and stayers, which is what makes the comparison meaningful: for a stayer,
# a "yes" here is, by construction, enrollment activity in some OTHER state
# than their one constant NPPES state -- genuine background churn, not
# support for a move that (per NPPES) never happened.
nppes_2324 <- nppes_2324 |>
  dplyr::mutate(transition_signal = .data$transition_support %in%
                  c("Strong administrative support", "Partial administrative support"))

risk <- nppes_2324 |> dplyr::group_by(.data$group) |>
  dplyr::summarise(n = dplyr::n(), n_signal = sum(.data$transition_signal),
                   risk = .data$n_signal / .data$n, .groups = "drop")
p1 <- risk$risk[risk$group == "mover"]; n1 <- risk$n[risk$group == "mover"]
p2 <- risk$risk[risk$group == "stayer"]; n2 <- risk$n[risk$group == "stayer"]

rd <- p1 - p2
se_rd <- sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
rd_ci <- rd + c(-1.96, 1.96) * se_rd

rr <- p1 / p2
se_log_rr <- sqrt((1 - p1) / (p1 * n1) + (1 - p2) / (p2 * n2))
rr_ci <- exp(log(rr) + c(-1.96, 1.96) * se_log_rr)

base::message(sprintf(
  "\nTransition-signal risk: movers %.1f%% (n=%d) vs. stayers %.1f%% (n=%d).",
  100 * p1, n1, 100 * p2, n2))
base::message(sprintf("Risk difference: %.1f pp (95%% CI %.1f to %.1f).",
                      100 * rd, 100 * rd_ci[1], 100 * rd_ci[2]))
base::message(sprintf("Risk ratio: %.2f (95%% CI %.2f to %.2f).", rr, rr_ci[1], rr_ci[2]))
base::message("Association, not causation: an NPPES-reported move and a Medicaid",
             " enrollment-transition signal can share an unobserved common cause",
             " (e.g. a life event prompting both) without one causing the other.")

risk_comparison <- tibble::tibble(
  group = c("mover", "stayer"), n = c(n1, n2), n_signal = c(risk$n_signal[risk$group=="mover"],
                                                            risk$n_signal[risk$group=="stayer"]),
  risk = c(p1, p2), risk_difference = c(rd, NA), rd_ci_low = c(rd_ci[1], NA),
  rd_ci_high = c(rd_ci[2], NA), risk_ratio = c(rr, NA), rr_ci_low = c(rr_ci[1], NA),
  rr_ci_high = c(rr_ci[2], NA))

out1 <- "artifacts/medicaid_2023_2024_transition_support_by_category.csv"
write_with_provenance(by_category, out1, inputs = c(PANEL, FROZEN, MEDICAID_DB))
out2 <- "artifacts/medicaid_2023_2024_transition_support_risk_comparison.csv"
write_with_provenance(risk_comparison, out2, inputs = c(PANEL, FROZEN, MEDICAID_DB))
base::message(sprintf("\nwrote %s, %s", out1, out2))
