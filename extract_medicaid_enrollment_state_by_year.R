#!/usr/bin/env Rscript
# =============================================================================
# Medicaid enrolment state per cohort midwife, per YEAR (spec A2)
# =============================================================================
# THE DISTORTION THIS CORRECTS. The DOGE T-MSIS enrolment file carries
# ENRL_START_DT and ENRL_END_DT -- real date ranges -- and
# compare_all_sources_mysteryroster.R was reducing the whole file to ONE modal
# state per NPI and placing it in the SNAPSHOT tier. A career-long modal state
# was then compared against each year's contemporaneous value from every other
# source. The resulting disagreement was reported as a property of Medicaid.
#
# Measured before the fix: the whole-file modal state differs from the
# year-specific state 14.4% of the time overall, and the error is largest
# exactly where drift is largest -- 30.5% in 2013, 20.0% in 2017, 7.6% in
# 2022, 5.7% in 2024. medicaid_enrollment's odd-one-out rate of 0.166 was
# five times the next worst source, and 77.5% fusion agreement was the lowest
# of fourteen. Both were substantially artifacts of the reduction.
#
# WHAT A YEAR MEANS HERE. A segment covers year Y when it overlaps any part of
# it: start <= 31 Dec Y and coalesce(end, '9999-12-31') >= 1 Jan Y. An open
# segment (NULL end, 18,849,576 rows nationally) is treated as still running,
# which is what an open enrolment means.
#
# EVIDENCE CLASS B, NOT A. This is retrospectively reported history: one file,
# published 2026-07-24, describing periods reaching back years. It is not
# twelve independently dated observations and must never be counted as such.
# The series carries evidence_type = "retrospective" on every row so a
# consumer cannot lose that by joining.
#
# LEFT CENSORING, PRECISELY. min(ENRL_END_DT) across the whole file is
# 2018-01-01: no segment that CLOSED before 2018 appears at all. The
# consequence is specific and worth stating exactly, because it is narrower
# than "the early years are wrong":
#
#   The STATES in 2013-2017 are as sound as any other year -- a midwife whose
#   segment ran 2015-2019 really was enrolled in that state in 2015.
#   The COVERAGE in 2013-2017 is biased -- it shows only midwives still
#   enrolled in 2018, so counts rise through 2018 partly because the file
#   starts seeing closures, not because enrolment grew.
#
# So agreement rates conditional on being observed are usable for every year;
# coverage TRENDS before 2018 are not. left_censored marks those years.
#
# DIRTY START DATES ARE KEPT, NOT CLEANED. 1,955,673 rows nationally carry
# 1900-01-01, and a handful carry 0001-01-01 or 1753. They are implausible as
# enrolment dates but they do not change which years a segment overlaps for
# any year in range -- a segment starting in 1900 and ending in 2020 covers
# 2013-2020 under any reading. Rewriting them would be inventing data to fix
# a problem that does not affect the output.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          <volume>/doge_opendata/medicaid_provider_enrollment_segments_2026_07_24/
#            medicaid-provider-enrollment-segments.parquet
# Outputs: artifacts/medicaid_enrollment_cohort_state_by_year.csv
#          artifacts/medicaid_enrollment_cohort_state_footprint.csv (person-level)
#          artifacts/medicaid_enrollment_coverage_by_year.csv (aggregate)
#          artifacts/medicaid_enrollment_modal_vs_yearly.csv (the before/after)
# See    : docs/source-series-reconstruction.md §2.2, §3.4
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
SEGMENTS_REL <- file.path("doge_opendata",
                          "medicaid_provider_enrollment_segments_2026_07_24",
                          "medicaid-provider-enrollment-segments.parquet")
# The window the comparison uses. 2013 is its left edge; the file's own
# coverage begins earlier but is unusable for the censoring reason above.
YEAR_MIN <- 2013L
YEAR_MAX <- 2024L
# No segment that closed before this date is in the file, so coverage for
# years earlier than this is survivorship rather than enrolment.
CENSORING_FLOOR <- 2018L

#' Expand enrolment segments into one state per cohort NPI-year
#'
#' @param con [DBIConnection] DuckDB with a `cohort_npi(npi)` table present.
#' @param parquet [character] path to the segments file.
#' @param year_min,year_max [integer] inclusive window to expand into.
#' @return [data.frame] npi, year, state, n_states_this_year, n_segments.
#'   One row per cohort NPI-year in which at least one segment overlapped.
#'   A year with no overlapping segment yields NO ROW -- absence of enrolment
#'   is not enrolment in an unknown state, and it is certainly not evidence
#'   that the midwife stopped practising.
expand_segments_to_years <- function(con, parquet, year_min, year_max) {
  q <- sprintf("
    WITH seg AS (
      SELECT trim(CAST(s.NPI AS VARCHAR)) AS npi,
             upper(trim(CAST(s.STATE_CD AS VARCHAR))) AS state,
             s.ENRL_START_DT AS d0, s.ENRL_END_DT AS d1
        FROM read_parquet(%1$s) s
        JOIN cohort_npi c ON trim(CAST(s.NPI AS VARCHAR)) = c.npi
       WHERE s.STATE_CD IS NOT NULL
         AND length(trim(CAST(s.STATE_CD AS VARCHAR))) > 0
    ), ex AS (
      SELECT g.y AS year, seg.npi, seg.state
        FROM seg, generate_series(%2$d, %3$d) g(y)
       WHERE seg.d0 <= make_date(g.y, 12, 31)
         AND coalesce(seg.d1, DATE '9999-12-31') >= make_date(g.y, 1, 1)
    ), tally AS (
      SELECT year, npi, state, COUNT(*) AS n FROM ex GROUP BY 1, 2, 3
    )
    SELECT npi, year, state, n AS n_segments,
           (SELECT COUNT(DISTINCT t2.state) FROM tally t2
             WHERE t2.npi = tally.npi AND t2.year = tally.year)
             AS n_states_this_year
      FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY year, npi
                                ORDER BY n DESC, state ASC) = 1",
    DBI::dbQuoteString(con, parquet), year_min, year_max)
  DBI::dbGetQuery(con, q)
}

#' Every state a cohort midwife was enrolled in, per year
#'
#' THE MODAL ROW IS NOT THE WHOLE TRUTH. expand_segments_to_years() computes
#' every (year, npi, state) and then keeps one per NPI-year. Measured
#' 2026-11-10 that discards 59,380 of 178,907 state memberships -- 33.2% --
#' and nothing downstream could see them, so any comparison against this
#' source tested equality with one pick rather than membership of a set. A
#' midwife enrolled in CO, NM and AZ was recorded as CO and counted as
#' disagreeing with a source that said AZ.
#'
#' This emits the set. It is a SEPARATE artifact, not a replacement: the
#' single-valued series is still what a single-valued comparator needs, and
#' silently widening it would change every existing statistic without
#' anyone asking.
#'
#' @inheritParams expand_segments_to_years
#' @return [data.frame] npi, year, state, n_segments -- one row per distinct
#'   state a midwife was enrolled in during that year.
expand_segments_to_footprint <- function(con, parquet, year_min, year_max) {
  q <- sprintf("
    WITH seg AS (
      SELECT trim(CAST(s.NPI AS VARCHAR)) AS npi,
             upper(trim(CAST(s.STATE_CD AS VARCHAR))) AS state,
             s.ENRL_START_DT AS d0, s.ENRL_END_DT AS d1
        FROM read_parquet(%1$s) s
        JOIN cohort_npi c ON trim(CAST(s.NPI AS VARCHAR)) = c.npi
       WHERE s.STATE_CD IS NOT NULL
         AND length(trim(CAST(s.STATE_CD AS VARCHAR))) > 0
    ), ex AS (
      SELECT g.y AS year, seg.npi, seg.state
        FROM seg, generate_series(%2$d, %3$d) g(y)
       WHERE seg.d0 <= make_date(g.y, 12, 31)
         AND coalesce(seg.d1, DATE '9999-12-31') >= make_date(g.y, 1, 1)
    )
    SELECT npi, year, state, COUNT(*) AS n_segments
      FROM ex GROUP BY 1, 2, 3",
    DBI::dbQuoteString(con, parquet), year_min, year_max)
  DBI::dbGetQuery(con, q)
}

#' The whole-file modal state, i.e. what the pipeline used to produce
#'
#' Kept so the correction can be quantified rather than asserted. This is the
#' reduction A2 replaces, reproduced exactly: one state per NPI across every
#' segment in the file, ties alphabetical, no year anywhere.
#'
#' @inheritParams expand_segments_to_years
#' @return [data.frame] npi, modal_state.
whole_file_modal_state <- function(con, parquet) {
  q <- sprintf("
    WITH seg AS (
      SELECT trim(CAST(s.NPI AS VARCHAR)) AS npi,
             upper(trim(CAST(s.STATE_CD AS VARCHAR))) AS state
        FROM read_parquet(%1$s) s
        JOIN cohort_npi c ON trim(CAST(s.NPI AS VARCHAR)) = c.npi
       WHERE s.STATE_CD IS NOT NULL
         AND length(trim(CAST(s.STATE_CD AS VARCHAR))) > 0
    ), tally AS (
      SELECT npi, state, COUNT(*) AS n FROM seg GROUP BY 1, 2
    )
    SELECT npi, state AS modal_state FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY npi
                                ORDER BY n DESC, state ASC) = 1",
    DBI::dbQuoteString(con, parquet))
  DBI::dbGetQuery(con, q)
}

if (sys.nframe() == 0L) {
  cohort <- readr::read_csv(COHORT, col_types = readr::cols(.default = "c"),
                            progress = FALSE) %>%
    filter(cohort_member == "TRUE") %>%
    transmute(npi = trimws(npi)) %>%
    filter(!is.na(npi), nzchar(npi)) %>% distinct()
  base::message(sprintf("cohort NPIs: %s", format(nrow(cohort), big.mark = ",")))

  parquet <- samsung_volume_path(SEGMENTS_REL, must_exist = FALSE)
  if (is.na(parquet))
    stop("segments parquet not found under the mounted volume", call. = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("SET temp_directory=%s",
                              DBI::dbQuoteString(con, tempdir())))
  DBI::dbWriteTable(con, "cohort_npi", as.data.frame(cohort), overwrite = TRUE)

  base::message("expanding segments by date-range overlap ...")
  panel <- expand_segments_to_years(con, parquet, YEAR_MIN, YEAR_MAX)
  panel$state <- clean_state(panel$state)
  panel <- panel[!is.na(panel$state), , drop = FALSE]
  stopifnot(nrow(panel) > 0)
  panel <- panel %>%
    mutate(evidence_type = "retrospective",
           left_censored = year < CENSORING_FLOOR) %>%
    arrange(npi, year)

  base::message("expanding the full multi-state footprint ...")
  fp <- expand_segments_to_footprint(con, parquet, YEAR_MIN, YEAR_MAX)
  fp$state <- clean_state(fp$state)
  fp <- fp[!is.na(fp$state), , drop = FALSE]
  fp$evidence_type <- "retrospective"
  fp$left_censored <- fp$year < CENSORING_FLOOR
  stopifnot(nrow(fp) >= nrow(panel))
  write_with_provenance(fp,
    "artifacts/medicaid_enrollment_cohort_state_footprint.csv",
    inputs = COHORT, na = "")
  base::message(sprintf("  footprint: %s rows vs %s modal rows (%.1f%% of memberships were being discarded)",
                        format(nrow(fp), big.mark = ","),
                        format(nrow(panel), big.mark = ","),
                        100 * (nrow(fp) - nrow(panel)) / nrow(fp)))

  base::message("reproducing the whole-file modal reduction it replaces ...")
  modal <- whole_file_modal_state(con, parquet)
  modal$modal_state <- clean_state(modal$modal_state)

  cmp <- panel %>%
    inner_join(modal, by = "npi") %>%
    group_by(year) %>%
    summarise(n_npi_years = n(),
              n_differs = sum(state != modal_state, na.rm = TRUE),
              pct_differs = round(100 * mean(state != modal_state, na.rm = TRUE), 1),
              pct_multi_state = round(100 * mean(n_states_this_year > 1), 1),
              .groups = "drop") %>%
    mutate(left_censored = year < CENSORING_FLOOR)

  cov <- panel %>% count(year, name = "n_midwives") %>%
    mutate(pct_of_cohort = round(100 * n_midwives / nrow(cohort), 1),
           left_censored = year < CENSORING_FLOOR)

  write_with_provenance(panel,
    "artifacts/medicaid_enrollment_cohort_state_by_year.csv",
    inputs = COHORT, na = "")
  write_with_provenance(cov,
    "artifacts/medicaid_enrollment_coverage_by_year.csv",
    inputs = COHORT, na = "")
  write_with_provenance(cmp,
    "artifacts/medicaid_enrollment_modal_vs_yearly.csv",
    inputs = COHORT, na = "")

  base::message(sprintf("\n%s NPI-years, %s midwives, %d-%d",
                        format(nrow(panel), big.mark = ","),
                        format(dplyr::n_distinct(panel$npi), big.mark = ","),
                        min(panel$year), max(panel$year)))
  base::message(sprintf("whole-file modal disagrees with the year-specific state on %.1f%% of NPI-years",
                        100 * mean(panel$state !=
                                   modal$modal_state[match(panel$npi, modal$npi)],
                                   na.rm = TRUE)))
  print(as.data.frame(cmp), row.names = FALSE)
}
