#!/usr/bin/env Rscript
# =============================================================================
# Source-coverage contracts: a missing input must never publish a smaller study
# =============================================================================
# THE DEFECT THESE TESTS EXIST FOR. On 2026-11-12 the state-source audit
# published a one-year Open Payments series where five years were intended,
# because the producer discovered its input with
# Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv") and only
# the 2024 file was on that machine. The build succeeded. See
# docs/state-source-audit-coverage-defect.md.
#
# The central test is T3: delete one required year's input and the build must
# FAIL NAMING THAT YEAR, not succeed with four years.
#
# The distinction every one of these tests is built around:
#   present + readable + zero cohort records = VALID evidence of absence
#   missing, or year unestablished            = evidence of NOTHING, must fail
# A test that demanded rows in every year would forbid Delaware's genuinely
# empty Board-of-Nursing file, which is a real finding, so none of them do.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "source_coverage.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# --- a disposable five-year fixture ------------------------------------------
# Built on disk rather than mocked, because the defect was a filesystem fact:
# the contract has to be tested against real absent files.
fixture_dir <- file.path(tempdir(), "source_coverage_fixture")
unlink(fixture_dir, recursive = TRUE)
dir.create(fixture_dir, recursive = TRUE, showWarnings = FALSE)

write_fixture_year <- function(program_year, n_rows = 3L,
                               year_written = program_year) {
  fixture_path <- file.path(
    fixture_dir, sprintf("cohort_general_%d.csv", program_year))
  readr::write_csv(tibble::tibble(
    certification_number = sprintf("CNM%05d", seq_len(n_rows)),
    npi = sprintf("1%09d", seq_len(n_rows)),
    program_year = rep(year_written, n_rows),
    recipient_state = rep(c("CO", "NM", "AZ"), length.out = n_rows)),
    fixture_path)
  fixture_path
}

fixture_manifest <- function(years = 2021:2025) {
  tibble::tibble(
    source_id = "open_payments", source_name = "fixture",
    expected_year = years, required = TRUE, source_type = "annual",
    input_path = file.path(fixture_dir,
                           sprintf("cohort_general_%d.csv", years)),
    producer = "fixture", date_field = "program_year",
    state_field = "recipient_state", validation_method = "in_file_date",
    source_vintage = "fixture", artifact_sha256 = NA_character_,
    availability_status = "available", notes = "fixture")
}

build_full_fixture <- function() {
  unlink(list.files(fixture_dir, full.names = TRUE))
  for (program_year in 2021:2025) write_fixture_year(program_year)
}

publication_fails <- function(manifest_rows) {
  verdict <- tryCatch({
    suppressMessages(validate_source_coverage(manifest_rows,
                                              publication_mode = TRUE))
    list(failed = FALSE, message = "")
  }, error = function(e) list(failed = TRUE, message = conditionMessage(e)))
  verdict
}

cat("\n-- the complete declared series --\n")
{
  build_full_fixture()
  coverage_audit <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = TRUE))
  chk(nrow(coverage_audit) == 5L,
      sprintf("T1 five declared years produce five audit rows [%d]",
              nrow(coverage_audit)))
  chk(all(coverage_audit$validation_status == "ok"),
      "T1b every year validates when all five inputs are present")
  resolved <- suppressMessages(
    resolve_source_inputs(coverage_audit, "open_payments"))
  chk(identical(as.integer(resolved$program_year), 2021:2025),
      "T2 resolve_source_inputs() returns the declared window, in order")
}

cat("\n-- THE REGRESSION: one required year removed --\n")
{
  build_full_fixture()
  file.remove(file.path(fixture_dir, "cohort_general_2023.csv"))
  verdict <- publication_fails(fixture_manifest())
  chk(verdict$failed,
      "T3 a publication build FAILS when one required year is missing")
  chk(grepl("2023", verdict$message),
      "T3b the failure names the missing year")
  chk(grepl("must not publish", verdict$message),
      "T3c the failure says publication is refused")

  # The defect's actual signature: four usable years, reported as success.
  exploratory <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = FALSE))
  usable <- suppressMessages(
    resolve_source_inputs(exploratory, "open_payments"))
  chk(nrow(usable) == 4L && !(2023L %in% usable$program_year),
      sprintf("T3d exploratory mode still reports only 4 usable years [%d]",
              nrow(usable)))
}

cat("\n-- two required years removed --\n")
{
  build_full_fixture()
  file.remove(file.path(fixture_dir, c("cohort_general_2021.csv",
                                       "cohort_general_2025.csv")))
  verdict <- publication_fails(fixture_manifest())
  chk(verdict$failed && grepl("2021", verdict$message) &&
        grepl("2025", verdict$message),
      "T4 both missing years are named, not just the first")
}

cat("\n-- a renamed annual file --\n")
{
  build_full_fixture()
  file.rename(file.path(fixture_dir, "cohort_general_2022.csv"),
              file.path(fixture_dir, "cohort_general_2022_OLD.csv"))
  verdict <- publication_fails(fixture_manifest())
  chk(verdict$failed && grepl("2022", verdict$message),
      "T5 a renamed file is a missing declared year, not a silent drop")
}

cat("\n-- an incorrect internal program year --\n")
{
  build_full_fixture()
  write_fixture_year(2024L, year_written = 2019L)  # declared 2024, says 2019
  verdict <- publication_fails(fixture_manifest())
  chk(verdict$failed,
      "T6 a file whose in-file year contradicts its declared year fails")
  chk(grepl("2024", verdict$message),
      "T6b the refuted year is named")
}

cat("\n-- a corrupted CSV --\n")
{
  build_full_fixture()
  writeLines(c("certification_number,npi,program_year,recipient_state",
               "\"unterminated,1,2023,CO", "\x01\x02 binary junk"),
             file.path(fixture_dir, "cohort_general_2023.csv"))
  coverage_audit <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = FALSE))
  corrupt_row <- dplyr::filter(coverage_audit, .data$program_year == 2023L)
  chk(!identical(corrupt_row$validation_status, "ok"),
      sprintf("T7 a corrupted CSV does not validate as ok [%s]",
              corrupt_row$validation_status))
  chk(!(2023L %in% suppressMessages(
          resolve_source_inputs(coverage_audit, "open_payments"))$program_year),
      "T7b a corrupted year is not handed to the producer")
}

cat("\n-- an empty but readable CSV: VALID, and must not fail --\n")
{
  build_full_fixture()
  write_fixture_year(2022L, n_rows = 0L)
  coverage_audit <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = TRUE))
  empty_row <- dplyr::filter(coverage_audit, .data$program_year == 2022L)
  chk(identical(empty_row$validation_status, "present_zero_records"),
      sprintf("T8 a present, complete, zero-record year is its own verdict [%s]",
              empty_row$validation_status))
  chk(identical(as.integer(empty_row$source_record_count), 0L),
      "T8b its record count is a measured 0, not NA")
  resolved <- suppressMessages(
    resolve_source_inputs(coverage_audit, "open_payments"))
  chk(2022L %in% resolved$program_year,
      "T8c a genuinely empty year is still analysed -- absence is evidence")
}

cat("\n-- an absent file is NOT the same as an empty one --\n")
{
  build_full_fixture()
  file.remove(file.path(fixture_dir, "cohort_general_2022.csv"))
  coverage_audit <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = FALSE))
  absent_row <- dplyr::filter(coverage_audit, .data$program_year == 2022L)
  chk(identical(absent_row$validation_status, "missing_required_input"),
      "T9 an absent required year is missing_required_input")
  chk(is.na(absent_row$source_record_count),
      "T9b an absent file reports NA records, never 0 -- the whole defect")
}

cat("\n-- a duplicate declared year --\n")
{
  build_full_fixture()
  doubled <- dplyr::bind_rows(fixture_manifest(),
                              dplyr::filter(fixture_manifest(),
                                            .data$expected_year == 2023L))
  duplicate_path <- file.path(tempdir(), "duplicate_manifest.csv")
  readr::write_csv(doubled, duplicate_path, na = "")
  verdict <- tryCatch({
    suppressMessages(read_source_manifest(duplicate_path)); FALSE
  }, error = function(e) grepl("twice", conditionMessage(e)))
  chk(isTRUE(verdict),
      "T10 a manifest declaring the same source-year twice is refused")
}

cat("\n-- an unexpected additional year on disk --\n")
{
  build_full_fixture()
  write_fixture_year(2026L)            # present on disk, NOT declared
  coverage_audit <- suppressMessages(
    validate_source_coverage(fixture_manifest(), publication_mode = TRUE))
  resolved <- suppressMessages(
    resolve_source_inputs(coverage_audit, "open_payments"))
  chk(!(2026L %in% resolved$program_year) && nrow(resolved) == 5L,
      "T11 an undeclared file on disk does not enter the analysed window")
}

cat("\n-- the real manifest parses and declares the intended window --\n")
{
  real_manifest <- suppressMessages(read_source_manifest())
  op_required <- real_manifest %>%
    dplyr::filter(.data$source_id == "open_payments", .data$required)
  chk(identical(sort(op_required$expected_year), 2021:2025),
      sprintf("T12 config declares Open Payments 2021-2025 as required [%s]",
              paste(sort(op_required$expected_year), collapse = ",")))
  chk(all(real_manifest$validation_method[real_manifest$required] != "glob"),
      "T12b no required source resolves by wildcard discovery")
}

unlink(fixture_dir, recursive = TRUE)
cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
