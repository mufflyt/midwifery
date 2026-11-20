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

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "source_coverage.R"))


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
  # DELIBERATELY NOT PINNED TO ONE VERDICT. How readr treats an unterminated
  # quote differs by version -- that divergence is what made this fixture
  # grade "ok" in CI while passing here -- so this asserts only that the
  # verdict is one a publication build refuses. The exact "unparseable"
  # claim is made by T7e below, on a fixture whose damage is a structural
  # field-count mismatch that every vroom reports.
  chk(corrupt_row$validation_status %in%
        c("schema_invalid", "year_unverified", "year_refuted",
          "year_check_failed"),
      sprintf("T7c and the verdict is one that refuses to publish [%s]",
              corrupt_row$validation_status))

  # THE CASE THAT CAUGHT T7 OUT, AND THE ONE THAT ISOLATES THE GUARD. Above,
  # the junk also nulls the year column, so a contract that noticed nothing
  # about corruption still failed the YEAR and T7 passed -- by accident, and
  # only on a readr whose leniency nulls it. On the readr installed in CI the
  # same fixture graded "ok".
  #
  # Here one row is a field SHORT. readr reports the problem; base read.csv,
  # which is what the year check reads with, recovers program_year = 2023
  # without complaint. Every other check therefore passes: the header has
  # both declared columns, there are two records, the year verifies. Nothing
  # but a positive corruption check refuses this file, which is why removing
  # that check fails T7d as well as T7e.
  build_full_fixture()
  writeLines(c("certification_number,npi,program_year,recipient_state",
               "CNM00001,1000000001,2023,CO",
               "CNM00002,1000000002,2023"),
             file.path(fixture_dir, "cohort_general_2023.csv"))
  verdict <- publication_fails(fixture_manifest())
  chk(verdict$failed,
      "T7d a short row is refused although every other check passes")
  chk(grepl("UNPARSEABLE", verdict$message),
      "T7e and the refusal says unparseable, not a missing column")
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

cat("\n-- a source that publishes no state at all: DECLARED, not broken --\n")
{
  # Texas BON and Washington DOH carry no address field of any kind, so no
  # re-harvest can produce a state. They declare an EMPTY state_field. That
  # must NOT read as a broken schema -- but it must also never be counted as
  # state evidence, or the audit is back to inventing observations.
  build_full_fixture()
  stateless_dir <- file.path(fixture_dir, "stateless")
  dir.create(stateless_dir, showWarnings = FALSE)
  stateless_path <- file.path(stateless_dir, "no_state_source.csv")
  readr::write_csv(tibble::tibble(
    certification_number = c("CNM1", "CNM2"), npi = c("1000000001",
                                                      "1000000002"),
    program_year = c(2026L, 2026L),
    live_bon_status = c("Active", "Active")), stateless_path)

  declared_no_state <- tibble::tibble(
    source_id = "state_boards_of_nursing", source_name = "stateless fixture",
    expected_year = 2026L, required = TRUE, source_type = "snapshot",
    input_path = stateless_path, producer = "fixture",
    date_field = "program_year", state_field = "",
    validation_method = "producer_declared", source_vintage = "fixture",
    artifact_sha256 = NA_character_, availability_status = "available",
    notes = "source publishes no state field")

  coverage_audit <- suppressMessages(
    validate_source_coverage(declared_no_state, publication_mode = TRUE))
  chk(identical(coverage_audit$validation_status, "ok"),
      sprintf("T13 an empty declared state_field is valid, not schema_invalid [%s]",
              coverage_audit$validation_status))
  chk(identical(as.integer(coverage_audit$state_observed_count), 0L),
      "T13b it observes 0 states, so it can never pass as state evidence")

  # The other half: a source that DOES declare a state column and has lost it
  # is exactly the Colorado defect, and must still fail loudly.
  declared_with_state <- declared_no_state
  declared_with_state$state_field <- "live_bon_state"
  verdict <- publication_fails(declared_with_state)
  chk(verdict$failed,
      "T14 a DECLARED state column that is absent still fails publication")
  chk(grepl("live_bon_state", verdict$message),
      "T14b the failure names the missing state column")
}

cat("\n-- the re-harvested Boards of Nursing files carry their state --\n")
{
  real_manifest <- suppressMessages(read_source_manifest())
  bon_declared <- real_manifest %>%
    dplyr::filter(.data$source_id == "state_boards_of_nursing")
  chk(nrow(bon_declared) == 8L,
      sprintf("T15 eight state boards are declared [%d]", nrow(bon_declared)))
  # nzchar(NA_character_) is TRUE, and readr reads an empty manifest cell as
  # NA -- so "declares a state column" has to test both.
  observes_state <- bon_declared %>%
    dplyr::filter(!is.na(.data$state_field), nzchar(.data$state_field))
  chk(nrow(observes_state) == 6L,
      sprintf("T15b six declare an observable state column [%d]",
              nrow(observes_state)))
  if (all(file.exists(bon_declared$input_path))) {
    bon_audit <- suppressMessages(
      validate_source_coverage(bon_declared, publication_mode = TRUE))
    chk(all(bon_audit$validation_status %in% c("ok", "present_zero_records")),
        sprintf("T15c every declared board file validates [%s]",
                paste(unique(bon_audit$validation_status), collapse = ",")))
    # Measured the same way on the archived 2026-11-09 files, this sum is
    # 720: Colorado and Pennsylvania contributed 0 because their state
    # column was absent (both register schema_invalid against this same
    # manifest), and Texas and Washington contribute 0 either way because
    # their sources carry no state. The 2026-11-15 re-harvest took it to
    # 1,292. Asserted as a floor, not an equality, because these are live
    # portals and the counts move between harvests.
    states_seen <- sum(bon_audit$state_observed_count, na.rm = TRUE)
    chk(states_seen > 720L,
        sprintf("T15d state observed on %d board records, above the 720 the %s",
                states_seen, "pre-re-harvest files could supply"))
  } else {
    cat("  skip T15c/T15d -- person-level board files absent from this checkout\n")
  }
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

cat("\n-- the Open Payments producers name their cohort arm --\n")
{
  # THE SAME DEFECT, ONE FILE OVER. The audit's year window stopped coming
  # from a wildcard on 2026-11-15, but both Open Payments extractors still
  # chose their COHORT by matching amcb_npi_crosswalk_*panel*.csv and taking
  # the first of a DESCENDING sort -- the translit arm, where every other
  # published table (build_table1_midwives.R, the hospital matchers, the
  # licence enrichers) names c5guard outright. The three arms exist in order
  # to differ, so a denominator under every Open Payments percentage was
  # being chosen by alphabetical order. Comments are stripped before
  # matching, so the note explaining the old code cannot satisfy the test.
  producers <- c("extract_open_payments_2025.R",
                 "extract_open_payments_address_history.R")
  for (producer in producers) {
    code <- readLines(file.path(root, producer), warn = FALSE)
    code <- code[!grepl("^\\s*#", code)]
    chk(!any(grepl("Sys\\.glob\\(.*amcb_npi_crosswalk", code)),
        sprintf("T16 %s does not wildcard-match its cohort arm", producer))
    chk(any(grepl("cohort_artifact_path\\(", code)),
        sprintf("T16b %s resolves the cohort through cohort_artifact_path()",
                producer))
    # BOTH write artifacts/cohort_midwives_open_payments_general_2025.csv, and
    # read_open_payments_state_series() refuses an annual artifact with no
    # program_year. extract_open_payments_2025.R selected neither year column,
    # so the 2025 step the appendix documents under "Reproducing" overwrote a
    # usable artifact with one the audit reader rejects.
    chk(any(grepl("AS program_year", code)),
        sprintf("T17 %s selects CMS's own Program_Year", producer))
  }
}

cat("\n-- when the year check itself cannot run --\n")
{
  # THE DEFECT THIS PAIR EXISTS FOR, FOUND BY CI AND NOT BY THIS MACHINE.
  # validate_source_coverage() wrapped the year probe in a tryCatch that
  # mapped every error to NULL, and a NULL probe fell through every verdict
  # to "ok". So a year whose evidence could not be examined was graded
  # usable.
  #
  # It happened for real. assert_source_year() reaches parse_vintage()
  # whenever no in-file date is found, and parse_vintage() calls
  # stringr::str_match(). On a runner whose stringi could not load its ICU
  # library that call threw, and T7, S8 and S9 -- a corrupt file, a stripped
  # year column, a blanked year column, three tests written to prove exactly
  # this -- all reported that the build refused nothing.
  #
  # Reproduced here by shadowing parse_vintage() with one that throws, which
  # is what a broken stringi does to it.
  build_full_fixture()
  stripped_path <- file.path(fixture_dir, "cohort_general_2023.csv")
  stripped <- readr::read_csv(stripped_path, progress = FALSE,
                              col_types = readr::cols(.default = "c"))
  readr::write_csv(dplyr::select(stripped, -"program_year"), stripped_path)

  real_parse_vintage <- parse_vintage
  parse_vintage <- function(...) stop("stringi could not be loaded")
  verdict <- publication_fails(fixture_manifest())
  parse_vintage <- real_parse_vintage

  chk(verdict$failed,
      "T24 a year check that THROWS refuses to publish, it does not pass")
  chk(grepl("could not RUN", verdict$message),
      "T24b the refusal says the check could not run")
  chk(grepl("stringi could not be loaded", verdict$message),
      "T24c and carries the underlying error, so the cause is visible")

  # The ordinary unverifiable case must still read as unverified, not as a
  # broken check: the two are different defects and the audit says which.
  #
  # ONLY CHECKABLE WHERE THE CHECK WORKS. Reaching "unverified" requires
  # parse_vintage() to return NA cleanly, so on the very runner this verdict
  # was added for -- where stringi cannot load and parse_vintage() throws --
  # there is no such thing as a cleanly unverifiable year, and asserting one
  # would be asserting that the environment is healthy. T24-T24c cover the
  # broken case; this covers the healthy one, and says which it had.
  vintage_runs <- !inherits(
    tryCatch(parse_vintage("probe.csv"), error = function(e) e), "error")
  if (vintage_runs) {
    build_full_fixture()
    readr::write_csv(dplyr::select(stripped, -"program_year"), stripped_path)
    unverified <- suppressMessages(
      validate_source_coverage(fixture_manifest(), publication_mode = FALSE))
    chk(identical(
          unverified$validation_status[unverified$program_year == 2023L],
          "year_unverified"),
        "T24d a year with no evidence reads 'unverified', not 'check failed'")
  } else {
    cat("  skip T24d -- parse_vintage() cannot run here, so there is no",
        "cleanly unverifiable year to tell apart\n")
  }
}

cat("\n-- a PANEL source: the file existing proves nothing about a year --\n")
{
  # WHY A SECOND SHAPE EXISTS. Eight of the audit's ten sources keep every
  # year in ONE file with a year column, so the file.exists() test that makes
  # the Open Payments contract real is vacuous for them: a panel that lost
  # 2015 from inside is still a file that exists. These are the tests that the
  # panel contract can actually fail -- without them, declaring eight sources
  # would have produced protection that only reads like protection.
  panel_path <- file.path(fixture_dir, "panel.csv")
  write_panel <- function(years) {
    readr::write_csv(tibble::tibble(
      npi = sprintf("1%09d", seq_along(years)),
      snapshot_year = as.character(years),
      practice_state = rep(c("CO", "NM"), length.out = length(years))),
      panel_path)
  }
  panel_manifest <- function(years = 2021:2025) {
    tibble::tibble(
      source_id = "nppes", source_name = "fixture panel",
      expected_year = years, required = TRUE, source_type = "panel",
      input_path = panel_path, producer = "fixture",
      date_field = "snapshot_year", npi_field = "npi",
      state_field = "practice_state",
      validation_method = "in_file_year_set", source_vintage = "fixture",
      artifact_sha256 = NA_character_, availability_status = "available",
      notes = "fixture")
  }

  write_panel(2021:2025)
  panel_audit <- suppressMessages(
    validate_source_coverage(panel_manifest(), publication_mode = TRUE))
  chk(nrow(panel_audit) == 5L && all(panel_audit$validation_status == "ok"),
      sprintf("T18 five years inside one file validate as five years [%s]",
              paste(unique(panel_audit$validation_status), collapse = ",")))
  chk(identical(as.integer(panel_audit$source_record_count), rep(1L, 5L)),
      "T18b each panel row reports ITS year's count, not the whole file's")

  # THE MUTATION. One year removed from INSIDE the file; the file still
  # exists, is readable, has both declared columns, and holds four of the five
  # declared years. This is the 2026-11-12 defect in panel form.
  write_panel(c(2021, 2022, 2024, 2025))
  verdict <- publication_fails(panel_manifest())
  chk(verdict$failed,
      "T19 a declared year missing from INSIDE the panel fails publication")
  chk(grepl("2023", verdict$message),
      "T19b the failure names the year the panel does not hold")
  chk(grepl("presence proved nothing", verdict$message),
      "T19c the failure says the file existing settled nothing")
  exploratory <- suppressMessages(
    validate_source_coverage(panel_manifest(), publication_mode = FALSE))
  chk(identical(
        exploratory$validation_status[exploratory$program_year == 2023L],
        "year_refuted"),
      "T19d the verdict is year_refuted, not input_present")

  # THE OTHER DIRECTION. The annual model cannot publish an undeclared year,
  # because resolve_source_inputs() only returns declared paths. A panel
  # producer reads the whole file, so a re-scrape that widened the window
  # would publish a year nobody declared -- the glob defect with the sign
  # flipped, the data deciding the sample.
  write_panel(2021:2026)
  verdict <- publication_fails(panel_manifest(2021:2025))
  chk(verdict$failed,
      "T20 a year in the panel that nobody declared fails publication")
  chk(grepl("2026", verdict$message) &&
        grepl("undeclared_year_observed", verdict$message),
      "T20b the failure names the undeclared year and the verdict")
  widened <- suppressMessages(
    validate_source_coverage(panel_manifest(2021:2025),
                             publication_mode = FALSE))
  undeclared_row <- dplyr::filter(widened, .data$program_year == 2026L)
  chk(nrow(undeclared_row) == 1L && isFALSE(undeclared_row$expected),
      "T20c the undeclared year is the one row marked expected = FALSE")
  chk(!(2026L %in% suppressMessages(
          resolve_source_inputs(widened, "nppes"))$program_year),
      "T20d an undeclared year is never resolved as a usable input")
  chk(nrow(suppressMessages(
        validate_source_coverage(panel_manifest(2021:2026),
                                 publication_mode = TRUE))) == 6L,
      "T20e declaring the sixth year is what makes it publishable")

  # THE PERSON KEY IS ENFORCED, NOT DECORATIVE. Healthgrades declares
  # hg_npi and Doximity certification_number; a contract that accepted any
  # spelling would have let a renamed column through, and one that demanded
  # `npi` would have failed those two sources for the wrong reason.
  write_panel(2021:2025)
  renamed_key <- panel_manifest()
  renamed_key$npi_field <- "provider_npi"
  verdict <- publication_fails(renamed_key)
  chk(verdict$failed && grepl("schema_invalid", verdict$message),
      "T21 a declared person key the file does not have fails publication")
  blank_key <- panel_manifest()
  blank_key$npi_field <- NA_character_
  blank_audit <- suppressMessages(
    validate_source_coverage(blank_key, publication_mode = TRUE))
  chk(all(blank_audit$validation_status == "ok") &&
        all(is.na(blank_audit$unique_npi_count)),
      "T21b a source declaring NO person key validates and counts none")
}

cat("\n-- all ten audited sources are under the manifest --\n")
{
  real_manifest <- suppressMessages(read_source_manifest())
  # The audit's own source list, so this cannot drift into a hand-kept copy.
  audited_sources <- c("nppes", "dac_physician_compare", "open_payments",
                       "pecos_revalidation", "facility_affiliation_ccn",
                       "healthgrades", "doximity", "state_boards_of_nursing",
                       "cms_ndh_fhir", "medicaid_enrollment")
  unmanifested <- setdiff(audited_sources, real_manifest$source_id)
  chk(!length(unmanifested),
      sprintf("T22 every audited source has manifest rows [%s]",
              if (length(unmanifested))
                paste(unmanifested, collapse = ", ") else "none missing"))
  chk(all(nzchar(real_manifest$producer)) &&
        !any(grepl("\\*", real_manifest$input_path)),
      "T22b every declared input names a producer and no path is a wildcard")

  # The windows the appendix publishes in prose are the windows the manifest
  # declares. Pinned here rather than restated, so the two cannot drift.
  declared_window <- function(source_id) {
    years <- real_manifest$expected_year[
      real_manifest$source_id == source_id &
        real_manifest$availability_status != "unavailable"]
    sort(unique(years))
  }
  chk(identical(declared_window("nppes"), 2007:2026),
      "T22c NPPES declares 2007-2026, the panel's full published window")
  chk(identical(declared_window("dac_physician_compare"), 2013:2026),
      "T22d DAC declares 2013-2026 across its historical and current files")
  chk(identical(declared_window("pecos_revalidation"), 2021:2026),
      "T22e PECOS revalidation declares 2021-2026")
  chk(identical(declared_window("facility_affiliation_ccn"),
                c(2013:2022, 2026L)),
      "T22f Facility Affiliation declares 2013-2022 and 2026")
  chk(identical(declared_window("medicaid_enrollment"), 2018:2024),
      "T22g Medicaid declares 2018-2024")
  chk(all(vapply(c("healthgrades", "doximity", "cms_ndh_fhir"),
                 function(s) identical(declared_window(s), 2026L),
                 logical(1))),
      "T22h the three current-only sources each declare 2026 alone")

  # THE THREE-YEAR HOLE IS DECLARED, NOT INFERRED FROM ITS ABSENCE. CMS
  # dropped the CCN columns in 2023 and keeps no affiliation history, so no
  # file for 2023-2025 can ever exist. Saying so is the difference between a
  # gap a reader can trust and a gap nobody noticed.
  fa_unavailable <- real_manifest %>%
    dplyr::filter(.data$source_id == "facility_affiliation_ccn",
                  .data$availability_status == "unavailable")
  chk(identical(sort(fa_unavailable$expected_year), 2023:2025) &&
        !any(fa_unavailable$required),
      sprintf("T23 the 2023-2025 affiliation hole is declared unavailable [%s]",
              paste(sort(fa_unavailable$expected_year), collapse = ",")))
  chk(all(grepl("CCN", fa_unavailable$notes)),
      "T23b each unavailable year says why no file for it can exist")
}

unlink(fixture_dir, recursive = TRUE)
cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
