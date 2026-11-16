# =============================================================================
# Declared source coverage: completeness as a precondition, not a consequence
# =============================================================================
# WHY THIS EXISTS. On 2026-11-12 the state-source audit published a one-year
# Open Payments series where five years were intended. Nothing failed. The
# three audit producers each discovered their input with
#
#     Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
#
# and the annual files are gitignored person-level artifacts (.gitignore:660).
# On a machine where only the 2024 file survived, the glob returned one path,
# every downstream step succeeded, and Figures 2, 4 and 5 were drawn from a
# series missing 2021, 2022, 2023 and 2025. A missing input produced a smaller
# chart instead of an error.
#
# The rule this file enforces: THE SET OF FILES PRESENT MAY NEVER DECIDE THE
# SET OF YEARS ANALYSED. The intended observation window is declared in
# config/state_source_audit_sources.csv and resolved against it. A glob may
# still find candidates; it may not define the sample.
#
# What this deliberately does NOT do: require every declared year to contain
# records. A source year that is genuinely complete and contains no qualifying
# cohort record is valid evidence of absence (Delaware's Board of Nursing file
# is present and empty, and that is a finding). A source file that is missing
# or whose year cannot be established is not evidence of anything. Those two
# cases are reported separately and only the second one fails a build.
#
# Year verification delegates to R/lib/source_year.R (assert_source_year()),
# which already encodes the house rule -- an in-file date column first, an
# authoritative release identifier second, a pinned hash third, and a refusal
# to accept a bare four-digit number in a filename as proof of anything.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

if (!exists("assert_source_year", mode = "function")) {
  source(file.path("R", "lib", "source_year.R"))
}

#' Columns every coverage audit row carries
#'
#' Declared once so the audit CSV, the tests, and any consumer agree on the
#' schema without restating it.
#' @return [character] column names, in order.
source_coverage_columns <- function() {
  c("source_id", "program_year", "input_path", "expected", "required",
    "input_present", "source_year_verified", "year_method", "schema_valid",
    "source_file_sha256", "source_vintage", "source_record_count",
    "unique_npi_count", "cohort_npi_count", "cohort_amcb_id_count",
    "state_observed_count", "provenance_valid", "validation_status",
    "validation_message")
}

#' Read and sanity-check the declared source manifest
#'
#' @param manifest_path [character] path to the manifest CSV.
#' @return [tbl_df] the manifest, with `expected_year` integer and `required`
#'   logical.
#' @examples
#' # read_source_manifest("config/state_source_audit_sources.csv")
read_source_manifest <- function(
    manifest_path = file.path("config", "state_source_audit_sources.csv")) {
  if (!file.exists(manifest_path))
    stop(sprintf("source manifest not found: %s", manifest_path),
         call. = FALSE)
  manifest_rows <- readr::read_csv(manifest_path,
                                   col_types = readr::cols(.default = "c"),
                                   progress = FALSE)
  needed_fields <- c("source_id", "source_name", "expected_year", "required",
                     "source_type", "input_path", "producer", "date_field",
                     "state_field", "validation_method", "availability_status",
                     "notes")
  absent_fields <- setdiff(needed_fields, names(manifest_rows))
  if (length(absent_fields))
    stop(sprintf("source manifest is missing column(s): %s",
                 paste(absent_fields, collapse = ", ")), call. = FALSE)

  manifest_rows <- manifest_rows %>%
    dplyr::mutate(
      expected_year = suppressWarnings(as.integer(.data$expected_year)),
      required = tolower(trimws(.data$required)) %in% c("true", "yes", "1"))

  duplicate_keys <- manifest_rows %>%
    dplyr::count(.data$source_id, .data$expected_year, .data$input_path) %>%
    dplyr::filter(.data$n > 1L)
  if (nrow(duplicate_keys))
    stop(sprintf("source manifest declares the same source/year twice: %s",
                 paste(duplicate_keys$source_id, duplicate_keys$expected_year,
                       collapse = "; ")), call. = FALSE)

  base::message(sprintf(
    "read_source_manifest(): %d declared source-year rows across %d sources",
    nrow(manifest_rows), dplyr::n_distinct(manifest_rows$source_id)))
  manifest_rows
}

#' Describe one declared source-year input
#'
#' Reads only what the audit needs to characterise the file: its row count,
#' its distinct NPIs and certification numbers, and how many rows carry a
#' usable state. Returns counts of NA when the file is absent, so an absent
#' input is never silently indistinguishable from an empty one.
#'
#' @param input_path [character] path to the annual artifact.
#' @param state_column [character] column holding the source's state value.
#' @return [list] the measured fields.
describe_source_input <- function(input_path, state_column) {
  blank_record <- list(record_count = NA_integer_, npi_count = NA_integer_,
                       amcb_id_count = NA_integer_,
                       state_observed = NA_integer_,
                       file_sha256 = NA_character_, schema_valid = NA)
  if (!file.exists(input_path)) return(blank_record)

  input_rows <- tryCatch(
    readr::read_csv(input_path, col_types = readr::cols(.default = "c"),
                    progress = FALSE),
    error = function(e) NULL)
  if (is.null(input_rows)) {
    # Present but unparseable is a DIFFERENT verdict from absent: hash it so
    # the audit can name the exact file that would not read.
    blank_record$schema_valid <- FALSE
    blank_record$file_sha256 <- digest_file_sha256(input_path)
    return(blank_record)
  }

  has_npi <- "npi" %in% names(input_rows)

  # A SOURCE THAT PUBLISHES NO STATE AT ALL IS DECLARED, NOT BROKEN. The
  # Texas BON APRN file and the Washington DOH credential file carry no
  # address field of any kind, so no re-harvest can produce a state from
  # them; both declare an EMPTY state_field in the manifest. That has to be
  # distinguishable from Colorado's file, which DOES publish a state and
  # whose column went missing because the harvester dropped it -- the bug
  # this contract exists to catch. So an empty declaration excuses the
  # column, a non-empty one demands it, and `state_observed` stays 0 either
  # way so nothing downstream can read a declared absence as evidence.
  state_declared <- !is.na(state_column) && nzchar(state_column)
  has_state_column <- state_declared && state_column %in% names(input_rows)
  has_state <- has_state_column || !state_declared
  state_values <- if (has_state_column)
    input_rows[[state_column]] else character(0)

  list(
    record_count = nrow(input_rows),
    npi_count = if (has_npi)
      dplyr::n_distinct(input_rows$npi[!is.na(input_rows$npi)]) else NA_integer_,
    amcb_id_count = if ("certification_number" %in% names(input_rows))
      dplyr::n_distinct(
        input_rows$certification_number[
          !is.na(input_rows$certification_number)]) else NA_integer_,
    state_observed = if (has_state_column)
      sum(!is.na(state_values) & nzchar(trimws(state_values))) else 0L,
    file_sha256 = digest_file_sha256(input_path),
    schema_valid = has_npi && has_state)
}

#' SHA-256 of a file, or NA when it cannot be read
#'
#' @param input_path [character] path to hash.
#' @return [character] lowercase hex digest, or NA_character_.
digest_file_sha256 <- function(input_path) {
  tryCatch({
    if (requireNamespace("digest", quietly = TRUE))
      digest::digest(file = input_path, algo = "sha256")
    else
      as.character(system2("shasum", c("-a", "256", shQuote(input_path)),
                           stdout = TRUE)[1]) |>
        substr(1, 64)
  }, error = function(e) NA_character_)
}

#' Validate declared source coverage and return the coverage audit
#'
#' THE PRECONDITION, NOT A POST-HOC CHECK. Call this before a publication
#' producer writes anything. In `publication_mode` it stops when a required
#' declared source-year is missing, unreadable, schema-invalid, or its year
#' cannot be established -- naming every offending year, not just the first.
#'
#' @param source_manifest [tbl_df] from `read_source_manifest()`.
#' @param publication_mode [logical] TRUE (default) fails the build on missing
#'   required evidence. FALSE records the same verdicts and returns them, for
#'   an explicitly-invoked exploratory run that must label its outputs.
#' @param source_ids [character] optional subset of `source_id` to validate.
#' @return [tbl_df] one row per declared source-year, columns per
#'   `source_coverage_columns()`.
validate_source_coverage <- function(source_manifest,
                                     publication_mode = TRUE,
                                     source_ids = NULL) {
  if (!is.null(source_ids))
    source_manifest <- dplyr::filter(source_manifest,
                                     .data$source_id %in% source_ids)
  if (!nrow(source_manifest))
    stop("validate_source_coverage(): no declared rows to validate",
         call. = FALSE)

  audit_rows <- vector("list", nrow(source_manifest))
  for (row_index in seq_len(nrow(source_manifest))) {
    declared <- source_manifest[row_index, ]
    input_path <- declared$input_path
    present <- file.exists(input_path)
    measured <- describe_source_input(input_path, declared$state_field)

    year_verified <- NA
    year_method <- NA_character_
    if (present && !is.na(declared$expected_year) &&
        identical(declared$validation_method, "in_file_date")) {
      year_probe <- tryCatch(
        assert_source_year(input_path, declared$expected_year,
                           date_columns = declared$date_field, strict = FALSE),
        error = function(e) NULL)
      if (!is.null(year_probe)) {
        # "refuted" means the data contradicts the declared year; "unverified"
        # means the year could not be established at all. Both are unusable
        # for publication, but they are different defects and the audit says
        # which, so a fix targets the right thing.
        year_verified <- if (identical(year_probe$status, "refuted")) FALSE
                         else if (identical(year_probe$status, "unverified")) NA
                         else TRUE
        year_method <- year_probe$status
      }
    } else if (present && identical(declared$validation_method,
                                    "producer_declared")) {
      # The producer writes one year per file and records the program year in
      # its own provenance; the filename alone is NOT treated as proof.
      year_verified <- NA
      year_method <- "producer_declared"
    } else if (present) {
      year_method <- declared$validation_method
      year_verified <- NA
    }

    status <- dplyr::case_when(
      !declared$required && identical(declared$availability_status,
                                      "ineligible") ~ "ineligible",
      !present && declared$required ~ "missing_required_input",
      !present && !declared$required ~ "absent_optional_input",
      isFALSE(measured$schema_valid) ~ "schema_invalid",
      # ZERO RECORDS IS DECIDED BEFORE THE YEAR IS. A complete source year
      # with no qualifying cohort record has no rows to carry a date, so it
      # can never prove its own year -- judging it on that would fail exactly
      # the valid-absence case this contract exists to protect (Delaware's
      # Board of Nursing file is present and empty, and that is a finding).
      isTRUE(measured$record_count == 0L) ~ "present_zero_records",
      identical(year_verified, FALSE) ~ "year_refuted",
      identical(declared$validation_method, "in_file_date") &&
        identical(year_method, "unverified") ~ "year_unverified",
      TRUE ~ "ok")

    status_message <- dplyr::case_when(
      status == "ineligible" ~ paste0(
        "declared ineligible for this year: ", declared$notes),
      status == "missing_required_input" ~ paste0(
        "REQUIRED input absent: ", input_path,
        " -- regenerate with ", declared$producer),
      status == "absent_optional_input" ~ paste0(
        "optional input absent: ", input_path),
      status == "schema_invalid" ~ paste0(
        "present but missing npi or the declared state column '",
        declared$state_field, "': ", input_path,
        " -- regenerate with ", declared$producer,
        " (a source that genuinely publishes no state declares an empty ",
        "state_field instead)"),
      status == "year_refuted" ~ paste0(
        "in-file year contradicts declared year ", declared$expected_year),
      status == "year_unverified" ~ paste0(
        "cannot establish the program year from column '", declared$date_field,
        "' -- a four-digit year in the filename is not proof"),
      status == "present_zero_records" ~ paste0(
        "present and complete with zero qualifying cohort records ",
        "-- valid evidence of absence"),
      TRUE ~ "declared, present, schema and year checks passed")

    audit_rows[[row_index]] <- tibble::tibble(
      source_id = declared$source_id,
      program_year = declared$expected_year,
      input_path = input_path,
      expected = TRUE,
      required = declared$required,
      input_present = present,
      source_year_verified = year_verified,
      year_method = year_method,
      schema_valid = measured$schema_valid,
      source_file_sha256 = measured$file_sha256,
      source_vintage = declared$source_vintage %||% NA_character_,
      source_record_count = measured$record_count,
      unique_npi_count = measured$npi_count,
      cohort_npi_count = measured$npi_count,
      cohort_amcb_id_count = measured$amcb_id_count,
      state_observed_count = measured$state_observed,
      provenance_valid = file.exists(paste0(input_path, ".provenance.json")),
      validation_status = status,
      validation_message = status_message)
  }

  coverage_audit <- dplyr::bind_rows(audit_rows)

  for (audit_index in seq_len(nrow(coverage_audit))) {
    base::message(sprintf(
      "  [%s] %s %s -- %s",
      coverage_audit$validation_status[audit_index],
      coverage_audit$source_id[audit_index],
      ifelse(is.na(coverage_audit$program_year[audit_index]), "(snapshot)",
             as.character(coverage_audit$program_year[audit_index])),
      coverage_audit$validation_message[audit_index]))
  }

  failing_rows <- coverage_audit %>%
    dplyr::filter(.data$required,
                  .data$validation_status %in% c("missing_required_input",
                                                 "schema_invalid",
                                                 "year_refuted",
                                                 "year_unverified"))
  if (nrow(failing_rows)) {
    # THE ERROR CARRIES THE REASON, NOT JUST THE VERDICT. A build that stops
    # with "schema_invalid" tells whoever reads the CI log nothing about which
    # column went missing or which producer to rerun; the per-row
    # validation_message already says both, so it goes in the failure instead
    # of only into the message log, where a non-interactive run loses it.
    failure_text <- paste(sprintf("%s %s: %s -- %s", failing_rows$source_id,
                                  ifelse(is.na(failing_rows$program_year),
                                         "(snapshot)",
                                         failing_rows$program_year),
                                  failing_rows$validation_status,
                                  failing_rows$validation_message),
                          collapse = "\n  ")
    if (isTRUE(publication_mode)) {
      stop(sprintf(paste0(
        "validate_source_coverage(): %d required source-year(s) cannot be ",
        "used, so this build must not publish:\n  %s\n",
        "Regenerate the inputs, or rerun with publication_mode = FALSE to ",
        "produce an explicitly-labelled exploratory result."),
        nrow(failing_rows), failure_text), call. = FALSE)
    }
    base::message(sprintf(paste0(
      "validate_source_coverage(): EXPLORATORY MODE -- %d required ",
      "source-year(s) unusable; outputs must be labelled incomplete:\n  %s"),
      nrow(failing_rows), failure_text))
  } else {
    base::message(sprintf(
      "validate_source_coverage(): all %d required source-year(s) validated",
      sum(coverage_audit$required)))
  }

  coverage_audit
}

#' Resolve the validated input paths for one declared source
#'
#' The replacement for `Sys.glob()` in a publication producer. Returns only
#' paths the coverage audit accepted, in declared-year order, so the analysed
#' window is the declared window.
#'
#' @param coverage_audit [tbl_df] from `validate_source_coverage()`.
#' @param source_id_wanted [character] the source to resolve.
#' @return [tbl_df] `program_year` and `input_path` for usable inputs.
resolve_source_inputs <- function(coverage_audit, source_id_wanted) {
  usable_statuses <- c("ok", "present_zero_records")
  resolved <- coverage_audit %>%
    dplyr::filter(.data$source_id == source_id_wanted,
                  .data$validation_status %in% usable_statuses) %>%
    dplyr::select("source_id", "program_year", "input_path") %>%
    dplyr::arrange(.data$program_year, .data$input_path)

  base::message(sprintf(
    "resolve_source_inputs(): %s -> %d validated input(s): %s",
    source_id_wanted, nrow(resolved),
    paste(ifelse(is.na(resolved$program_year), "(snapshot)",
                 resolved$program_year), collapse = ", ")))
  resolved
}

`%||%` <- function(lhs, rhs) if (is.null(lhs)) rhs else lhs
