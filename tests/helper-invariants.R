# =============================================================================
# helper-invariants.R -- semantic expectations, ported from ~/isochrones
# =============================================================================
# PORTED VERBATIM, then extended. The originals live in
# ~/isochrones/tests/testthat/helper-invariants.R and were written for the
# ABOG/NPPES pipeline. They are reused here rather than rewritten because the
# two repositories share their identifiers (NPI), their geography (county and
# tract GEOIDs) and their failure modes -- and because a second, subtly
# different implementation of the same assertion is exactly the defect H4
# exists to catch.
#
# DIVERGENCE FROM THE ORIGINAL, deliberate and the reason for this file:
#
#   expect_npi_valid() upstream checks only that an NPI is ten characters and
#   all digits. That accepts 1234567890, which is not a valid NPI. An NPI
#   carries a Luhn check digit over the payload "80840" + its first nine
#   digits, so a transposition or a single-digit typo is DETECTABLE, and this
#   pipeline joins on NPI everywhere. npi_luhn_valid() below implements the
#   real check; expect_npi_valid() now uses it. If this is ported back, that
#   change should go with it.
#
# Loaded explicitly by tests/test_invariants_midwifery.R -- this repository is
# not a package and has no tests/testthat/ auto-load.
# =============================================================================

#' Expect a vector has no missing values
#'
#' @param x A vector.
#' @param label Optional label for the expectation.
#' @return Invisible TRUE if expectation passes.
expect_no_missing <- function(x, label = NULL) {
  testthat::expect_false(
    any(is.na(x)),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected no NA values."
    )
  )
}

#' Expect a character identifier preserves leading zeros
#'
#' @param x A vector.
#' @param width Integer width required (e.g., 10 for NPI, 11 for tract GEOID).
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_character_id_width <- function(x, width, label = NULL) {
  testthat::expect_true(
    is.character(x),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected character vector."
    )
  )

  trimmed <- trimws(x)
  ok <- !is.na(trimmed) & nchar(trimmed) == width

  testthat::expect_true(
    all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected all non-NA values to have width ",
      width,
      "."
    )
  )
}

#' Expect an identifier is numeric-only characters
#'
#' @param x Character vector.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_id_numeric_chars <- function(x, label = NULL) {
  testthat::expect_true(
    is.character(x),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected character vector."
    )
  )

  ok <- is.na(x) | grepl("^[0-9]+$", x)

  testthat::expect_true(
all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected only digits (or NA)."
    )
  )
}

#' Expect a valid NPI (10-digit, numeric-only, character)
#'
#' @param npi Character vector of NPIs.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
#' Is an NPI arithmetically valid?
#'
#' An NPI is ten digits: nine of payload and a trailing Luhn check digit
#' computed over "80840" + those nine. Width and digit-ness alone accept
#' 1234567890, which no provider has. Checking the digit turns a silent wrong
#' join into a caught one, which matters in a pipeline keyed on NPI at every
#' stage.
#'
#' @param npi [character]: NPI as recorded.
#' @return [logical] one per element; NA in, NA out.
#' @examples
#' npi_luhn_valid("1234567893")   # TRUE  -- CMS's own worked example
#' npi_luhn_valid("1234567890")   # FALSE -- right shape, wrong check digit
npi_luhn_valid <- function(npi) {
  x <- trimws(as.character(npi))
  out <- rep(NA, length(x))
  shaped <- !is.na(x) & grepl("^[0-9]{10}$", x)
  out[!is.na(x) & !shaped] <- FALSE
  if (!any(shaped)) return(out)

  for (i in which(shaped)) {
    payload <- paste0("80840", substr(x[i], 1, 9))
    d <- rev(as.integer(strsplit(payload, "")[[1]]))
    # Double every other digit starting at the rightmost of the payload.
    idx <- seq_along(d)
    dbl <- d
    dbl[idx %% 2 == 1] <- d[idx %% 2 == 1] * 2
    dbl <- ifelse(dbl > 9, dbl - 9, dbl)
    # as.integer() on the arithmetic too: identical(3, 3L) is FALSE, and
    # comparing a double check digit to an integer one rejected every valid NPI.
    check <- as.integer((10 - (sum(dbl) %% 10)) %% 10)
    out[i] <- check == as.integer(substr(x[i], 10, 10))
  }
  out
}

#' Expect a valid NPI (10 digits AND a correct Luhn check digit)
#'
#' @param npi Character vector of NPIs.
#' @param label Optional label.
#' @param allow_na Logical; NA passes when TRUE.
#' @return Invisible TRUE if expectation passes.
expect_npi_valid <- function(npi, label = "NPI", allow_na = TRUE) {
  expect_character_id_width(x = npi, width = 10L, label = label)
  expect_id_numeric_chars(x = npi, label = label)

  ok <- npi_luhn_valid(npi)
  ok <- if (allow_na) is.na(ok) | ok else !is.na(ok) & ok
  bad <- utils::head(unique(as.character(npi)[!ok]), 5)
  testthat::expect_true(
    all(ok),
    label = paste0(label, ": expected a valid NPI check digit",
                   if (length(bad)) paste0(" (e.g. ", paste(bad, collapse = ", "), ")") else "",
                   ".")
  )
}

#' Expect a key is unique across columns
#'
#' @param table_like A data.frame or tibble.
#' @param key_cols Character vector of column names forming a key.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_unique_key <- function(table_like, key_cols, label = NULL) {
  if (!is.data.frame(table_like)) {
    stop("Expected a data.frame/tibble.")
  }

  missing_cols <- setdiff(key_cols, names(table_like))
  if (length(missing_cols) > 0) {
    stop(paste0("Missing key columns: ", paste(missing_cols, collapse = ", ")))
  }

  key_df <- table_like[key_cols]
  dup_flag <- duplicated(key_df)

  testthat::expect_false(
any(dup_flag),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected unique rows by key: ",
      paste(key_cols, collapse = ", "),
      ". Found ",
      sum(dup_flag),
      " duplicates."
    )
  )
}

#' Expect nonnegative numeric values
#'
#' @param x Numeric vector.
#' @param allow_na Logical; allow NA values.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_nonnegative <- function(x, allow_na = TRUE, label = NULL) {
  testthat::expect_true(
is.numeric(x),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected numeric vector."
    )
  )

  if (allow_na) {
    ok <- is.na(x) | x >= 0
  } else {
    ok <- !is.na(x) & x >= 0
  }

  testthat::expect_true(
all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected all values to be >= 0",
      if (allow_na) " (or NA)." else "."
    )
  )
}

#' Expect a percent is between 0 and 100
#'
#' @param x Numeric vector.
#' @param allow_na Logical; allow NA values.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_percent_0_100 <- function(x, allow_na = TRUE, label = NULL) {
  testthat::expect_true(
is.numeric(x),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected numeric vector."
    )
  )

  if (allow_na) {
    ok <- is.na(x) | (x >= 0 & x <= 100)
  } else {
    ok <- !is.na(x) & (x >= 0 & x <= 100)
  }

  testthat::expect_true(
all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected values in [0, 100]",
      if (allow_na) " (or NA)." else "."
    )
  )
}

#' Expect numerator is <= denominator
#'
#' @param numerator Numeric vector.
#' @param denominator Numeric vector.
#' @param allow_na Logical; allow NA values in either vector.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_numerator_le_denominator <- function(
  numerator,
  denominator,
  allow_na = TRUE,
  label = NULL
) {
  testthat::expect_true(is.numeric(numerator),
    label = "Expected numeric numerator."
  )
  testthat::expect_true(is.numeric(denominator),
    label = "Expected numeric denominator."
  )
  testthat::expect_equal(
length(numerator),
    length(denominator),
    label = "Expected equal lengths."
  )

  if (allow_na) {
    ok <- is.na(numerator) | is.na(denominator) | numerator <= denominator
  } else {
    ok <- !is.na(numerator) & !is.na(denominator) & numerator <= denominator
  }

  testthat::expect_true(
all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected numerator <= denominator",
      if (allow_na) " (or NA)." else "."
    )
  )
}

#' Expect dates are not in the future
#'
#' @param date_vec Date or POSIXct vector.
#' @param today Date used for comparison (defaults to Sys.Date().
#' @param allow_na Logical; allow NA dates.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_no_future_dates <- function(
  date_vec,
  today = base::Sys.Date(),
  allow_na = TRUE,
  label = NULL
) {
  ok_type <- inherits(date_vec, "Date") || inherits(date_vec, "POSIXct") ||
    inherits(date_vec, "POSIXlt")

  testthat::expect_true(
ok_type,
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected Date/POSIXct/POSIXlt."
    )
  )

  as_date <- as.Date(date_vec)

  if (allow_na) {
    ok <- is.na(as_date) | as_date <= today
  } else {
    ok <- !is.na(as_date) & as_date <= today
  }

  testthat::expect_true(
all(ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected no future dates relative to ",
      format(today),
      "."
    )
  )
}

#' Expect monotone accessibility across increasing time thresholds
#'
#' Use when you have access indicators/rates for multiple thresholds
#' (e.g., access_30, access_60, access_120) that should be nondecreasing.
#'
#' @param table_like data.frame/tibble.
#' @param cols Character vector ordered from smallest to largest threshold.
#' @param allow_na Logical; allow NA rows.
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_monotone_nondecreasing <- function(
  table_like,
  cols,
  allow_na = TRUE,
  label = NULL
) {
  testthat::expect_true(is.data.frame(table_like),
    label = "Expected a data.frame/tibble."
  )

  missing_cols <- setdiff(cols, names(table_like))
  testthat::expect_true(
    length(missing_cols) == 0,
    label = paste0("Missing columns: ", paste(missing_cols, collapse = ", "))
  )

  # Extract columns as data frame first, then convert to matrix
  # This handles sf objects and ensures we only get the requested columns
  df_subset <- as.data.frame(table_like)[cols]
  mat <- as.matrix(df_subset)

  testthat::expect_true(is.numeric(mat),
    label = "Expected numeric columns for monotonicity check."
  )

  row_ok <- apply(
    mat,
    1,
    function(row_vals) {
      if (allow_na && any(is.na(row_vals))) {
        return(TRUE)
      }
      all(diff(row_vals) >= 0)
    }
  )

  testthat::expect_true(
all(row_ok),
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected nondecreasing across: ",
      paste(cols, collapse = " <= "),
      "."
    )
  )
}

#' Expect schema matches expected column names and types
#'
#' @param table_like data.frame/tibble.
#' @param expected_names Character vector of expected column names (ordered).
#' @param expected_types Named character vector: names are columns,
#'   values are one of: "character", "numeric", "integer", "logical",
#'   "Date", "POSIXct".
#' @param strict_names Logical; if TRUE, names must match exactly in order.
#' @return Invisible TRUE if expectation passes.
expect_schema <- function(
  table_like,
  expected_names = NULL,
  expected_types = NULL,
  strict_names = FALSE
) {
  testthat::expect_true(is.data.frame(table_like),
    label = "Expected a data.frame/tibble."
  )

  if (!is.null(expected_names)) {
    if (strict_names) {
      testthat::expect_identical(
        names(table_like),
        expected_names,
        label = "Column names (and order) did not match expected."
      )
    } else {
      testthat::expect_true(
        all(expected_names %in% names(table_like)),
        label = paste0(
          "Missing expected columns: ",
          paste(setdiff(expected_names, names(table_like)), collapse = ", ")
        )
      )
    }
  }

  if (!is.null(expected_types)) {
    testthat::expect_true(
      is.character(expected_types) && !is.null(names(expected_types)),
      label = "expected_types must be a named character vector."
    )

    for (col_nm in names(expected_types)) {
      testthat::expect_true(
        col_nm %in% names(table_like),
        label = paste0("Expected column not found: ", col_nm)
      )

      expected <- expected_types[[col_nm]]
      col_val <- table_like[[col_nm]]

      ok <- switch(
        expected,
        character = is.character(col_val),
        numeric = is.numeric(col_val),
        integer = is.integer(col_val),
        logical = is.logical(col_val),
        Date = inherits(col_val, "Date"),
        POSIXct = inherits(col_val, "POSIXct"),
        FALSE
      )

      testthat::expect_true(
    ok,
        label = paste0(
          "Type mismatch for '",
          col_nm,
          "'. Expected ",
          expected,
          ". Got ",
          paste(class(col_val), collapse = "/"),
          "."
        )
      )
    }
  }

  invisible(TRUE)
}

#' Expect a transformation has an expected row-count direction
#'
#' @param before Integer rows before.
#' @param after Integer rows after.
#' @param direction One of: "decrease_or_equal", "increase_or_equal",
#'   "equal", "decrease", "increase".
#' @param label Optional label.
#' @return Invisible TRUE if expectation passes.
expect_rowcount_direction <- function(
  before,
  after,
  direction = c(
    "decrease_or_equal",
    "increase_or_equal",
    "equal",
    "decrease",
    "increase"
  ),
  label = NULL
) {
  direction <- match.arg(direction)
  testthat::expect_true(is.numeric(before) && length(before) == 1)
  testthat::expect_true(is.numeric(after) && length(after) == 1)

  ok <- switch(
    direction,
    decrease_or_equal = after <= before,
    increase_or_equal = after >= before,
    equal = after == before,
    decrease = after < before,
    increase = after > before
  )

  testthat::expect_true(
ok,
    label = paste0(
      if (!is.null(label)) paste0(label, ": ") else "",
      "Expected row-count direction '",
      direction,
      "' but before=",
      before,
      ", after=",
      after,
      "."
    )
  )
}
