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
# TWO SHAPES OF SOURCE, ONE RULE. Open Payments keeps one file per year, so
# a missing year is a missing file and file.exists() is a real test of it. The
# other eight audited sources keep every year in ONE file with a year column
# (midwife_panel.csv holds 2007-2026), and for those file.exists() proves
# nothing about any particular year -- a panel that lost 2015 from inside is
# still a file that exists. Declaring such a source row-per-year against a
# presence check would have produced a contract that cannot fail, which is a
# worse state than no contract, because it reads like protection. So a panel
# row declares validation_method = "in_file_year_set" and is checked against
# the years the file actually holds, in BOTH directions:
#
#   a declared year absent from the data -> year_refuted (the 11-12 defect)
#   a year in the data nobody declared    -> undeclared_year_observed
#
# The second direction is what the annual model gets for free -- resolve_source_
# inputs() can only return paths that were declared -- and what a panel does
# not, because its producer reads the whole file. Without it, a re-scrape that
# silently widened a source's window would publish an undeclared year, which
# is the same inversion as the glob: the data deciding the sample.
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

  # npi_field ARRIVED LATER, SO IT IS OPTIONAL WITH A DEFAULT. Twenty-one rows
  # were declared before any source needed to name its own person key, and all
  # of them link on `npi`. Requiring the column would have made every one of
  # them unreadable; defaulting the whole column when it is absent keeps the
  # single meaning -- "the person key is `npi` unless the row says otherwise" --
  # while letting Healthgrades declare `hg_npi` and Doximity declare
  # `certification_number`, the only key it publishes. Note the default is
  # applied to the ABSENT COLUMN, never to an absent CELL: an empty cell in a
  # manifest that has the column is a deliberate declaration that the source
  # has no person key at all (the Medicaid concordance is an aggregate), and
  # filling it in with `npi` would turn that declaration into a schema failure.
  if (!"npi_field" %in% names(manifest_rows))
    manifest_rows$npi_field <- "npi"

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
#' @param npi_column [character] column holding the source's person key.
#'   Defaults to `npi`; an empty declaration excuses the column, exactly as an
#'   empty `state_column` does.
#' @return [list] the measured fields.
describe_source_input <- function(input_path, state_column,
                                  npi_column = "npi") {
  blank_record <- list(record_count = NA_integer_, npi_count = NA_integer_,
                       amcb_id_count = NA_integer_,
                       state_observed = NA_integer_,
                       file_sha256 = NA_character_, schema_valid = NA,
                       parse_problems = NA_integer_)
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
    blank_record$parse_problems <- NA_integer_
    return(blank_record)
  }

  # CORRUPTION IS DETECTED, NOT WAITED FOR. The branch above fires only when
  # readr THROWS, and readr almost never throws on a damaged CSV -- it warns
  # and hands back whatever it could make of the bytes. So that branch was
  # close to dead code, and the contract's answer for a corrupt required
  # input depended on what readr's leniency happened to do with it. In CI,
  # where the installed readr parses an unterminated quote differently from
  # the one on this machine, the same corrupt fixture graded "ok" -- T7 had
  # been passing locally only because the junk also nulled the year column
  # and tripped a different guard entirely. A parse that reported problems
  # is not trustworthy evidence whatever it returned, so it is refused here,
  # on any readr version. Measured across all 29 real declared inputs:
  # zero problems, so this costs nothing that is actually readable.
  parse_problem_count <- tryCatch(nrow(readr::problems(input_rows)),
                                  error = function(e) 0L)
  if (parse_problem_count > 0L) {
    blank_record$schema_valid <- FALSE
    blank_record$file_sha256 <- digest_file_sha256(input_path)
    blank_record$parse_problems <- parse_problem_count
    return(blank_record)
  }

  # THE PERSON KEY IS DECLARED, NOT ASSUMED TO BE SPELLED `npi`. This read
  # `"npi" %in% names(input_rows)` while every declared source happened to use
  # that spelling, so the first source that does not would have been graded
  # schema_invalid and failed the build for having the wrong column name
  # rather than the wrong data. Healthgrades publishes `hg_npi`; Doximity
  # publishes no NPI at all and is linked through `certification_number` via
  # the frozen AMCB linkage; the Medicaid concordance is a year x
  # classification aggregate with no person column at all and declares none.
  # Those are three different facts and the manifest now states each.
  npi_declared <- !is.na(npi_column) && nzchar(npi_column)
  has_npi_column <- npi_declared && npi_column %in% names(input_rows)
  has_npi <- has_npi_column || !npi_declared

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
    npi_count = if (has_npi_column)
      dplyr::n_distinct(
        input_rows[[npi_column]][!is.na(input_rows[[npi_column]])])
      else NA_integer_,
    amcb_id_count = if ("certification_number" %in% names(input_rows))
      dplyr::n_distinct(
        input_rows$certification_number[
          !is.na(input_rows$certification_number)]) else NA_integer_,
    state_observed = if (has_state_column)
      sum(!is.na(state_values) & nzchar(trimws(state_values))) else 0L,
    file_sha256 = digest_file_sha256(input_path),
    schema_valid = has_npi && has_state,
    parse_problems = 0L)
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

#' Describe a panel file once: its year set and its per-year counts
#'
#' ONE PASS, NOT ONE PER DECLARED YEAR. NPPES declares twenty rows against a
#' 4.7-million-row panel, and the first version of this contract called
#' `describe_source_input()` per row -- twenty full reads of a 700 MB CSV to
#' answer twenty variants of one question. Everything a panel row needs is a
#' property of the file (its year set, its hash, whether the declared columns
#' are there) or of one year within it (counts), so both are measured here
#' together and looked up per row.
#'
#' EXACTLY, NOT SAMPLED. `source_year_from_columns()` reads a head sample and
#' a tail sample, which proves a one-year file is that year and is wrong here:
#' the panel is ordered by snapshot year, so head-and-tail sees 2007 and 2026
#' and would refute all eighteen years between them. Only the declared columns
#' are parsed, so the file is read without materialising the rest.
#'
#' A PANEL CANNOT REPORT A PRESENT-BUT-EMPTY YEAR. An annual file can be on
#' disk with zero rows, and that is valid evidence of absence. A year with no
#' rows inside a panel leaves no trace at all, so it is indistinguishable from
#' a year that was never loaded, and this returns no entry for it -- which
#' makes the year refuted rather than empty. That is the safe verdict and a
#' real limit of the panel shape, stated here rather than papered over.
#'
#' @param input_path [character] the panel file.
#' @param date_column [character] the column carrying the year, matched
#'   case-insensitively. Only the first four characters are read, so `2019`,
#'   `2019-06` and `2019-06-30` all answer 2019.
#' @param state_column [character] the source's state column, or empty when it
#'   genuinely publishes none.
#' @param npi_column [character] the source's person key, or empty when it has
#'   none (an aggregate).
#' @return [list] `file_sha256`, `schema_valid`, and `by_year`: one row per
#'   observed year with `record_count`, `npi_count`, `amcb_id_count` and
#'   `state_observed`.
#' @examples
#' f <- tempfile(fileext = ".csv")
#' readr::write_csv(data.frame(npi = c("1", "2"), yr = c("2019", "2020"),
#'                             st = c("CO", "NM")), f)
#' describe_panel_input(f, "yr", "st", "npi")$by_year$program_year
#' #> [1] 2019 2020
describe_panel_input <- function(input_path, date_column, state_column,
                                 npi_column = "npi") {
  empty_by_year <- tibble::tibble(
    program_year = integer(0), record_count = integer(0),
    npi_count = integer(0), amcb_id_count = integer(0),
    state_observed = integer(0))
  if (!file.exists(input_path))
    return(list(file_sha256 = NA_character_, schema_valid = NA,
                parse_problems = NA_integer_, by_year = empty_by_year))

  header_names <- tryCatch(
    names(readr::read_csv(input_path, n_max = 0L,
                          col_types = readr::cols(.default = "c"),
                          progress = FALSE)),
    error = function(e) character(0))
  resolve_column <- function(declared) {
    if (length(declared) != 1L || is.na(declared) || !nzchar(declared))
      return(NA_character_)
    present <- header_names[tolower(header_names) == tolower(declared)]
    if (length(present)) present[1] else NA_character_
  }
  year_name <- resolve_column(date_column)
  state_name <- resolve_column(state_column)
  npi_name <- resolve_column(npi_column)
  amcb_name <- resolve_column("certification_number")

  # Same rule as describe_source_input(): an EMPTY declaration excuses the
  # column, a non-empty one demands it.
  state_declared <- length(state_column) == 1L && !is.na(state_column) &&
    nzchar(state_column)
  npi_declared <- length(npi_column) == 1L && !is.na(npi_column) &&
    nzchar(npi_column)
  schema_valid <- (!npi_declared || !is.na(npi_name)) &&
    (!state_declared || !is.na(state_name))
  described <- list(file_sha256 = digest_file_sha256(input_path),
                    schema_valid = schema_valid, parse_problems = 0L,
                    by_year = empty_by_year)
  if (is.na(year_name) || !length(header_names)) return(described)

  read_names <- unique(c(year_name, state_name, npi_name, amcb_name))
  read_names <- read_names[!is.na(read_names)]
  column_spec <- stats::setNames(
    rep(list(readr::col_skip()), length(header_names)), header_names)
  for (read_name in read_names)
    column_spec[[read_name]] <- readr::col_character()
  panel_rows <- tryCatch(
    readr::read_csv(input_path,
                    col_types = do.call(readr::cols, column_spec),
                    progress = FALSE),
    error = function(e) NULL)
  if (is.null(panel_rows)) {
    described$schema_valid <- FALSE
    described$parse_problems <- NA_integer_
    return(described)
  }
  # Same rule as describe_source_input(): a parse that reported problems is
  # not evidence, whatever readr handed back. The COUNT travels with the
  # verdict so the refusal can say "unparseable" rather than fall through to
  # "missing npi or the declared state column", which would name the wrong
  # fix for a damaged panel.
  panel_problem_count <- tryCatch(nrow(readr::problems(panel_rows)),
                                  error = function(e) 0L)
  if (panel_problem_count > 0L) {
    described$schema_valid <- FALSE
    described$parse_problems <- panel_problem_count
    return(described)
  }

  column_or_na <- function(column_name) {
    if (is.na(column_name)) rep(NA_character_, nrow(panel_rows))
    else as.character(panel_rows[[column_name]])
  }
  measured_rows <- tibble::tibble(
    program_year = suppressWarnings(as.integer(
      substr(trimws(as.character(panel_rows[[year_name]])), 1L, 4L))),
    state_value = column_or_na(state_name),
    npi_value = column_or_na(npi_name),
    amcb_value = column_or_na(amcb_name))

  nonblank <- function(values) sum(!is.na(values) & nzchar(trimws(values)))
  described$by_year <- measured_rows %>%
    dplyr::filter(!is.na(.data$program_year)) %>%
    dplyr::group_by(.data$program_year) %>%
    dplyr::summarise(
      record_count = dplyr::n(),
      npi_count = if (is.na(npi_name)) NA_integer_ else
        dplyr::n_distinct(.data$npi_value[!is.na(.data$npi_value)]),
      amcb_id_count = if (is.na(amcb_name)) NA_integer_ else
        dplyr::n_distinct(.data$amcb_value[!is.na(.data$amcb_value)]),
      state_observed = if (is.na(state_name)) 0L
        else nonblank(.data$state_value),
      .groups = "drop") %>%
    dplyr::arrange(.data$program_year)

  base::message(sprintf(
    "describe_panel_input(): %s holds %d year(s) over %s rows: %s",
    basename(input_path), nrow(described$by_year),
    format(sum(described$by_year$record_count), big.mark = ","),
    paste(described$by_year$program_year, collapse = ", ")))
  described
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

  # ONCE PER FILE, NOT ONCE PER DECLARED YEAR. NPPES declares twenty rows
  # against one 4.7-million-row panel; reading it twenty times to answer the
  # same question twenty ways would take twenty scans and could, if the file
  # changed underneath, answer differently each time.
  panel_declarations <- dplyr::filter(
    source_manifest, .data$validation_method == "in_file_year_set")
  panel_described <- list()
  for (panel_path in unique(panel_declarations$input_path)) {
    first_row <- match(panel_path, panel_declarations$input_path)
    panel_described[[panel_path]] <- describe_panel_input(
      panel_path,
      panel_declarations$date_field[first_row],
      panel_declarations$state_field[first_row],
      panel_declarations$npi_field[first_row])
  }

  audit_rows <- vector("list", nrow(source_manifest))
  for (row_index in seq_len(nrow(source_manifest))) {
    declared <- source_manifest[row_index, ]
    input_path <- declared$input_path
    present <- file.exists(input_path)
    declared_npi_field <- if ("npi_field" %in% names(declared))
      declared$npi_field else "npi"
    described <- panel_described[[input_path]]
    is_panel <- identical(declared$validation_method, "in_file_year_set")
    observed_years <- if (is.null(described)) integer(0)
                      else described$by_year$program_year
    # A panel row's counts are THAT YEAR's, not the file's. Repeating the
    # panel's 4.7 million rows on each of twenty NPPES rows would put a
    # number in a published audit artifact that is true of no year in it.
    measured <- if (is_panel && !is.null(described)) {
      year_row <- dplyr::filter(described$by_year,
                                .data$program_year == declared$expected_year)
      list(record_count = if (nrow(year_row)) year_row$record_count[1]
                          else NA_integer_,
           npi_count = if (nrow(year_row)) year_row$npi_count[1]
                       else NA_integer_,
           amcb_id_count = if (nrow(year_row)) year_row$amcb_id_count[1]
                           else NA_integer_,
           state_observed = if (nrow(year_row)) year_row$state_observed[1]
                            else NA_integer_,
           file_sha256 = described$file_sha256,
           schema_valid = described$schema_valid,
           parse_problems = described$parse_problems)
    } else {
      describe_source_input(input_path, declared$state_field,
                            declared_npi_field)
    }

    year_verified <- NA
    year_method <- NA_character_
    # A CHECK THAT COULD NOT RUN IS NOT A CHECK THAT PASSED. This tryCatch
    # mapped any error to NULL, and a NULL probe left year_verified NA and
    # year_method NA_character_ -- which fell through every case below to
    # "ok". So a year whose evidence could not be examined at all was graded
    # usable, by the same silence this whole contract exists to end.
    #
    # It is not hypothetical. assert_source_year() reaches parse_vintage()
    # whenever no in-file date is found, and parse_vintage() calls
    # stringr::str_match(). On a CI runner whose stringi could not load its
    # ICU library, that call threw, every such row graded "ok", and three
    # saboteurs written to prove exactly this case -- a stripped year column,
    # a blanked year column, a corrupt file -- all reported that the build
    # refused nothing. A broken package was silently converting
    # "unverifiable" into "fine". The error is now its own verdict and
    # carries its own text, so a reader sees the stringi failure instead of
    # a green build.
    year_probe_error <- NA_character_
    if (present && !is.na(declared$expected_year) &&
        identical(declared$validation_method, "in_file_date")) {
      year_probe <- tryCatch(
        assert_source_year(input_path, declared$expected_year,
                           date_columns = declared$date_field, strict = FALSE),
        error = function(e) {
          year_probe_error <<- conditionMessage(e)
          NULL
        })
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
    } else if (present && !is.na(declared$expected_year) && is_panel) {
      # The same refusal rules as a one-year file, with the mixed-year rule
      # suspended because a panel spanning years is the declared shape. What
      # is NOT suspended is `expected_year %in% years`: that is the whole
      # check, and the reason a panel can be declared at all.
      year_probe <- tryCatch(
        assert_year_set(observed_years, declared$expected_year,
                        multiyear = TRUE, strict = FALSE,
                        label = basename(input_path)),
        error = function(e) {
          year_probe_error <<- conditionMessage(e)
          NULL
        })
      if (!is.null(year_probe)) {
        year_verified <- if (identical(year_probe$status, "refuted")) FALSE
                         else if (identical(year_probe$status,
                                            "unverified")) NA
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
      # A DECLARED EXCLUSION IS NOT UNDONE BY A FILE TURNING UP. Open
      # Payments 2013 and 2014 are declared `unavailable` because the CMS
      # file carries no NPI column at all, so no file for those years can
      # ever be analysable. Only `ineligible` was being honoured here, so a
      # stub or a mis-keyed regeneration producing a readable 2013 file would
      # have been graded "ok", joined the resolved inputs and widened the
      # published Open Payments window by two pre-eligibility years -- a
      # declaration overruled by the filesystem, which is the inversion this
      # whole contract exists to forbid. The verdict stays distinct from
      # `ineligible` because the reason is different and the audit says which.
      !declared$required && identical(declared$availability_status,
                                      "unavailable") ~ "declared_unavailable",
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
      declared$validation_method %in% c("in_file_date",
                                        "in_file_year_set") &&
        identical(year_method, "unverified") ~ "year_unverified",
      !is.na(year_probe_error) ~ "year_check_failed",
      TRUE ~ "ok")

    status_message <- dplyr::case_when(
      status == "ineligible" ~ paste0(
        "declared ineligible for this year: ", declared$notes),
      status == "declared_unavailable" ~ paste0(
        "declared unavailable for this year, so no file for it is ",
        "analysable: ", declared$notes),
      status == "missing_required_input" ~ paste0(
        "REQUIRED input absent: ", input_path,
        " -- regenerate with ", declared$producer),
      status == "absent_optional_input" ~ paste0(
        "optional input absent: ", input_path),
      status == "schema_invalid" &&
        isTRUE(measured$parse_problems > 0L) ~ paste0(
        "present but UNPARSEABLE: readr reported ", measured$parse_problems,
        " parsing problem(s) in ", input_path,
        " -- a damaged file is not evidence of anything, whatever it parsed",
        " to; regenerate with ", declared$producer),
      status == "schema_invalid" ~ paste0(
        "present but missing npi or the declared state column '",
        declared$state_field, "': ", input_path,
        " -- regenerate with ", declared$producer,
        " (a source that genuinely publishes no state declares an empty ",
        "state_field instead)"),
      status == "year_refuted" &&
        identical(declared$validation_method, "in_file_year_set") ~ paste0(
        "declared year ", declared$expected_year, " is NOT among the ",
        length(observed_years), " year(s) the panel holds (",
        paste(observed_years, collapse = ", "), ") -- the file exists, so ",
        "presence proved nothing; regenerate with ", declared$producer),
      status == "year_refuted" ~ paste0(
        "in-file year contradicts declared year ", declared$expected_year),
      status == "year_unverified" ~ paste0(
        "cannot establish the program year from column '", declared$date_field,
        "' -- a four-digit year in the filename is not proof"),
      status == "year_check_failed" ~ paste0(
        "the year check could not RUN on ", input_path, ": ",
        year_probe_error,
        " -- a year whose evidence could not be examined has not passed"),
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

  # THE OTHER DIRECTION: A YEAR NOBODY DECLARED. The annual model gets this
  # free, because resolve_source_inputs() can only hand back a path that was
  # declared. A panel producer reads the whole file, so a re-scrape that
  # widened the source's window -- a later NPPES dissemination appended, a
  # Doximity scrape that started carrying date_modified from an earlier year --
  # would be published without anyone declaring it. That is the glob defect
  # with the sign flipped: the data deciding the sample. These rows are the
  # only ones in the audit with `expected = FALSE`, which is what the column
  # is for; they are not `required`, and they fail a publication build anyway,
  # because the objection is not that something is missing.
  for (panel_path in names(panel_described)) {
    declared_years <- panel_declarations$expected_year[
      panel_declarations$input_path == panel_path]
    undeclared_years <- setdiff(
      panel_described[[panel_path]]$by_year$program_year, declared_years)
    for (undeclared_year in undeclared_years) {
      coverage_audit <- dplyr::bind_rows(coverage_audit, tibble::tibble(
        source_id = panel_declarations$source_id[
          match(panel_path, panel_declarations$input_path)],
        program_year = as.integer(undeclared_year),
        input_path = panel_path,
        expected = FALSE, required = FALSE, input_present = TRUE,
        source_year_verified = TRUE, year_method = "in_file_date",
        schema_valid = NA, source_file_sha256 = NA_character_,
        source_vintage = NA_character_, source_record_count = NA_integer_,
        unique_npi_count = NA_integer_, cohort_npi_count = NA_integer_,
        cohort_amcb_id_count = NA_integer_, state_observed_count = NA_integer_,
        provenance_valid = NA,
        validation_status = "undeclared_year_observed",
        validation_message = paste0(
          "the panel holds year ", undeclared_year,
          " and the manifest does not declare it, so publishing this source ",
          "would report a window nobody declared: add the row to ",
          "config/state_source_audit_sources.csv, or fix ", panel_path)))
    }
  }
  coverage_audit <- dplyr::arrange(coverage_audit, .data$source_id,
                                   .data$program_year, .data$input_path)

  for (audit_index in seq_len(nrow(coverage_audit))) {
    base::message(sprintf(
      "  [%s] %s %s -- %s",
      coverage_audit$validation_status[audit_index],
      coverage_audit$source_id[audit_index],
      ifelse(is.na(coverage_audit$program_year[audit_index]), "(snapshot)",
             as.character(coverage_audit$program_year[audit_index])),
      coverage_audit$validation_message[audit_index]))
  }

  # `required` gates the four MISSING-EVIDENCE verdicts, because an optional
  # year that is absent is a declared absence. It must not gate
  # undeclared_year_observed, whose complaint is the opposite -- evidence
  # nobody declared -- and which carries required = FALSE precisely because
  # nothing asked for it.
  failing_rows <- coverage_audit %>%
    dplyr::filter(
      (.data$required &
         .data$validation_status %in% c("missing_required_input",
                                        "schema_invalid",
                                        "year_refuted",
                                        "year_unverified",
                                        "year_check_failed")) |
        .data$validation_status == "undeclared_year_observed")
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

#' The one validated path a source has for a year
#'
#' AMBIGUITY IS AN ERROR, NOT A COIN FLIP -- the same rule
#' `cohort_artifact_path()` states for the crosswalk arms, for the same
#' reason. A producer that reads a source through this cannot be holding a
#' path the manifest does not declare, which is what stops the manifest from
#' becoming a second inventory that nothing consults and nobody updates.
#'
#' A panel declares the same path once per year, so its years collapse to one
#' path and the `program_year` argument is unnecessary. A source split across
#' files (DAC's historical vintages and its current pull; Facility
#' Affiliation's embedded history and CMS's current product) needs the year to
#' say which file, and gets an error rather than a guess if it omits it.
#'
#' @param coverage_audit [tbl_df] from `validate_source_coverage()`.
#' @param source_id_wanted [character] the source to resolve.
#' @param program_year [integer] the year, when the source has more than one
#'   file. Omit for a single-file source.
#' @return [character] exactly one validated path.
#' @examples
#' # declared_path(coverage_audit, "nppes")
#' # declared_path(coverage_audit, "dac_physician_compare", 2026L)
declared_path <- function(coverage_audit, source_id_wanted,
                          program_year = NULL) {
  resolved <- resolve_source_inputs(coverage_audit, source_id_wanted)
  if (!is.null(program_year)) {
    year_wanted <- as.integer(program_year)
    resolved <- dplyr::filter(resolved, .data$program_year == year_wanted)
  }
  candidate_paths <- unique(resolved$input_path)
  if (length(candidate_paths) != 1L)
    stop(sprintf(paste0(
      "declared_path(): %s%s resolves to %d validated path(s), not one: %s. ",
      "Declare the year, or fix config/state_source_audit_sources.csv -- a ",
      "producer may not pick between them."),
      source_id_wanted,
      if (is.null(program_year)) "" else sprintf(" %d", program_year),
      length(candidate_paths),
      if (length(candidate_paths)) paste(candidate_paths, collapse = ", ")
      else "none"), call. = FALSE)
  candidate_paths
}
