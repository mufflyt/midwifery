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

  series_rows <- dplyr::bind_rows(lapply(usable$input_path, function(annual_file) {
    annual_rows <- readr::read_csv(
      annual_file, col_types = readr::cols(.default = "c"), progress = FALSE)
    if (!nrow(annual_rows)) return(NULL)
    if (!"program_year" %in% names(annual_rows)) {
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
    annual_rows %>%
      dplyr::transmute(npi = trimws(.data$npi),
                       year = as.integer(.data$program_year),
                       state = clean_state(.data$recipient_state))
  })) %>%
    dplyr::filter(!is.na(.data$npi), nzchar(.data$npi), !is.na(.data$year))

  analysed_years <- sort(unique(series_rows$year))
  declared_years <- sort(usable$program_year)

  # The years the rows actually carry must be the years that were declared.
  # If they diverge, a file's contents disagree with its declaration and the
  # series is not the one anybody asked for.
  if (!identical(as.integer(analysed_years), as.integer(declared_years))) {
    stop(sprintf(paste0(
      "read_open_payments_state_series(): the declared window is %s but the ",
      "rows carry %s. A file's contents disagree with its declaration."),
      paste(declared_years, collapse = ", "),
      paste(analysed_years, collapse = ", ")), call. = FALSE)
  }

  base::message(sprintf(
    "  open_payments: %s rows across %d declared years (%s)",
    format(nrow(series_rows), big.mark = ","), length(analysed_years),
    paste(range(analysed_years), collapse = "-")))

  list(rows = series_rows, years = analysed_years,
       coverage_audit = coverage_audit)
}
