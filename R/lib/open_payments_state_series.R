# =============================================================================
# The Open Payments practice-state series, over the DECLARED window
# =============================================================================
# WHY THIS EXISTS. Three producers built this series with the same five lines:
#
#   op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
#   op_all <- bind_rows(lapply(op_files, function(f) {
#     yr <- as.integer(str_extract(f, "\\d{4}"))        # <- the year, from the NAME
#     ...
#
# -- build_state_source_audit.R, build_state_source_pairwise_audit.R and
# build_cross_source_comparison.R. Two defects in five lines:
#
#   1. The glob let the files present decide the years analysed. On
#      2026-11-12 only the 2024 file was on the machine, so a five-year
#      series was published as one year and nothing failed. See
#      docs/state-source-audit-coverage-defect.md.
#   2. The year came from the FILENAME, which
#      R/lib/source_year.R::assert_source_year() refuses as proof by design.
#      A renamed file, or one written by a producer handed the wrong year,
#      would have been believed without question.
#
# Both are fixed here, once, rather than in three places that would drift:
# the window comes from config/state_source_audit_sources.csv and the year
# comes from CMS's own Program_Year column inside each file.
#
# ELIGIBILITY IS NOT THE SAME AS PRESENCE. Certified nurse-midwives only
# became reportable covered recipients under Open Payments in program year
# 2021. The 2015-2020 files exist and are readable, but hold 0-29 incidental
# rows each; they are declared `ineligible` in the manifest and are
# deliberately NOT in this series, which is the same omission the technical
# appendix already made in prose. A year excluded for ineligibility is a
# declared scientific decision; a year missing because nobody noticed is the
# defect above, and the two must never look alike.
# =============================================================================

#' Read the Open Payments state series over its declared window
#'
#' Resolves inputs through the declared-coverage contract instead of
#' `Sys.glob()`, and takes each row's year from the in-file `program_year`
#' column rather than from the filename. Fails a publication build when any
#' required declared year cannot be used, naming it.
#'
#' @param publication_mode [logical] stop when a required declared year
#'   cannot be used. TRUE for any run whose numbers will be published.
#' @return [list] `rows` (npi, year, state), `years` (the analysed window),
#'   `coverage_audit` (the full per-year verdict table).
#' @export
read_open_payments_state_series <- function(publication_mode = TRUE) {
  declared <- read_source_manifest() %>%
    dplyr::filter(.data$source_id == "open_payments")
  if (!nrow(declared)) {
    stop("read_open_payments_state_series(): no open_payments rows are ",
         "declared in config/state_source_audit_sources.csv", call. = FALSE)
  }
  coverage_audit <- validate_source_coverage(declared,
                                             publication_mode = publication_mode)
  usable <- resolve_source_inputs(coverage_audit, "open_payments")

  # ONE PASS PER FILE, WITH ITS LOSSES COUNTED. A row is dropped here for one
  # of three reasons, and they are not interchangeable: no npi, no parseable
  # year, or a year the declaration never asked for. Reading them into one
  # bind_rows() and filtering afterwards made all three look identical and
  # left none of them visible, so each file now reports what it read and what
  # it could not use.
  EMPTY_SERIES <- tibble::tibble(npi = character(0), year = integer(0),
                                 state = character(0))
  per_file <- lapply(seq_len(nrow(usable)), function(file_index) {
    annual_file <- usable$input_path[file_index]
    annual_rows <- readr::read_csv(
      annual_file, col_types = readr::cols(.default = "c"), progress = FALSE)
    if (nrow(annual_rows) && !"program_year" %in% names(annual_rows)) {
      # Unreachable while the manifest declares in_file_date -- the contract
      # fails first. Kept so that loosening the declaration can never
      # silently reintroduce the filename as the source of the year.
      stop(sprintf(paste0(
        "read_open_payments_state_series(): %s has no program_year column. ",
        "The year must come from inside the file; a four-digit number in ",
        "the filename is not proof. Regenerate with ",
        "extract_open_payments_address_history.R."), annual_file),
        call. = FALSE)
    }
    parsed <- if (!nrow(annual_rows)) EMPTY_SERIES else annual_rows %>%
      dplyr::transmute(
        npi = trimws(.data$npi),
        year = suppressWarnings(as.integer(.data$program_year)),
        state = clean_state(.data$recipient_state))
    unusable_npi <- is.na(parsed$npi) | !nzchar(parsed$npi)
    list(input_path = annual_file,
         declared_year = usable$program_year[file_index],
         n_read = nrow(annual_rows),
         n_year_unparseable = sum(is.na(parsed$year)),
         n_npi_missing = sum(unusable_npi),
         rows = parsed[!unusable_npi & !is.na(parsed$year), , drop = FALSE])
  })

  file_losses <- dplyr::bind_rows(lapply(per_file, function(one_file)
    tibble::tibble(input_path = one_file$input_path,
                   declared_year = one_file$declared_year,
                   n_read = one_file$n_read,
                   n_year_unparseable = one_file$n_year_unparseable,
                   n_npi_missing = one_file$n_npi_missing,
                   n_kept = nrow(one_file$rows))))

  # A PAYMENT ROW WITH AN UNPARSEABLE YEAR IS A PRODUCER DEFECT, NOT DATA.
  # CMS publishes Program_Year as a bare four-digit integer, so anything
  # as.integer() cannot read ("2,024", "PY2024", a shifted column) means the
  # file was written wrong. The old code let as.integer() return NA and the
  # trailing filter drop the row, which shrank the published series by
  # however many rows happened to be malformed while every year still
  # appeared in the window -- a partial loss the window check cannot see.
  year_defects <- dplyr::filter(file_losses, .data$n_year_unparseable > 0L)
  if (nrow(year_defects)) {
    stop(sprintf(paste0(
      "read_open_payments_state_series(): %d row(s) carry a program_year ",
      "that is not a four-digit year, so they would leave the series ",
      "without changing the declared window:\n  %s\n",
      "Regenerate with extract_open_payments_address_history.R."),
      sum(year_defects$n_year_unparseable),
      paste(sprintf("%s: %d of %d row(s)", year_defects$input_path,
                    year_defects$n_year_unparseable, year_defects$n_read),
            collapse = "\n  ")), call. = FALSE)
  }

  series_rows <- if (!length(per_file)) EMPTY_SERIES else
    dplyr::bind_rows(lapply(per_file, function(one_file) one_file$rows))

  analysed_years <- sort(unique(series_rows$year))
  declared_years <- sort(usable$program_year)

  # ZERO RECORDS IS NOT A CONTRADICTION. A declared year that is present,
  # complete and holds no qualifying cohort record contributes no rows and so
  # cannot appear among the analysed years. Comparing the analysed years to
  # the whole declared window therefore refused exactly the valid-absence
  # case the coverage contract exists to protect, and blamed it on the
  # file's contents disagreeing with its declaration. The window check now
  # expects rows only from years whose file actually had rows, and a year
  # that had rows but contributed none is still a defect.
  years_with_records <- sort(file_losses$declared_year[file_losses$n_read > 0L])
  years_empty <- sort(file_losses$declared_year[file_losses$n_read == 0L])

  undeclared_years <- setdiff(analysed_years, declared_years)
  if (length(undeclared_years)) {
    stop(sprintf(paste0(
      "read_open_payments_state_series(): the declared window is %s but rows ",
      "carry the undeclared year(s) %s. A file's contents disagree with its ",
      "declaration."),
      paste(declared_years, collapse = ", "),
      paste(undeclared_years, collapse = ", ")), call. = FALSE)
  }
  silent_years <- setdiff(years_with_records, analysed_years)
  if (length(silent_years)) {
    stop(sprintf(paste0(
      "read_open_payments_state_series(): year(s) %s have records but ",
      "contributed none to the series. A year whose file holds rows must ",
      "contribute them or fail; it may not quietly become an empty year."),
      paste(silent_years, collapse = ", ")), call. = FALSE)
  }

  if (length(years_empty)) {
    base::message(sprintf(paste0(
      "  open_payments: %s declared present and complete with zero ",
      "qualifying records -- valid evidence of absence, not a gap"),
      paste(years_empty, collapse = ", ")))
  }
  npi_losses <- dplyr::filter(file_losses, .data$n_npi_missing > 0L)
  if (nrow(npi_losses)) {
    # Reported rather than fatal: CMS does publish general-payment records
    # with no recipient NPI, and one cannot be matched to a midwife. The
    # count is printed so it is a number somebody can quote, never a
    # subtraction nobody can see.
    base::message(sprintf(
      "  open_payments: %d row(s) carry no npi and cannot be attributed: %s",
      sum(npi_losses$n_npi_missing),
      paste(sprintf("%d (%d)", npi_losses$declared_year,
                    npi_losses$n_npi_missing), collapse = ", ")))
  }

  base::message(sprintf(
    "  open_payments: %s rows across %d declared years (%s)",
    format(nrow(series_rows), big.mark = ","), length(declared_years),
    if (length(declared_years))
      paste(range(declared_years), collapse = "-") else "none"))

  list(rows = series_rows, years = analysed_years,
       declared_years = declared_years, years_empty = years_empty,
       file_losses = file_losses, coverage_audit = coverage_audit)
}
