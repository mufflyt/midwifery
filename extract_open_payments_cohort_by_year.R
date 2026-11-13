#!/usr/bin/env Rscript
# =============================================================================
# Open Payments cohort presence, by program year (spec Workstream B)
# =============================================================================
# Open Payments has sat in the longitudinal tier of the cross-source
# comparison with exactly ONE year of cohort data (2024), producing zero
# year-to-year transitions and four skipped lead/lag pairings. The raw
# releases for 2013-2023 and 2025 have been on the volume the whole time.
#
# THE SCHEMA DRIFTS, AND THE DRIFT IS THE WHOLE DIFFICULTY:
#
#   2013-2014  NO NPI COLUMN. CMS did not publish one. They DO carry
#              Physician_Profile_ID, the same identifier later years carry as
#              Covered_Recipient_Profile_ID beside an NPI, so the link is
#              recoverable through build_open_payments_profile_npi_lookup.R
#              (1,567,335 profiles, learned from 2021-2025, 8 ambiguous
#              profiles excluded). Backfilled rows are RETROSPECTIVE: an NPI
#              seen on a profile in 2022 and applied to its 2013 row assumes
#              the profile's NPI did not change in nine years. Labelled, and
#              never pooled with observed rows without the label.
#   2015       Physician_NPI
#   2016-2025  Covered_Recipient_NPI
#   2024       no raw directory on this volume; read from op_2024 inside
#              open_payments_merged_2013_2024.duckdb
#
# ELIGIBILITY IS NOT PRESENCE, AND THE DIFFERENCE MATTERS MORE HERE THAN
# ANYWHERE ELSE IN THIS PROJECT. Certified nurse-midwives did not become
# covered recipients until PROGRAM YEAR 2021, when the SUPPORT Act expansion
# took effect. Before that a midwife could receive industry payments all year
# and correctly appear nowhere in this file. Absence in 2015-2020 is
# therefore evidence about the REPORTING RULE, not about the midwife, and
# every output here carries cnm_reportable so no consumer can lose that.
#
# Reading a pre-2021 zero as "no industry relationship" would be the same
# error as reading a Medicare billing gap as workforce exit.
#
# THE YEAR IS VALIDATED AGAINST THE DATA, NOT THE FILENAME. Every release
# carries Program_Year, so the distinct values are read in the same scan that
# extracts the cohort and passed to assert_year_set(). A file whose contents
# disagree with the year its name claims is refused, not relabelled. This is
# the first producer to use the Workstream D validator.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          <volume>/open_payments_data/<year>/unzipped_files/OP_DTL_GNRL_*.csv
#          <volume>/open_payments_data/open_payments_merged_2013_2024.duckdb
# A STATE, NOT JUST A PRESENCE. Recipient_State is published in every
# program year (column 14 in 2013, 15 from 2015), so the same scan that
# counts payment rows can also say where the recipient was. One state per
# NPI-year by the modal rule this project uses everywhere -- most payment
# rows wins, ties alphabetical, so a rerun is byte-identical -- with
# n_states_this_year written alongside so multiplicity stays a column.
#
# THE USABLE LONGITUDINAL WINDOW IS 2021-2025, NOT 2013-2025. Before the
# SUPPORT Act expansion this cohort has 4-21 midwives a year. Feeding those
# years into churn or lead/lag would manufacture transitions out of a handful
# of people who happened to be reportable under some other recipient
# category. The full series is written; the consumer is told which part of it
# can carry a trend.
#
# Outputs: artifacts/open_payments_midwife_presence_by_year.csv
#          artifacts/open_payments_source_coverage_by_year.csv
#          artifacts/open_payments_year_validation.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "open_payments_schema.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "source_year.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
LOOKUP <- "artifacts/open_payments_profile_npi_lookup.csv"
OP_REL <- "open_payments_data"
MERGED <- file.path(OP_REL, "open_payments_merged_2013_2024.duckdb")
# The program year the SUPPORT Act expansion made CNMs covered recipients.
CNM_REPORTABLE_FROM <- 2021L
YEARS <- c(2013:2023, 2025L)

#' Which column holds the NPI in a given program year's release
#'
#' Returned rather than guessed per file: CMS renamed the field once, and a
#' producer that probes the header silently accepts a year where the field is
#' missing entirely.
#'
#' @param year [integer] program year.
#' @return [character] column name, or NA when the release has no NPI column.

#' Locate one program year's payment detail file
#'
#' @param year [integer] program year.
#' @return [character] path, or NA when no raw release is on the volume.
op_raw_path <- function(year) {
  d <- samsung_volume_path(file.path(OP_REL, as.character(year),
                                     "unzipped_files"), must_exist = FALSE)
  if (is.na(d) || !dir.exists(d)) return(NA_character_)
  hits <- list.files(d, pattern = "^OP_DTL_GNRL_.*\\.csv$", full.names = TRUE)
  if (!length(hits)) return(NA_character_)
  hits[1]
}

#' Cohort presence for a year with no NPI column, via the profile lookup
#'
#' Joins the release's profile IDs to the learned profile -> NPI map and then
#' to the cohort. The result is a retrospective attribution and is labelled
#' as one.
#'
#' @param con [DBIConnection] DuckDB with `cohort_npi` and `profile_npi`.
#' @param src [character] quoted table or read_csv() expression.
#' @param year [integer] program year.
#' @return [data.frame] npi, program_year, n_payment_rows; NULL when nothing
#'   links, which for a year in which CNMs were not reportable is the
#'   expected and informative answer.
op_year_rows_via_profile <- function(con, src, year) {
  pc <- op_profile_column(year)
  r <- DBI::dbGetQuery(con, sprintf("
    WITH hit AS (
      SELECT l.npi AS npi,
             upper(trim(CAST(t.Recipient_State AS VARCHAR))) AS state
        FROM %2$s t
        JOIN profile_npi l ON trim(CAST(t.%1$s AS VARCHAR)) = l.profile_id
        JOIN cohort_npi c ON c.npi = l.npi
       WHERE t.%1$s IS NOT NULL
         AND length(trim(CAST(t.%1$s AS VARCHAR))) > 0
    ), tally AS (
      SELECT npi, state, COUNT(*) AS n FROM hit GROUP BY 1, 2
    )
    SELECT npi, state, n AS n_payment_rows,
           (SELECT SUM(t2.n) FROM tally t2 WHERE t2.npi = tally.npi)
             AS n_payment_rows_all_states,
           (SELECT COUNT(DISTINCT t3.state) FROM tally t3
             WHERE t3.npi = tally.npi AND t3.state IS NOT NULL)
             AS n_states_this_year
      FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY npi
                                ORDER BY n DESC, state ASC) = 1",
    DBI::dbQuoteIdentifier(con, pc), src))
  if (!nrow(r)) return(NULL)
  r$state <- clean_state(r$state)
  r$program_year <- as.integer(year)
  r
}

#' The profile-ID column name for a program year
#'
#' @param year [integer] program year.
#' @return [character] column name; CMS renamed it with the 2016 release.

#' Cohort presence and payment counts for one program year
#'
#' Reads only the NPI and Program_Year columns. The releases are 2-9 GB each
#' and the rest of the 90-odd columns are never needed here.
#'
#' @param con [DBIConnection] DuckDB with `cohort_npi` present.
#' @param src [character] a quoted table name or a read_csv() expression.
#' @param npi_col [character] which column holds the NPI.
#' @param year [integer] the program year the caller believes this is.
#' @return [list] `rows` (npi, program_year, n_payment_rows) and `validation`
#'   (one row recording how the year was checked and what was found).
op_year_rows <- function(con, src, npi_col, year) {
  obs <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT TRY_CAST(t.Program_Year AS INTEGER) AS y FROM %s t
      WHERE t.Program_Year IS NOT NULL", src))$y
  v <- assert_year_set(obs, year, strict = FALSE,
                       label = sprintf("Open Payments %d", year))
  if (identical(v$status, "refuted")) return(list(rows = NULL, validation = v))
  r <- DBI::dbGetQuery(con, sprintf("
    WITH hit AS (
      SELECT trim(CAST(t.%1$s AS VARCHAR)) AS npi,
             upper(trim(CAST(t.Recipient_State AS VARCHAR))) AS state
        FROM %2$s t JOIN cohort_npi c
          ON trim(CAST(t.%1$s AS VARCHAR)) = c.npi
       WHERE t.%1$s IS NOT NULL
    ), tally AS (
      SELECT npi, state, COUNT(*) AS n FROM hit GROUP BY 1, 2
    )
    SELECT npi, state, n AS n_payment_rows,
           (SELECT SUM(t2.n) FROM tally t2 WHERE t2.npi = tally.npi)
             AS n_payment_rows_all_states,
           (SELECT COUNT(DISTINCT t3.state) FROM tally t3
             WHERE t3.npi = tally.npi AND t3.state IS NOT NULL)
             AS n_states_this_year
      FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY npi
                                ORDER BY n DESC, state ASC) = 1",
    DBI::dbQuoteIdentifier(con, npi_col), src))
  if (nrow(r)) {
    r$state <- clean_state(r$state)
    r$program_year <- as.integer(year)
  }
  list(rows = r, validation = v)
}

if (sys.nframe() == 0L) {
  cohort <- readr::read_csv(COHORT, col_types = readr::cols(.default = "c"),
                            progress = FALSE) %>%
    filter(cohort_member == "TRUE") %>%
    transmute(npi = trimws(npi)) %>%
    filter(!is.na(npi), nzchar(npi)) %>% distinct()
  base::message(sprintf("cohort NPIs: %s", format(nrow(cohort), big.mark = ",")))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("SET temp_directory=%s",
                              DBI::dbQuoteString(con, tempdir())))
  DBI::dbWriteTable(con, "cohort_npi", as.data.frame(cohort), overwrite = TRUE)
  have_lookup <- file.exists(LOOKUP)
  if (have_lookup) {
    lk <- readr::read_csv(LOOKUP, col_types = readr::cols(.default = "c"),
                          progress = FALSE)[, c("profile_id", "npi")]
    DBI::dbWriteTable(con, "profile_npi", as.data.frame(lk), overwrite = TRUE)
    base::message(sprintf("profile lookup: %s profiles",
                          format(nrow(lk), big.mark = ",")))
  } else {
    base::message("profile lookup absent; 2013-2014 will stay unlinkable")
  }
  merged <- samsung_volume_path(MERGED, must_exist = FALSE)
  if (!is.na(merged))
    DBI::dbExecute(con, sprintf("ATTACH %s AS m (READ_ONLY)",
                                DBI::dbQuoteString(con, merged)))

  rows <- list(); vals <- list()
  for (y in sort(c(YEARS, 2024L))) {
    npi_col <- op_npi_column(y)
    via_profile <- is.na(npi_col)
    if (via_profile && !have_lookup) {
      base::message(sprintf("  %d  no NPI column and no profile lookup -- unlinkable", y))
      vals[[length(vals) + 1L]] <- tibble(
        program_year = y, status = "unlinkable", confidence = "none",
        observed_years = NA_character_,
        detail = "no NPI field, and artifacts/open_payments_profile_npi_lookup.csv is absent")
      next
    }
    src <- if (identical(y, 2024L)) {
      if (is.na(merged)) NA_character_ else "m.op_2024"
    } else {
      p <- op_raw_path(y)
      if (is.na(p)) NA_character_
      else sprintf("read_csv(%s, all_varchar = true, ignore_errors = true)",
                   DBI::dbQuoteString(con, p))
    }
    if (is.na(src)) {
      base::message(sprintf("  %d  release not on this volume", y))
      vals[[length(vals) + 1L]] <- tibble(
        program_year = y, status = "absent", confidence = "none",
        observed_years = NA_character_, detail = "no release found")
      next
    }
    got <- tryCatch(
      if (via_profile) {
        r <- op_year_rows_via_profile(con, src, y)
        list(rows = r, validation = list(
          status = "retrospective_profile_link", confidence = "medium",
          observed_years = y,
          detail = "no NPI field; linked through the 2021-2025 profile lookup"))
      } else op_year_rows(con, src, npi_col, y),
                    error = function(e) list(rows = NULL,
                      validation = list(status = "error", confidence = "none",
                        observed_years = NA_integer_,
                        detail = conditionMessage(e))))
    v <- got$validation
    vals[[length(vals) + 1L]] <- tibble(
      program_year = y, status = v$status, confidence = v$confidence,
      observed_years = paste(v$observed_years, collapse = ";"),
      detail = v$detail)
    if (is.null(got$rows) || !nrow(got$rows)) {
      base::message(sprintf("  %d  %-12s 0 cohort NPIs", y, v$status))
      next
    }
    rows[[length(rows) + 1L]] <- got$rows
    base::message(sprintf("  %d  %-12s %6s cohort NPIs, %s payment rows",
                          y, v$status,
                          format(nrow(got$rows), big.mark = ","),
                          # all states, not just the modal one -- otherwise
                          # the log looks like rows were lost when the state
                          # breakdown was added.
                          format(sum(got$rows$n_payment_rows_all_states),
                                 big.mark = ",")))
  }
  stopifnot(length(rows) > 0)
  pres <- bind_rows(rows) %>%
    mutate(cnm_reportable = program_year >= CNM_REPORTABLE_FROM,
           # 2013-2014 have no NPI of their own; their link is inferred from a
           # profile's NPI as recorded years later.
           evidence_type = if_else(program_year <= 2014L,
                                   "retrospective", "observed"),
           activity_type = "payment",
           # 4-21 midwives a year is not a trend. The flag says which rows a
           # longitudinal consumer may use, rather than leaving that to be
           # rediscovered from the counts.
           usable_for_trend = program_year >= CNM_REPORTABLE_FROM) %>%
    arrange(program_year, npi)

  cov <- pres %>%
    count(program_year, cnm_reportable, evidence_type, name = "n_midwives") %>%
    mutate(pct_of_cohort = round(100 * n_midwives / nrow(cohort), 2))
  # Years with no usable link are rows in the coverage table, not gaps in it:
  # "we could not look" must be distinguishable from "we looked and found
  # nobody".
  validation <- bind_rows(vals)
  # A placeholder row belongs to a year that produced NOTHING, not to a year
  # whose status merely differs. 2013-2014 link retrospectively through the
  # profile lookup and DO produce rows; keying on status rather than on
  # output gave them both a count and an NA, which reads as two populations.
  missing <- validation %>%
    filter(!program_year %in% unique(pres$program_year)) %>%
    transmute(program_year, cnm_reportable = program_year >= CNM_REPORTABLE_FROM,
              evidence_type = "unlinkable",
              n_midwives = NA_integer_, pct_of_cohort = NA_real_)
  cov <- bind_rows(cov, missing) %>% arrange(program_year)

  write_with_provenance(pres,
    "artifacts/open_payments_midwife_presence_by_year.csv",
    inputs = COHORT, na = "")
  write_with_provenance(cov,
    "artifacts/open_payments_source_coverage_by_year.csv",
    inputs = COHORT, na = "")
  write_with_provenance(validation,
    "artifacts/open_payments_year_validation.csv", inputs = COHORT, na = "")

  base::message(sprintf("\n%s NPI-years, %s midwives, %d-%d",
                        format(nrow(pres), big.mark = ","),
                        format(dplyr::n_distinct(pres$npi), big.mark = ","),
                        min(pres$program_year), max(pres$program_year)))
  print(as.data.frame(cov), row.names = FALSE)
}
