# =============================================================================
# helper-schema-validation.R -- TRANSLATED, not copied, from ~/isochrones
# =============================================================================
# The upstream file (~/isochrones/tests/testthat/helper-schema-validation.R) is
# built for a DuckDB warehouse: every function takes a DBI connection and runs
# SQL, and it opens with connect_production_db(). Copying it here verbatim would
# have added DBI and duckdb to a CI job whose entire premise is that it installs
# almost nothing -- to obtain functions that cannot be called on anything this
# repository publishes, because midwifery's artifacts are CSVs on disk.
#
# So the four validators are TRANSLATED to data frames, keeping the names, the
# argument order after the connection, and the return shape (a list with `ok`
# and a message), so a reader who knows one knows the other:
#
#   upstream                                    here
#   validate_domain_invariant(con, query, ...)  (data, predicate, ...)
#   validate_cardinality(con, schema, table,..) (data, key_cols, ...)
#   validate_statistical_property(con, query,..)(values, min, max, ...)
#   validate_temporal_consistency(con, query,..)(earlier, later, ...)
#
# The SQL "return 0 rows if the invariant holds" convention becomes "a predicate
# that must be TRUE for every row", which is the same idea with the database
# taken out.
#
# Base R. No DBI, no duckdb, no connection.
# =============================================================================

#' Validate a domain invariant over a data frame
#'
#' Upstream runs a query that must return zero rows. Here you supply a
#' predicate that must hold for every row; the rows where it fails are the
#' rows the query would have returned.
#'
#' @param data [data.frame]
#' @param predicate [function] taking `data`, returning a logical vector.
#' @param description [character(1)] human-readable statement of the invariant.
#' @param allow_na [logical(1)] treat NA as passing (default TRUE) -- missing is
#'   not a violation unless you say it is.
#' @return [list] `ok`, `n_violations`, `description`, `violating_rows`.
validate_domain_invariant <- function(data, predicate, description,
                                      allow_na = TRUE) {
  stopifnot(is.data.frame(data), is.function(predicate))
  held <- predicate(data)
  if (!is.logical(held)) {
    stop("predicate must return a logical vector; got ", class(held)[1])
  }
  if (length(held) != nrow(data)) {
    stop("predicate returned ", length(held), " values for ", nrow(data), " rows")
  }
  held <- if (allow_na) is.na(held) | held else !is.na(held) & held
  bad <- which(!held)
  list(ok = length(bad) == 0L,
       n_violations = length(bad),
       description = description,
       violating_rows = utils::head(bad, 20))
}

#' Validate the cardinality of a key
#'
#' @param data [data.frame]
#' @param key_cols [character] columns forming the key.
#' @param expected_cardinality [character(1)] "unique" or "non_unique".
#' @return [list] `ok`, `n_duplicate_keys`, `examples`.
validate_cardinality <- function(data, key_cols,
                                 expected_cardinality = c("unique", "non_unique")) {
  expected_cardinality <- match.arg(expected_cardinality)
  stopifnot(is.data.frame(data))
  missing_cols <- setdiff(key_cols, names(data))
  if (length(missing_cols)) {
    stop("key column(s) absent: ", paste(missing_cols, collapse = ", "))
  }

  k <- do.call(paste, c(data[key_cols], sep = "\r"))
  dups <- unique(k[duplicated(k)])
  n <- length(dups)

  ok <- if (expected_cardinality == "unique") n == 0L else n > 0L
  list(ok = ok,
       n_duplicate_keys = n,
       examples = gsub("\r", " | ", utils::head(dups, 5)))
}

#' Validate that a statistic falls inside a plausible range
#'
#' The upstream version runs an aggregate query and bounds the scalar it
#' returns. Here you pass the values. Bounds are INCLUSIVE, and NA values are
#' dropped rather than failing -- a missing rate is a coverage question, not a
#' plausibility one.
#'
#' @param values [numeric]
#' @param min_value,max_value [numeric(1)] inclusive bounds.
#' @param description [character(1)]
#' @param statistic [function] summary applied to `values` (default `max`).
#' @return [list] `ok`, `value`, `description`.
validate_statistical_property <- function(values, min_value, max_value,
                                          description, statistic = max) {
  v <- suppressWarnings(as.numeric(values))
  v <- v[is.finite(v)]
  if (!length(v)) {
    return(list(ok = TRUE, value = NA_real_,
                description = paste0(description, " (no finite values; not checked)")))
  }
  s <- statistic(v)
  list(ok = isTRUE(s >= min_value && s <= max_value),
       value = s,
       description = description)
}

#' Validate that one date never precedes another
#'
#' @param earlier,later [Date|character] vectors of equal length.
#' @param description [character(1)]
#' @param allow_na [logical(1)]
#' @param format [character(1)|NULL] strptime format WITHOUT a day component,
#'   e.g. "%m/%Y". A day of 01 is prepended. NULL uses as.Date()'s own parsing.
#' @return [list] `ok`, `n_violations`, `description`.
validate_temporal_consistency <- function(earlier, later, description,
                                          allow_na = TRUE, format = NULL) {
  if (length(earlier) != length(later)) {
    stop("earlier and later must be the same length")
  }
  # `format` exists because AMCB publishes MM/YYYY, which as.Date() rejects
  # outright rather than guessing. Defaulting to a guess would be worse: a
  # silently unparsed column compares as all-NA and the invariant passes
  # vacuously, which is the shape of "verification that verified nothing".
  as_d <- function(v) if (is.null(format)) suppressWarnings(as.Date(v)) else
    suppressWarnings(as.Date(paste0("01/", v), format = paste0("%d/", format)))
  a <- as_d(earlier)
  b <- as_d(later)
  if (all(is.na(a)) || all(is.na(b))) {
    stop("no date parsed; pass format= (e.g. \"%m/%Y\") rather than comparing NAs")
  }
  held <- a <= b
  held <- if (allow_na) is.na(held) | held else !is.na(held) & held
  list(ok = all(held),
       n_violations = sum(!held),
       description = description)
}

#' Turn any of the above into a testthat expectation
#'
#' Keeps the validators usable from pipeline code (where a list is what you
#' want) and from tests (where a failure should be an expectation), without
#' writing each assertion twice.
#'
#' @param result [list] the return value of a validate_* function.
#' @return invisible(TRUE), or fails the enclosing test.
expect_validation_ok <- function(result) {
  # Not `%||%`: three definitions of it already exist at top level and a
  # fourth would trip H4, which is the check that made this file share the
  # reporter in the first place.
  detail <- if (is.null(result$description)) "validation" else result$description
  extra <- if (!is.null(result$n_violations) && result$n_violations > 0) {
    sprintf(" -- %d violation(s), e.g. rows %s", result$n_violations,
            paste(result$violating_rows, collapse = ", "))
  } else if (!is.null(result$n_duplicate_keys) && result$n_duplicate_keys > 0) {
    sprintf(" -- %d duplicate key(s), e.g. %s", result$n_duplicate_keys,
            paste(result$examples, collapse = "; "))
  } else if (!is.null(result$value) && !is.na(result$value)) {
    sprintf(" -- observed %s", format(result$value))
  } else ""
  testthat::expect_true(isTRUE(result$ok), label = paste0(detail, extra))
}
