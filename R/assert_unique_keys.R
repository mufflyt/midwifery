#' @title Key Uniqueness Assertion
#'
#' @description
#' `assert_unique_keys()`, on its own, because 17 scripts were sourcing all
#' 1,892 lines of `R/join_safety.R` to reach it.
#'
#' @details
#' WHY THIS FILE EXISTS. The 2026-11-20 complexity audit measured the five-stage
#' pipeline's `source()` closure and found `check_npi_deactivation.R` -- 65 lines
#' -- pulling 2,195 lines (`R/join_safety.R` plus the `R/safe_divide.R` it
#' sources) to call exactly one function from them, and then doing its own join
#' bare. Sixteen other scripts source the module with the same comment beside
#' it: `# assert_unique_keys(dedupe = TRUE)`. The function calls nothing else in
#' that module, so it was a file move, not a rewrite.
#'
#' `R/join_safety.R` sources this file, so every one of those 17 call sites
#' keeps working unchanged; a script that needs only the assertion can now
#' source this file instead.
#'
#' Defined here and ONLY here: `tests/ci_hygiene.R`'s H4 gate fails on a
#' top-level function defined in two tracked files, which is the right rule --
#' two copies of a key-uniqueness assertion is exactly how a cohort count
#' diverges.
#'
#' @section Dependencies:
#' `checkmate` and `dplyr` (including the `%>%` pipe dplyr re-exports), both
#' assumed loaded by the caller the same way `R/join_safety.R` assumes them.
#' No `library()` call here: a sourced file must not pollute the caller's
#' search path.
#'
#' @family join-safety
#'
#' @author Tyler Muffly, MD + Claude Code
#' @name assert_unique_keys_module
NULL

if (!requireNamespace("checkmate", quietly = TRUE)) {
  stop("[assert_unique_keys] Package 'checkmate' is required but not installed.",
       call. = FALSE)
}

#' Assert that Join Keys Are Unique
#'
#' @title Key Uniqueness Assertion
#'
#' @description
#' Checks that specified key columns contain no duplicates. Can either
#' deduplicate
#' (keeping first) or raise an informative error with sample duplicates.
#'
#' @details
#' **Bug fixes incorporated:**
#' \itemize{
#'   \item Bug #36 (2026-01-27): Error message now shows sample duplicate key
#' values.
#'   \item Bug #135 (2026-01-28): Error message reports total rows affected by
#' duplicates.
#'   \item Bug #163 (2026-01-28): Added \code{dedupe=TRUE} option to silently
#' remove duplicates.
#' }
#'
#' @param .data    \code{[data.frame]} Input data frame to check.
#' @param key_cols \code{[character]} Vector of column names forming the key.
#' @param dedupe   \code{[logical(1)]} If \code{TRUE}, remove duplicates instead
#'   of erroring.
#'
#' @return The input data frame (possibly deduplicated). Throws an error if
#'   duplicates found.
#'
#' @section Pipeline Position:
#' Called by \code{safe_left_join()} and \code{safe_inner_join()} before the
#' underlying join when \code{expect_unique_right = TRUE} (default). Also
#' available directly for pre-join validation of lookup tables.
#'
#' @section Algorithm:
#' Groups by \code{key_cols} with \code{dplyr::count()} and filters for
#' groups with count > 1. When \code{dedupe = TRUE} keeps only the first
#' row per group via \code{dplyr::distinct()}. Error messages include up to 3
#' sample duplicate key values for rapid debugging (Bug #36 fix).
#'
#' @seealso \code{\link{safe_left_join}} and \code{\link{safe_inner_join}},
#'   which call this internally; \code{\link{check_join_keys}} for a
#'   lighter-weight existence check without deduplication.
#'
#' @concept join-safety
#' @concept data-integrity
#'
#' @examples
#' \dontrun{
#' # Strict check — will stop() if any NPI appears more than once
#' assert_unique_keys(demographics_lookup, key_cols = "npi",
#'                    label = "census_demographics")
#'
#' # Lenient: deduplicate instead of erroring
#' clean_lookup <- assert_unique_keys(demographics_lookup, key_cols = "npi",
#'                                    label = "census_demographics", dedupe =
#' TRUE)
#' }
#'
#' @family join-safety
#' @export
assert_unique_keys <- function(.data, key_cols, label = "table", dedupe = FALSE) {
  checkmate::assert_data_frame(.data)
  checkmate::assert_character(key_cols, min.len = 1)
  checkmate::assert_string(label)
  checkmate::assert_flag(dedupe)

  n <- nrow(.data)
  d <- .data %>%
    dplyr::count(dplyr::across(dplyr::all_of(key_cols)), name = ".dups") %>%
    dplyr::filter(.dups > 1L)

  if (nrow(d) > 0) {
    # BUG FIX (2026-01-28): Bug 163 - Support dedupe option to remove duplicates
    if (isTRUE(dedupe)) {
      # CYCLE 2. dedupe used to mean "keep whichever row sorted first", which
      # resolves a DATA CONFLICT by file order inside a helper named
      # assert_unique_keys. Two rows for one certification_number disagreeing
      # on practice_state would silently publish one of the two states, and
      # which one depended on how the input happened to be sorted.
      #
      # Identical duplicate rows carry no conflict and still collapse. Rows
      # that share a key but disagree elsewhere are a question for a human, so
      # they stop the run and name the offending key and column.
      dup_keys <- .data %>%
        dplyr::semi_join(dplyr::select(d, dplyr::all_of(key_cols)), by = key_cols)
      conflicting <- dup_keys %>%
        dplyr::group_by(dplyr::across(dplyr::all_of(key_cols))) %>%
        dplyr::filter(dplyr::n_distinct(dplyr::pick(dplyr::everything())) > 1L) %>%
        dplyr::ungroup()
      if (nrow(conflicting) > 0) {
        varying <- setdiff(names(conflicting), key_cols)
        varying <- varying[vapply(varying, function(v)
          dplyr::n_distinct(conflicting[[v]]) > 1L, logical(1))]
        stop(sprintf(paste0(
          "assert_unique_keys(dedupe = TRUE) on %s: %d rows share a key but ",
          "DISAGREE on %s. Deduplication would resolve that by row order. ",
          "Reconcile the source, or drop the conflicting column before ",
          "deduplicating.\n  key(s): %s\n  disagreeing column(s): %s"),
          label, nrow(conflicting),
          if (length(varying)) "other columns" else "row content",
          paste(key_cols, collapse = ", "),
          paste(utils::head(varying, 5), collapse = ", ")), call. = FALSE)
      }
      out <- .data %>%
        dplyr::distinct(dplyr::across(dplyr::all_of(key_cols)), .keep_all = TRUE)
      message(sprintf(
        "assert_unique_keys: dedupe=TRUE removed %d duplicate rows from %s",
        n - nrow(out), label
      ))
      return(out)
    }

    # BUG FIX (2026-01-27): Bug 36 - Show sample duplicate values in error.
    # Previously just said "found N duplicated key(s)" with no examples,
    # making it impossible to debug which rows caused the problem.
    # BUG FIX (2026-01-28): Bug 135 - Show total rows with duplicates
    total_dup_rows <- sum(d$.dups)
    sample_dups <- head(d, 3)
    sample_strs <- apply(sample_dups[, key_cols, drop = FALSE], 1, function(row) {
      paste(key_cols, "=", row, collapse = ", ")
    })
    stop(sprintf(
      "❌ %s expected unique keys [%s] but found %d duplicated key group(s) affecting %d rows. Samples: %s",
      label, paste(key_cols, collapse = ", "), nrow(d), total_dup_rows,
      paste(sample_strs, collapse = "; ")
    ))
  }
  invisible(.data)
}
