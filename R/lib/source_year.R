# =============================================================================
# Proving what year a file's data is from (spec Workstream D)
# =============================================================================
# Several series in this project take their observation year from a filename
# or from a literal the caller passed in. Nothing checks that the bytes agree.
# A renamed, re-dated or wrongly-downloaded file is then misdated silently,
# and a misdated year is worse than a missing one: lead/lag against NPPES
# would report the source as systematically early or late, which is a
# publishable sentence and completely false.
#
# This is the one place that answers "is this file really from year Y?".
#
# IT RETURNS A STATUS, IT DOES NOT GUESS. Five levels, strongest first, and
# the level actually used is recorded so a reader can see how much the answer
# is worth:
#
#   in_file_date      a date or program-year column inside the data.
#                     Strongest: the bytes say so.
#   release_id        an authoritative release identifier in the path, via
#                     the existing parse_vintage(), which already refuses a
#                     bare YYYY for exactly the reason this file exists.
#   fingerprint       a previously validated sha256 for this (path, year).
#                     A row count ALONE is never enough -- two years of the
#                     same product have similar row counts, and a count
#                     cannot distinguish them. A count may corroborate a
#                     hash; it may not replace one.
#   unverified        no evidence available. An explicit status, never a
#                     silent pass.
#   refuted           evidence contradicts the expected year. Always an error
#                     unless the caller asks only to be told.
#
# MIXED YEARS ARE A FAILURE BY DEFAULT. A file that contains 2019 and 2020
# rows is refuted unless multiyear = TRUE, because the usual cause is two
# downloads concatenated or a year column that means something else.
#
# @family data-quality
# =============================================================================

if (!exists("parse_vintage", mode = "function")) {
  source(file.path("R", "lib", "source_vintage.R"))
}

#' Smallest and largest year that can plausibly be an observation year here
#'
#' NPPES enumeration began in 2005 and nothing in this project observes the
#' future. A parsed year outside this is a parsing failure, not a finding.
SOURCE_YEAR_MIN <- 2005L
SOURCE_YEAR_MAX <- as.integer(format(Sys.Date(), "%Y")) + 1L

#' Prove that a file's data is from the year it is claimed to be from
#'
#' @param path [character] one file. Must exist.
#' @param expected_year [integer] the year the caller believes it holds.
#' @param date_columns [character] candidate column names carrying a date or
#'   a program year, tried in order, matched case-insensitively. When none is
#'   present the function falls through to the release identifier.
#' @param fingerprint [character] a previously validated sha256 of this file,
#'   or NULL. Used only when neither a date column nor a release identifier is
#'   available.
#' @param multiyear [logical] TRUE when the source legitimately spans several
#'   years, which suppresses the mixed-year refusal. Default FALSE.
#' @param sample_rows [integer] rows to read when probing a date column.
#'   Reading the whole of a 600 MB CSV to learn its year is not necessary;
#'   reading only the head would miss a year change part-way through, so a
#'   head sample is combined with a tail sample.
#' @param strict [logical] TRUE (default) stops on a refuted year. FALSE
#'   returns the verdict so a caller can record and continue.
#' @return [list] `status` (one of "in_file_date", "release_id",
#'   "fingerprint", "unverified", "refuted"), `confidence`
#'   ("high"/"medium"/"low"/"none"), `method`, `observed_years` (integer),
#'   `expected_year`, `detail`, `path`.
#' @examples
#' f <- tempfile(fileext = ".csv")
#' utils::write.csv(data.frame(npi = "1", claim_month = "2019-04"), f,
#'                  row.names = FALSE)
#' assert_source_year(f, 2019L, date_columns = "claim_month")$status
#' #> "in_file_date"
assert_source_year <- function(path, expected_year,
                               date_columns = character(0),
                               fingerprint = NULL, multiyear = FALSE,
                               sample_rows = 50000L, strict = TRUE) {
  stopifnot(length(path) == 1L, file.exists(path))
  expected_year <- as.integer(expected_year)
  out <- function(status, confidence, method, years, detail) {
    v <- list(status = status, confidence = confidence, method = method,
              observed_years = years, expected_year = expected_year,
              detail = detail, path = path)
    if (isTRUE(strict) && identical(status, "refuted"))
      stop(sprintf("assert_source_year: %s -- %s", basename(path), detail),
           call. = FALSE)
    v
  }

  # ---- level 1: a date or program-year column inside the data -------------
  years <- source_year_from_columns(path, date_columns, sample_rows)
  if (length(years)) {
    # One rule, applied here and by any caller that discovered the years
    # some cheaper way. See assert_year_set().
    r <- assert_year_set(years, expected_year, multiyear = multiyear,
                         strict = FALSE, label = basename(path))
    return(out(r$status, r$confidence, "in_file_date", years, r$detail))
  }

  # ---- level 2: an authoritative release identifier in the path -----------
  # parse_vintage() refuses a bare YYYY on purpose, so a filename that merely
  # contains "2019" does NOT get us here. That refusal is the point.
  v <- suppressWarnings(parse_vintage(path))
  if (length(v) && !is.na(v[1])) {
    vy <- as.integer(format(v[1], "%Y"))
    if (!identical(vy, expected_year))
      return(out("refuted", "medium", "release_id", vy,
                 sprintf("release identifier in the path says %d, caller says %d",
                         vy, expected_year)))
    return(out("release_id", "medium", "release_id", vy,
               sprintf("release date %s parsed from the path",
                       format(v[1], "%Y-%m-%d"))))
  }

  # ---- level 3: a previously validated checksum ---------------------------
  if (!is.null(fingerprint) && nzchar(fingerprint)) {
    got <- digest::digest(path, algo = "sha256", file = TRUE)
    if (!identical(got, fingerprint))
      return(out("refuted", "medium", "fingerprint", NA_integer_,
                 sprintf("sha256 %s does not match the recorded %s",
                         substr(got, 1, 12), substr(fingerprint, 1, 12))))
    return(out("fingerprint", "medium", "fingerprint", expected_year,
               "sha256 matches a previously validated file for this year"))
  }

  out("unverified", "none", "none", NA_integer_,
      "no in-file date, no release identifier in the path, no fingerprint")
}

#' Apply the year-refusal rules to an ALREADY-OBSERVED set of years
#'
#' assert_source_year() reads a sample to discover the years in a file. That
#' is the wrong approach for a 7 GB CSV, where the scan has to happen anyway
#' inside the query that extracts the data: the engine can return
#' SELECT DISTINCT Program_Year far more cheaply than R can sample it, and
#' the answer is exact rather than sampled.
#'
#' So the rules live here and both entry points use them. One definition of
#' what counts as refuted, two ways of discovering the years.
#'
#' @param years [integer] the distinct years actually observed in the data.
#' @param expected_year [integer] what the caller believes it holds.
#' @param multiyear [logical] TRUE when the source legitimately spans years.
#' @param strict [logical] TRUE stops on refusal; FALSE returns the verdict.
#' @param label [character] what to name in an error message.
#' @return [list] same shape as `assert_source_year()`.
#' @examples
#' assert_year_set(2019L, 2019L)$status   # "in_file_date"
#' assert_year_set(c(2019L, 2020L), 2019L, strict = FALSE)$status  # "refuted"
assert_year_set <- function(years, expected_year, multiyear = FALSE,
                            strict = TRUE, label = "<year set>") {
  years <- sort(unique(as.integer(years[!is.na(years)])))
  expected_year <- as.integer(expected_year)
  out <- function(status, confidence, detail) {
    v <- list(status = status, confidence = confidence,
              method = "in_file_date", observed_years = years,
              expected_year = expected_year, detail = detail, path = label)
    if (isTRUE(strict) && identical(status, "refuted"))
      stop(sprintf("assert_year_set: %s -- %s", label, detail), call. = FALSE)
    v
  }
  if (!length(years))
    return(out("unverified", "none", "no years observed in the data"))
  bad <- years[years < SOURCE_YEAR_MIN | years > SOURCE_YEAR_MAX]
  if (length(bad))
    return(out("refuted", "high",
               sprintf("implausible year(s): %s",
                       paste(bad, collapse = ", "))))
  if (length(years) > 1L && !isTRUE(multiyear))
    return(out("refuted", "high",
               sprintf("data mixes years %s; pass multiyear = TRUE if expected",
                       paste(years, collapse = ", "))))
  if (!expected_year %in% years)
    return(out("refuted", "high",
               sprintf("data says %s, caller says %d",
                       paste(years, collapse = ", "), expected_year)))
  out("in_file_date", "high",
      "the data's own year field carries the expected year")
}

#' Years present in the first date-like column a file actually has
#'
#' Reads a head sample and a tail sample rather than the whole file. Head
#' alone would miss a file that changes year part-way through, which is the
#' concatenation case the mixed-year rule exists to catch.
#'
#' @inheritParams assert_source_year
#' @return [integer] distinct plausible years found, or integer(0) when no
#'   candidate column is present or nothing parses.
source_year_from_columns <- function(path, date_columns, sample_rows = 50000L) {
  if (!length(date_columns)) return(integer(0))
  hdr <- tryCatch(names(utils::read.csv(path, nrows = 1L, check.names = FALSE)),
                  error = function(e) character(0))
  if (!length(hdr)) return(integer(0))
  pick <- hdr[tolower(hdr) %in% tolower(date_columns)]
  if (!length(pick)) return(integer(0))
  col <- pick[1]
  grab <- function(skip) {
    tryCatch(utils::read.csv(path, nrows = sample_rows, skip = skip,
                             header = (skip == 0L), check.names = FALSE,
                             colClasses = "character"),
             error = function(e) NULL)
  }
  d <- grab(0L)
  if (is.null(d) || !col %in% names(d)) return(integer(0))
  vals <- as.character(d[[col]])
  n <- tryCatch(length(readr::read_lines(path, progress = FALSE)),
                error = function(e) NA_integer_)
  if (!is.na(n) && n > 2L * sample_rows) {
    tl <- grab(n - sample_rows)
    if (!is.null(tl) && ncol(tl) == length(hdr)) {
      names(tl) <- hdr
      vals <- c(vals, as.character(tl[[col]]))
    }
  }
  ys <- suppressWarnings(as.integer(substr(trimws(vals), 1, 4)))
  ys <- ys[!is.na(ys)]
  sort(unique(ys))
}
