# =============================================================================
# helper-contracts.R -- data contracts, ported from ~/isochrones
# =============================================================================
# PORTED VERBATIM from ~/isochrones/tests/testthat/helper-contracts.R, then
# extended with contract_npi_valid(). These are stop()-on-violation guards
# rather than testthat expectations, so they are usable from pipeline code as
# well as from tests -- which is the point: a contract that only runs under
# testthat does not protect a production run.
#
# Note contract_npi_unique()'s reference to "Hall of Shame Incident #1" -- that
# is isochrones' Hall of Shame, where duplicate NPIs caused a 5-10% physician
# overcount. midwifery's own entry #4 ("Counted 88 physicians twice") is the
# same defect independently rediscovered, which is the argument for sharing
# these rather than writing them twice.
#
# ADDED HERE: contract_npi_valid(), which checks the Luhn check digit via
# npi_luhn_valid() in helper-invariants.R. Uniqueness and validity are
# different properties -- a file can hold 16,892 unique NPIs of which several
# are typos, and only the check digit finds those.
# =============================================================================

#' Simple, reusable "data contract" guards for schema/domains/joins.

#' Require specific columns exist in a data frame
contract_require_cols <- function(x, cols) {
  miss <- setdiff(cols, colnames(x))
  if (length(miss) > 0) stop("Missing cols: ", paste(miss, collapse = ", "))
  invisible(TRUE)
}

#' Enforce data types for specific columns
#' @param x data frame
#' @param spec named list like list(npi="character", year="integer")
contract_types <- function(x, spec) {
  for (nm in names(spec)) {
    want <- spec[[nm]]
    got  <- class(x[[nm]])[1]
    if (want == "integer" && is.double(x[[nm]]) &&
        all(x[[nm]] == as.integer(x[[nm]]), na.rm = TRUE)) {
      next
    }
    if (want != got) stop("Type mismatch for ", nm, ": got ", got,
                          " want ", want)
  }
  invisible(TRUE)
}

#' Enforce categorical domain (allow-list)
contract_domain <- function(v, allowed) {
  bad <- setdiff(unique(v[!is.na(v)]), allowed)
  if (length(bad) > 0) stop("Disallowed values: ", paste(bad, collapse = ", "))
  invisible(TRUE)
}

#' Assert 1:1 join keys (no fan-out)
#' @param a left data frame
#' @param b right data frame
#' @param by character vector of key column names
contract_join_11 <- function(a, b, by) {
  ka <- a[, by, drop = FALSE]
  kb <- b[, by, drop = FALSE]
  if (anyDuplicated(ka) > 0) stop("Left keys not unique for join: ", paste(by, collapse = ","))
  if (anyDuplicated(kb) > 0) stop("Right keys not unique for join: ", paste(by, collapse = ","))
  invisible(TRUE)
}

#' Assert NPI uniqueness (Bug #16 prevention)
#' @description Verifies that all NPIs in a dataset are unique.
#'   Duplicate NPIs indicate incorrect physician matching and can lead to
#'   5-10% overestimation of physician counts (Hall of Shame Incident #1).
#' @param df data frame containing NPI column
#' @param npi_col character, name of NPI column (default: "npi")
#' @param context character, description of data source for error message
#' @param allow_na logical, whether to allow NA values (default: TRUE)
#' @return invisible(TRUE) if all NPIs are unique, otherwise stops with error
#' @examples
#' \dontrun{
#' # Basic usage
#' contract_npi_unique(physician_data, context = "geocoded physicians")
#'
#' # With custom column name
#' contract_npi_unique(df, npi_col = "provider_npi", context = "Medicare data")
#'
#' # Disallow NA values
#' contract_npi_unique(df, allow_na = FALSE, context = "final cohort")
#' }
contract_npi_unique <- function(df,
                                npi_col = "npi",
                                context = "unknown",
                                allow_na = TRUE) {
  # Validate inputs
  if (!npi_col %in% names(df)) {
    stop(sprintf("NPI column '%s' not found in data frame (context: %s)",
                 npi_col, context))
  }

  # Extract NPI column
  npi_values <- df[[npi_col]]

  # Check for NA values if not allowed
  if (!allow_na) {
    na_count <- sum(is.na(npi_values))
    if (na_count > 0) {
      stop(sprintf("BUG #16: Found %d NA values in NPI column (context: %s, allow_na=FALSE)",
                   na_count, context))
    }
  }

  # Filter to non-NA, non-empty NPIs
  valid_npis <- npi_values[!is.na(npi_values) & npi_values != ""]

  if (length(valid_npis) == 0) {
    warning(sprintf("No valid NPIs found in dataset (context: %s)", context))
    return(invisible(TRUE))
  }

  # Check for duplicates
  duplicate_npis <- valid_npis[duplicated(valid_npis)]
  n_duplicates <- length(unique(duplicate_npis))

  if (n_duplicates > 0) {
    # Count how many times each duplicate appears
    dup_counts <- table(valid_npis[valid_npis %in% duplicate_npis])
    top_dupes <- head(sort(dup_counts, decreasing = TRUE), 5)

    error_msg <- sprintf(
      paste0("BUG #16: Duplicate NPIs detected (Hall of Shame Incident #1)\n",
             "  Context: %s\n",
             "  Unique duplicate NPIs: %d\n",
             "  Total duplicate instances: %d\n",
             "  Duplicate rate: %.2f%%\n",
             "  Top duplicates:\n%s"),
      context,
      n_duplicates,
      sum(dup_counts - 1),
      100 * n_duplicates / length(valid_npis),
      paste(sprintf("    - NPI %s: %d occurrences",
                    names(top_dupes), top_dupes), collapse = "\n")
    )

    stop(error_msg, call. = FALSE)
  }

  invisible(TRUE)
}

#' Assert every NPI is arithmetically valid, not merely unique
#'
#' Requires npi_luhn_valid() from helper-invariants.R. Uniqueness says no two
#' rows claim the same provider; validity says the provider can exist. A
#' transposed digit produces a unique, well-shaped, entirely wrong NPI, and
#' only the check digit catches it.
#'
#' @param df data frame containing an NPI column.
#' @param npi_col character, name of the NPI column (default: "npi").
#' @param context character, description used in the error message.
#' @param allow_na logical, whether NA passes (default: TRUE).
#' @return invisible(TRUE), or stops.
contract_npi_valid <- function(df,
                               npi_col = "npi",
                               context = "unknown",
                               allow_na = TRUE) {
  if (!npi_col %in% names(df)) {
    stop(sprintf("NPI column '%s' not found in data frame (context: %s)",
                 npi_col, context))
  }
  if (!exists("npi_luhn_valid", mode = "function")) {
    stop("contract_npi_valid() needs npi_luhn_valid(); source helper-invariants.R first.")
  }

  v <- df[[npi_col]]
  v <- v[!is.na(v) & nzchar(trimws(as.character(v))) & trimws(as.character(v)) != "NA"]
  if (length(v) == 0) {
    warning(sprintf("No populated NPIs to validate (context: %s)", context))
    return(invisible(TRUE))
  }

  ok <- npi_luhn_valid(v)
  ok <- if (allow_na) is.na(ok) | ok else !is.na(ok) & ok
  bad <- unique(as.character(v)[!ok])

  if (length(bad) > 0) {
    stop(sprintf(
      paste0("Invalid NPI check digit(s) detected\n",
             "  Context: %s\n",
             "  Distinct invalid NPIs: %d of %d checked (%.3f%%)\n",
             "  Examples: %s"),
      context, length(bad), length(v), 100 * length(bad) / length(v),
      paste(utils::head(bad, 5), collapse = ", ")),
      call. = FALSE)
  }
  invisible(TRUE)
}
