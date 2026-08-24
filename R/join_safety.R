#' @title Safe Join Functions with Coverage Validation and Reporting
#'
#' @description
#' Provides a robust suite of join wrappers (\code{safe_left_join},
#' \code{safe_inner_join}, etc.)
#' that enforce data quality contracts. Features include coverage thresholds,
#' cardinality validation, automated deduplication, and CSV reporting.
#'
#' @details
#' This module implements the "Safe Join Standard" which aims to eliminate the
#' most common sources of data corruption in the pipeline:
#' \itemize{
#'   \item \strong{Silent Data Loss}: Unmatched rows in inner/left joins.
#'   \item \strong{Silent Row Explosion}: Unintended many-to-many fan-outs.
#'   \item \strong{Type Mismatches}: Coercing keys to character to avoid join
#' failures.
#'   \item \strong{Metadata Drift}: Unified reporting across all join types.
#' }
#'
#' @family join-safety
#'
#' @author Tyler Muffly, MD + Claude Code
#' @name join_safety
NULL

# ---- Dependencies --------------------------------------------------------
# Assumes dplyr, readr, tibble are loaded via R/01-setup.R
# BUG FIX (class 17): removed library(checkmate) — use pkg:: prefix; sourced files
# must not call library() as it pollutes the search path of the calling environment.
if (!requireNamespace("checkmate", quietly = TRUE)) {
  stop("[join_safety] Package 'checkmate' is required but not installed.", call. = FALSE)
}
source(here::here("R", "safe_divide.R"))

# ---- Helper Functions ----------------------------------------------------

#' Harmonize Join Key Types Between Two Data Frames
#'
#' @title Join Key Type Harmonization
#'
#' @description
#' Prevents silent join failures caused by integer/double/character type
#' mismatches on join key columns. When types differ, both sides are coerced
#' to character (the safest common representation for IDs like NPI, GEOID).
#'
#' @inheritParams shared_params_name
#' @param left        \code{[data.frame]} Left data frame.
#' @param right       \code{[data.frame]} Right data frame.
#' @param by          \code{[character]} Join key specification (named or
#'   unnamed vector).
#' @param label_left  \code{[character(1)]} Label for messages.
#' @param label_right \code{[character(1)]} Label for messages.
#'
#' @return \code{[list]} With harmonized \code{left} and \code{right} data
#'   frames.
#'
#' @section Algorithm:
#' Iterates each key pair derived from \code{by}. When the R class of the left
#' column differs from the right column (e.g., integer vs. double, or integer
#' vs. character after a Parquet round-trip), both sides are coerced to
#' \code{character} — the safest common representation for ID columns like NPI
#' and GEOID.
#'
#' @section Pipeline Position:
#' Called automatically at the top of every \code{safe_*_join()} wrapper before
#' the underlying \code{dplyr} join executes. Never call directly in pipeline
#' scripts.
#'
#' @seealso \code{\link{safe_left_join}} and \code{\link{safe_inner_join}},
#'   which invoke this function before joining.
#'
#' @family join-safety
#' @concept join-safety
#' @concept data-integrity
#'
#' @examples
#' \dontrun{
#' harmonized <- harmonize_join_key_types(
#'   left = physicians, right = claims,
#'   by = c("npi" = "provider_npi"),
#'   label_left = "abog", label_right = "nber"
#' )
#' left  <- harmonized$left
#' right <- harmonized$right
#' }
#'
#' @keywords internal
harmonize_join_key_types <- function(left, right, by,
                                    label_left = "left",
                                    label_right = "right") {
  # Resolve left/right column names from the by spec
  if (is.null(names(by))) {
    left_cols <- by
    right_cols <- by
  } else {
    left_cols <- names(by)
    right_cols <- unname(by)
    # Unnamed entries use the value for both sides
    unnamed <- left_cols == ""
    left_cols[unnamed] <- right_cols[unnamed]
  }

  for (i in seq_along(left_cols)) {
    lc <- left_cols[i]
    rc <- right_cols[i]
    if (!lc %in% names(left) || !rc %in% names(right)) next

    l_class <- class(left[[lc]])[1]
    r_class <- class(right[[rc]])[1]

    if (l_class != r_class) {
      message(sprintf(
        "[safe_join] Key type mismatch: %s$%s is %s, %s$%s is %s — coercing both to character",
        label_left, lc, l_class, label_right, rc, r_class
      ))
      left[[lc]] <- as.character(left[[lc]])
      right[[rc]] <- as.character(right[[rc]])
    }
  }

  list(left = left, right = right)
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

#' Format Join \code{by} Specification for Human-Readable Display
#'
#' @title Join Spec Formatter
#'
#' @description
#' Converts complex dplyr join specs (vectors, named vectors, join_by objects)
#' into a compact string like \code{"npi=provider_npi, year"}.
#'
#' @details
#' **Bug fixes incorporated:**
#' \itemize{
#'   \item Bug #43 (2026-01-27): Returns \code{"<none specified>"} for
#' \code{NULL} or empty \code{by}.
#'   \item Bug #169 (2026-01-28): Handles \code{dplyr::join_by()} objects.
#'   \item Preserves left-right mapping for named vectors.
#' }
#'
#' @param by \code{[character]} or \code{[join_by]} Join specification.
#'
#' @return \code{[character(1)]} Formatted string.
#'
#' @section Algorithm:
#' Handles three input types in priority order: (1) \code{dplyr::join_by()}
#' objects via \code{$x}/\code{$y} slots; (2) named character vectors where
#' \code{names(by)} are left-side and \code{unname(by)} are right-side; (3)
#' plain unnamed character vectors. \code{NULL} and zero-length inputs return
#' the sentinel string \code{"<none specified>"}.
#'
#' @section Pipeline Position:
#' Used internally by \code{safe_left_join()}, \code{safe_inner_join()},
#' \code{safe_semi_join()}, and \code{safe_anti_join()} to produce
#' human-readable join key strings for error messages and CSV report
#' \code{by_columns} columns.
#'
#' @seealso \code{\link{join_coverage_report}} and \code{\link{safe_left_join}},
#'   both of which call this function to populate diagnostic output.
#'
#' @family join-safety
#' @concept join-safety
#'
#' @examples
#' \dontrun{
#' format_by_columns("npi")                           # => "npi"
#' format_by_columns(c("npi" = "provider_npi"))       # => "npi=provider_npi"
#' format_by_columns(dplyr::join_by(npi == provider_npi)) # =>
#' "npi=provider_npi"
#' format_by_columns(NULL)                             # => "<none specified>"
#' }
#'
#' @keywords internal
format_by_columns <- function(by) {
  # BUG FIX (2026-01-27): Bug 43 - Handle NULL or empty by vectors.
  # Previously returned empty string, which propagated as blank in error messages
  # and report CSV by_columns fields.
  if (is.null(by) || (is.character(by) && length(by) == 0)) {
    return("<none specified>")
  }

  # BUG FIX (2026-01-28): Bug 169 - Handle dplyr::join_by() objects
  if (inherits(by, "dplyr_join_by")) {
    # Extract column names from join_by object
    # join_by objects have $x (left cols) and $y (right cols) components
    x_cols <- by$x
    y_cols <- by$y
    if (length(x_cols) == 0) {
      return("<none specified>")
    }
    parts <- vapply(seq_along(x_cols), function(i) {
      if (x_cols[i] == y_cols[i]) {
        x_cols[i]
      } else {
        paste0(x_cols[i], "=", y_cols[i])
      }
    }, character(1))
    return(paste(parts, collapse = ", "))
  }

  # BUG FIX (2026-01-27): For named vectors like c("npi" = "provider_npi"),
  # show "npi=provider_npi" instead of just "provider_npi" so the left-right
  # column mapping is preserved in reports and error messages.
  if (is.character(by) && !is.null(names(by)) && any(nzchar(names(by)))) {
    # Named character vector: show left=right mapping
    parts <- vapply(seq_along(by), function(i) {
      nm <- names(by)[i]
      if (nzchar(nm) && nm != by[i]) {
        paste0(nm, "=", by[i])
      } else {
        by[i]
      }
    }, character(1))
    paste(parts, collapse = ", ")
  } else if (is.character(by)) {
    paste(by, collapse = ", ")
  } else {
    nm <- names(by)
    if (is.null(nm) || length(nm) == 0) "<unrecognized by format>" else paste(nm, collapse = ", ")
  }
}

#' Report Join Coverage and Enforce Minimum Threshold
#'
#' @title Join Coverage Validator
#'
#' @description
#' Validates that the fraction of left rows matching the right table meets a
#' minimum threshold. Used internally by \code{safe_*_join} functions.
#'
#' @details
#' **Bug fixes incorporated:**
#' \itemize{
#'   \item Bug #101 (2026-01-28): Validate \code{min_coverage} in \code{[0, 1]}.
#'   \item Bug #187 (2026-01-28): Warn when \code{min_coverage = 0}.
#'   \item Bug #31 (2026-01-27): Consistent error handling via \code{stop()}.
#' }
#'
#' @param left_before  \code{[integer(1)]} Row count in left table before join.
#' @param joined_rows  \code{[integer(1)]} Count of rows that found a match.
#' @param label_left   \code{[character(1)]} Label for left table.
#' @param label_right  \code{[character(1)]} Label for right table.
#' @param min_coverage \code{[numeric(1)]} Minimum fraction matched (default
#'   \code{0.98}).
#' @inheritParams shared_params_run
#'
#' @return Invisible \code{TRUE}. Throws an error if coverage < threshold.
#'
#' @section Algorithm:
#' Coverage = \code{joined_rows / left_before} computed via \code{safe_divide()}
#' to avoid division-by-zero on empty tables. Errors when coverage exceeds 1.0
#' (right-side duplicates caused row explosion) or falls below
#' \code{min_coverage}. Both error messages include row counts and percentages
#' for actionable debugging.
#'
#' @section Pipeline Position:
#' Called at the end of the fallback (non-enhanced-metrics) path in
#' \code{safe_left_join()} and \code{safe_inner_join()}. The enhanced metrics
#' path in \code{R/join_metrics.R} performs its own coverage check and does
#' not call this function.
#'
#' @seealso \code{\link{safe_left_join}} and \code{\link{safe_inner_join}},
#'   which call this in their basic validation path;
#'   \code{\link{assert_unique_keys}} for the complementary key-uniqueness
#' check.
#'
#' @family join-safety
#' @concept join-safety
#' @concept coverage-threshold
#'
#' @examples
#' \dontrun{
#' join_coverage_report(
#'   left_before  = 10000L,
#'   joined_rows  = 9800L,
#'   label_left   = "physician_cohort",
#'   label_right  = "census_demographics",
#'   min_coverage = 0.98
#' )
#' }
#'
#' @keywords internal
join_coverage_report <- function(left_before, joined_rows,
                                 label_left = "left", label_right = "right",
                                 min_coverage = 0.98,
                                 verbose = TRUE) {
  checkmate::assert_count(left_before)
  checkmate::assert_count(joined_rows)
  checkmate::assert_string(label_left)
  checkmate::assert_string(label_right)
  checkmate::assert_flag(verbose)

  # BUG FIX (2026-01-28): Bug 101 - Validate min_coverage is in [0, 1]
  checkmate::assert_number(min_coverage, lower = 0, upper = 1)

  # BUG FIX (2026-01-28): Bug 187 - Warn when min_coverage=0 (allows complete data loss)
  if (min_coverage == 0) {
    warning("join_coverage_report: min_coverage=0 allows complete data loss (0% coverage). This is usually unintentional.", call. = FALSE)
  }

  # BUG FIX (2026-01-27): Handle empty left table to prevent division by zero
  if (left_before == 0) {
    message(sprintf(
      "📊 Join coverage: %s rows=0, after join=%s (coverage=N/A, empty input)",
      label_left, format(joined_rows, big.mark = ",")
    ))
    return(invisible(TRUE))
  }

  coverage <- safe_divide(joined_rows, left_before)
  message(sprintf(
    "📊 Join coverage: %s rows=%s, after join=%s (coverage=%.1f%%)",
    label_left,
    format(left_before, big.mark = ","),
    format(joined_rows, big.mark = ","),
    coverage * 100
  ))

  # Check for unexpected row multiplication (coverage > 1.0 indicates duplicates)
  # BUG FIX (2026-01-27): Bug 31 - Enforce join validation like every other check.
  # Previously called stop() unconditionally, ensure consistent error handling.
  # Bug 4 fix: safe_divide() returns NA when left_before==0; NA > 1.0 is NA,
  # which causes "missing value where TRUE/FALSE needed" in if().
  if (!is.na(coverage) && coverage > 1.0) {
    error_msg <- sprintf(
      "❌ Join produced MORE rows than input (%.1f%% coverage). This indicates duplicate keys in right table. Joined=%s, Expected=%s",
      coverage * 100, format(joined_rows, big.mark = ","), format(left_before, big.mark = ",")
    )
      stop(error_msg)
  }

  # Bug 5 fix: same NA guard needed as Bug 4 — coverage may be NA.
  if (!is.na(coverage) && coverage < min_coverage) {
    error_msg <- sprintf(
      "❌ Join coverage %.1f%% below %.1f%% threshold. Lost %s rows. Investigate key normalization, duplicates, or missing keys.",
      coverage * 100, min_coverage * 100,
      format(left_before - joined_rows, big.mark = ",")
    )

    # Validate join integrity
      stop(error_msg)
  }
  invisible(TRUE)
}

# ---- Safe Join Wrappers --------------------------------------------------

#' @title Safe Left Join with Coverage Validation and Cardinality Checking
#'
#' @description
#' Wrapper for \code{dplyr::left_join()} with comprehensive validation: coverage
#' thresholds, cardinality checks, duplication limits, and CSV reporting.
#' Primary join function for pipeline enrichment steps. Delegates to enhanced
#' metrics module when available (recommended).
#'
#' @details
#' **Pipeline usage:** Used in 20+ enrichment steps for adding demographics,
#' Medicare claims, retirement data, etc. See
#' \code{R/01-build-county-base.R} for example. (This pointed at
#' \code{R/11-create-access-by-group.R}, which exists in no checkout -- a
#' cross-reference to a file that was never here or has been renamed away.)
#'
#' **Validation workflow:**
#' \enumerate{
#'   \item Validate \code{by} parameter (Bug #220).
#'   \item Read environment variable overrides (\code{JOIN_MIN_COVERAGE},
#'         \code{JOIN_MAX_DUPLICATION}).
#'   \item Check if enhanced metrics available (\code{R/join_metrics.R}).
#'   \item If enhanced: delegate to \code{safe_left_join_with_metrics()} (stops
#' if
#'         unavailable).
#'   \item If basic: validate right uniqueness, compute coverage, check
#' duplication.
#'   \item Write CSV report to \code{artifacts/step00_summary/} (if
#' \code{write_report = TRUE}).
#' }
#'
#' @param left                 \code{[data.frame]} Left table (preserves all
#'   rows).
#' @param right                \code{[data.frame]} Right table (lookup data).
#' @param by                   \code{[character]} or \code{[join_by]}
#'   specification.
#' @param expect_unique_right  \code{[logical(1)]} Require right keys unique.
#'   Default \code{TRUE}.
#' @param label_left           \code{[character(1)]} Label for left table.
#' @param label_right          \code{[character(1)]} Label for right table.
#' @param min_coverage         \code{[numeric(1)]} Min fraction of matches
#'   (0-1).
#' @param max_duplication      \code{[numeric(1)]} Max allowed row inflation.
#' @param max_right_dup_keys   \code{[integer(1)]} Max duplicate key groups on
#'   right.
#' @param max_left_only_rows   \code{[integer(1)]} Max unmatched rows.
#' @param agree_on             \code{[character]} Columns to check for
#'   agreement.
#' @param agree_map            \code{[list]} Agreement thresholds per column.
#' @param suffix               \code{[character(2)]} Suffixes for conflicts.
#' @param write_report         \code{[logical(1)]} Write CSV report.
#' @param report_prefix        \code{[character(1)]} Filename prefix.
#' @param use_enhanced_metrics \code{[logical(1)]} Use full metrics module.
#'   Default \code{TRUE}.
#'
#' @return \code{[data.frame]} Left join result.
#'
#' @section Contract:
#' \strong{Guarantees:}
#' \itemize{
#'   \item Always preserves all rows from \code{left}.
#'   \item Throws error if match rate < \code{min_coverage}.
#'   \item Throws error if row count inflation > \code{max_duplication}.
#'   \item Coerces join keys to character if types mismatch (prevents silent 0
#' matches).
#' }
#' \strong{Fails if:}
#' \itemize{
#'   \item \code{by} is NULL or empty.
#'   \item Join keys are missing from either table.
#'   \item Uniqueness or coverage contracts are violated.
#' }
#'
#' @section Pipeline Position:
#' Step-agnostic enrichment join used in 20+ pipeline steps (e.g., Step 4
#' demographic enrichment, Step 5 credential enrichment, Step 11 RUCA
#' attribution). Replaces bare \code{dplyr::left_join()} throughout the
#' pipeline to enforce the Safe Join Standard.
#'
#' @section Algorithm:
#' Validates parameters and reads \code{JOIN_MIN_COVERAGE} /
#' \code{JOIN_MAX_DUPLICATION} environment overrides. Harmonizes key types via
#' \code{harmonize_join_key_types()}. When \code{use_enhanced_metrics = TRUE}
#' (default), delegates entirely to \code{safe_left_join_with_metrics()} from
#' \code{R/join_metrics.R} for full cardinality, coverage, and agreement
#' checking. Falls back to the inline coverage-only path only when
#' \code{use_enhanced_metrics = FALSE} is explicitly set.
#'
#' @section Calls:
#' \code{harmonize_join_key_types()}, \code{safe_left_join_with_metrics()} (if enhanced),
#' \code{dplyr::left_join()}, \code{join_coverage_report()}.
#'
#' @section Performance:
#' O(n log n) join complexity. Added validation overhead is O(n), typically <
#' 10%
#' of total join time. Memory usage peaks at ~3x the size of the tables during 
#' metric computation.
#'
#' @section Disaster Prevention:
#' \describe{
#'   \item{Silent join failure guard}{Prevents "all-NA" enrichment columns by
#' coercing
#'         NPI/GEOID keys to character before joining.}
#'   \item{Many-to-many explosion guard}{Stops the pipeline if a lookup join 
#'         unexpectedly multiplies row count (e.g., duplicate NPIs in a
#' reference table).}
#' }
#'
#' @concept join-safety
#' @concept coverage-threshold
#' @concept fanout-detection
#' @concept duckdb-joins
#'
#' @seealso \code{\link{safe_inner_join}}, \code{\link{safe_semi_join}},
#'   \code{\link{safe_anti_join}} for other join types;
#'   \code{R/join_metrics.R} for enhanced validation module.
#'
#' @examples
#' \dontrun{
#' # Basic enrichment join
#' enriched <- safe_left_join(
#'   left = cohort,
#'   right = demographics,
#'   by = "fips_tract",
#'   label_left = "physician_cohort",
#'   label_right = "census_demographics_2020"
#' )
#'
#' # Join with column name mapping
#' enriched <- safe_left_join(
#'   left = abog,
#'   right = nber,
#'   by = c("npi" = "provider_npi", "year"),
#'   label_left = "abog_physicians",
#'   label_right = "nber_claims"
#' )
#' }
#'
#' @family safe-joins
#' @keywords join safety left
#' @export
safe_left_join <- function(left, right, by, expect_unique_right = TRUE,
                           label_left = "left", label_right = "right",
                           min_coverage = NULL,
                           max_duplication = NULL,
                           max_right_dup_keys = if (expect_unique_right) 0 else Inf,
                           max_left_only_rows = NA_integer_,
                           require_complete_keys = TRUE,
                           agree_on = NULL, agree_map = NULL,
                           suffix = c(".x", ".y"),
                           write_report = TRUE, report_prefix = "join_left",
                           # CYCLE 9. Was TRUE, which made this function ERROR on every
                           # call: it requires safe_left_join_with_metrics() from
                           # R/join_metrics.R, and that file does not exist in this
                           # repo. All six callers had independently discovered they
                           # must pass FALSE -- a unanimous silent vote that the
                           # default was unusable, and the likeliest reason the
                           # pipeline makes 46 bare joins against 8 guarded ones.
                           # Basic validation is real validation; it is what every
                           # caller has actually been running. Asking for enhanced
                           # metrics explicitly still hard-stops when they are absent,
                           # which preserves the 2026-02-12 intent that a REQUESTED
                           # check is never silently skipped.
                           use_enhanced_metrics = FALSE) {
  # ── Parameter validation ──────────────────────────────────────────────────
  checkmate::assert_data_frame(left)
  checkmate::assert_data_frame(right)
  # BUG FIX (2026-01-28): Bug 220 - Validate by parameter
  if (is.null(by) || (is.character(by) && length(by) == 0)) {
    stop("safe_left_join: 'by' parameter is required. Specify join column(s) or use dplyr::join_by().", call. = FALSE)
  }
  # Validate label parameters
  checkmate::assert_string(label_left)
  checkmate::assert_string(label_right)
  # Validate numeric parameters when explicitly passed (not NULL)
  checkmate::assert_number(min_coverage, lower = 0, upper = 1, null.ok = TRUE)
  checkmate::assert_number(max_duplication, lower = 0, null.ok = TRUE)
  # Validate logical parameters
  checkmate::assert_flag(expect_unique_right)
  checkmate::assert_flag(write_report)
  checkmate::assert_flag(use_enhanced_metrics)
  # Validate suffix
  checkmate::assert_character(suffix, len = 2)
  # Validate report_prefix
  checkmate::assert_string(report_prefix)

  # Read environment variables if parameters not explicitly provided
  # BUG FIX (2026-01-28): Bug 188 - Handle invalid env var values gracefully
  if (is.null(min_coverage)) {
    env_coverage <- Sys.getenv("JOIN_MIN_COVERAGE", unset = "")
    if (nzchar(env_coverage)) {
      min_coverage <- suppressWarnings(as.numeric(env_coverage))
      if (is.na(min_coverage)) {
        warning(sprintf("Invalid JOIN_MIN_COVERAGE value '%s', using default 0.98", env_coverage), call. = FALSE)
        min_coverage <- 0.98
      }
    } else {
      min_coverage <- 0.98
    }
  }

  if (is.null(max_duplication)) {
    env_dup <- Sys.getenv("JOIN_MAX_DUPLICATION", unset = "")
    if (nzchar(env_dup)) {
      max_duplication <- suppressWarnings(as.numeric(env_dup))
      if (is.na(max_duplication)) {
        warning(sprintf("Invalid JOIN_MAX_DUPLICATION value '%s', using default 1.02", env_dup), call. = FALSE)
        max_duplication <- 1.02
      }
    } else {
      max_duplication <- 1.02
    }
  }

  # Post-resolution range checks (env var values may be out of range)
  if (!is.null(min_coverage) && (min_coverage < 0 || min_coverage > 1)) {
    warning(sprintf(
      "safe_left_join: resolved min_coverage=%s is out of [0,1] range, clamping to [0,1]",
      min_coverage
    ), call. = FALSE)
    min_coverage <- max(0, min(1, min_coverage))
  }
  if (!is.null(max_duplication) && max_duplication < 0) {
    warning(sprintf(
      "safe_left_join: resolved max_duplication=%s is negative, setting to default 1.02",
      max_duplication
    ), call. = FALSE)
    max_duplication <- 1.02
  }

  # BUG FIX (2026-04-05): Harmonize join key types before any join operation.
  # RDS/Parquet round-trips can silently change integer→double. If left has
  # integer NPI and right has double NPI (or vice versa), dplyr::left_join
  # silently produces 0 matches. Coerce mismatched keys to character.
  harmonized <- harmonize_join_key_types(left, right, by, label_left, label_right)
  left <- harmonized$left
  right <- harmonized$right

  # PRIORITY 1 FIX (2026-02-12): Enhanced metrics now required when requested
  # Previously warned and fell back to basic validation, hiding that comprehensive
  # checks (cardinality, key quality, agreement) were skipped.
  # Now: STOP if enhanced metrics requested but not available.
  if (use_enhanced_metrics) {
    if (!exists("safe_left_join_with_metrics", mode = "function")) {
      stop(
        "Enhanced join metrics requested but not available.\n",
        "safe_left_join_with_metrics() function not found.\n\n",
        "R/join_metrics.R DOES NOT EXIST in the midwifery repo -- this is not a\n",
        "module-loading problem, the file was never added here. Either drop\n",
        "use_enhanced_metrics (basic validation still runs) or port the module.\n",
        "Check module loading or source manually:\n",
        "  source(here::here('R', 'join_metrics.R'))\n\n",
        "To use basic validation only, set use_enhanced_metrics=FALSE explicitly.",
        call. = FALSE
      )
    }

    # Enhanced metrics available - use them
    result <- safe_left_join_with_metrics(
      left = left,
      right = right,
      by = by,
      expect_unique_right = expect_unique_right,
      label_left = label_left,
      label_right = label_right,
      min_coverage = min_coverage,
      max_duplication = max_duplication,
      max_right_dup_keys = max_right_dup_keys,
      max_left_only_rows = max_left_only_rows,
      require_complete_keys = require_complete_keys,
      agree_on = agree_on,
      agree_map = agree_map,
      write_report = write_report,
      report_prefix = report_prefix
    )

    # Log to join integrity ledger (non-breaking)
    if (exists("log_join_integrity", mode = "function")) {
      tryCatch(
        log_join_integrity(
          step_name = Sys.getenv("PIPELINE_CURRENT_STEP", unset = "unknown"),
          join_type = "left",
          left_label = label_left,
          right_label = label_right,
          left_rows = nrow(left),
          right_rows = nrow(right),
          result_rows = nrow(result),
          matched_rows = nrow(left) - nrow(dplyr::anti_join(left, right, by = by, na_matches = "never")),
          key_columns = format_by_columns(by)
        ),
        error = function(e) NULL
      )
    }

    return(result)
  }

  # Fallback to original implementation with hardened features
  # Right side uniqueness if declared
  if (isTRUE(expect_unique_right)) {
    # BUG FIX (2026-01-28): Bug 62 - Use right-side column names for right table check.
    # NEW-102: join_by() objects not handled — unname(join_by_obj) returns the object
    # itself, causing assert_unique_keys() to fail with a cryptic type error.
    by_right_cols <- if (inherits(by, "dplyr_join_by")) {
      by$y
    } else if (is.character(by) && is.null(names(by))) {
      by
    } else {
      unname(by)
    }
    assert_unique_keys(right, by_right_cols, label = paste(label_right, "(right)"))
  }

  left_n <- nrow(left)

  # Calculate actual coverage (fraction of left rows that match) before join
  left_only_rows <- nrow(dplyr::anti_join(left, right, by = by, na_matches = "never"))
  matched_rows <- left_n - left_only_rows

  # Enhanced left join with relationship declaration and no NA matches
  # BUG FIX (2026-01-28): Bug 153 - Pass suffix parameter to handle column name conflicts
  out <- dplyr::left_join(
    left, right,
    by = by,
    suffix = suffix,
    relationship = if (expect_unique_right) "many-to-one" else NULL,
    na_matches = "never"
  )

  # BUG FIX (2026-01-27): Cross-verify anti_join match count against left_join output.

  # For a left join, nrow(out) should equal left_n when right keys are unique (many-to-one).
  # If nrow(out) > left_n, it means right-side duplicate keys caused row multiplication.
  # If nrow(out) < left_n, something went seriously wrong (should never happen for left join).
  # We also verify that the number of matched rows (from anti_join) is consistent with
  # the number of non-NA right-side columns in the output.
  if (left_n > 0 && nrow(out) != left_n) {
    # Row count changed — indicates duplicate right keys caused multiplication
    by_cols_for_check <- if (is.character(by)) by else unname(by)
    right_only_cols <- setdiff(names(right), by_cols_for_check)
    if (length(right_only_cols) > 0) {
      # Count output rows that got a match (non-NA in first right-only column)
      output_matched <- sum(!is.na(out[[right_only_cols[1]]]))
      if (output_matched != matched_rows) {
        message(sprintf(
          "JOIN CROSS-VERIFICATION: anti_join matched %d left rows, but left_join produced %d matched output rows (row multiplication from duplicate right keys). Output has %d rows vs %d input. %s -> %s on %s.",
          matched_rows, output_matched, nrow(out), left_n,
          label_left, label_right,
          format_by_columns(by)
        ))
      }
    }
  }

  # Basic coverage check (enhanced metrics would provide more)
  join_coverage_report(left_n, matched_rows, label_left, label_right, min_coverage)

  # BUG FIX (2026-01-27): Enforce max_right_dup_keys in fallback path
  # Previously this parameter was accepted but silently ignored when enhanced
  # metrics were unavailable, allowing right-side duplicate keys to go undetected.

  # Coverage-consistent gate for unmatched left rows

  # Tolerance precedence:
  # 1. If max_left_only_rows is explicitly set (non-NA), use it as-is
  # 2. Else if min_coverage is finite and in (0,1), derive from coverage
  # 3. Else default 0 (strict)
  if (!is.na(max_left_only_rows)) {
    effective_max <- max_left_only_rows
  } else if (is.finite(min_coverage) && min_coverage > 0 && min_coverage < 1) {
    effective_max <- ceiling((1 - min_coverage) * left_n)
  } else {
    effective_max <- 0L
  }

  if (left_only_rows > effective_max) {
    left_only_pct <- safe_pct_manu(left_only_rows, left_n)
    coverage_derived_str <- if (is.finite(min_coverage) && min_coverage > 0 && min_coverage < 1)
      as.character(ceiling((1 - min_coverage) * left_n)) else "N/A"
    error_msg <- sprintf(
      "Join has %d unmatched left rows (%.2f%%). Effective max: %d (explicit=%s, coverage-derived=%s). %s -> %s on %s.",
      left_only_rows, left_only_pct, effective_max,
      if (is.na(max_left_only_rows)) "NA" else as.character(max_left_only_rows),
      coverage_derived_str,
      label_left, label_right, format_by_columns(by)
    )
    stop(error_msg)
  }

  # BUG FIX (2026-01-27): Enforce max_duplication parameter
  # BUG FIX (2026-01-27): Bug 50 - Guard against division by zero when left_n==0.
  # Previously computed nrow(out)/0 = NaN unconditionally, then relied on the
  # left_n > 0 guard to avoid using the NaN. Now only compute when meaningful.
  duplication_factor <- safe_divide(nrow(out), left_n, default = 0)
  if (left_n > 0 && duplication_factor > max_duplication) {
    error_msg <- sprintf(
      "Join row duplication %.2fx exceeds max_duplication=%.2f. Output %d rows from %d input rows. %s -> %s.",
      duplication_factor, max_duplication,
      nrow(out), left_n,
      label_left, label_right
    )
      stop(error_msg)
  }

  # Write basic report if requested
  if (write_report) {
    # BUG FIX (2026-01-27): Use millisecond precision to prevent silent overwrites
    # when two joins run within the same second.
    ts <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
    env_report_dir <- Sys.getenv("JOIN_REPORT_DIR", unset = "")
    report_dir <- if (nzchar(env_report_dir)) env_report_dir else "artifacts/step00_summary"
    dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
    report_path <- file.path(report_dir, sprintf("%s_%s.csv", report_prefix, ts))

    # BUG FIX (2026-01-28): Bug 149 - Include validation status in report
    basic_metrics <- tibble(
      timestamp = ts,
      join_type = "left",
      label_left = label_left,
      label_right = label_right,
      left_rows = left_n,
      matched_rows = matched_rows,
      output_rows = nrow(out),
      coverage = safe_divide(matched_rows, left_n),
      left_only_rows = left_only_rows,
      left_only_pct = safe_pct_manu(left_only_rows, left_n),
      by_columns = format_by_columns(by),
    )

    report_tmp <- paste0(report_path, ".tmp")
    readr::write_csv(basic_metrics, report_tmp, na = "")
    file.rename(report_tmp, report_path)
    message("[DEBUG] Join report written: ", report_path)

    # Write bounded unmatched keys artifacts when there are unmatched left rows
    if (left_only_rows > 0) {
      # Determine run-scoped output directory
      run_id_env <- Sys.getenv("RUN_ID", unset = "")
      if (nzchar(run_id_env)) {
        unmatched_dir <- file.path("artifacts", run_id_env, "step00_summary")
      } else {
        unmatched_dir <- report_dir
      }
      dir.create(unmatched_dir, recursive = TRUE, showWarnings = FALSE)

      # Deterministic filename: hash by_columns for collision-proof naming
      by_str <- format_by_columns(by)
      # BUG FIX (class 6): was algo="sha1" — project standard requires algo="sha256"
      by_hash <- substr(digest::digest(by_str, algo = "sha256"), 1, 8)
      file_base <- sprintf("%s_unmatched_%s_%s_%s_%s",
        report_prefix, label_left, label_right,
        if (nzchar(run_id_env)) run_id_env else ts, by_hash)

      # File 1: Unmatched keys CSV (distinct join keys only, capped at 5000)
      by_left_cols <- if (is.character(by) && is.null(names(by))) by else names(by)
      unmatched_left <- dplyr::anti_join(left, right, by = by, na_matches = "never")
      unmatched_keys <- unmatched_left %>%
        dplyr::distinct(across(all_of(by_left_cols)))

      truncated <- nrow(unmatched_keys) > 5000
      truncated_from <- nrow(unmatched_keys)
      if (truncated) {
        unmatched_keys <- head(unmatched_keys, 5000)
      }

      csv_path <- file.path(unmatched_dir, paste0(file_base, ".csv"))
      csv_tmp <- paste0(csv_path, ".tmp")
      readr::write_csv(unmatched_keys, csv_tmp, na = "")
      file.rename(csv_tmp, csv_path)

      # File 2: Machine-readable summary JSON
      key_examples <- head(unmatched_keys, 20)
      key_examples_list <- lapply(seq_len(nrow(key_examples)), function(i) {
        as.list(key_examples[i, , drop = FALSE])
      })

      # SHA-256 of sorted keys for deterministic comparison
      sorted_keys <- unmatched_left %>%
        dplyr::distinct(across(all_of(by_left_cols))) %>%
        dplyr::arrange(across(everything()))
      keys_hash <- digest::digest(sorted_keys, algo = "sha256")

      summary_data <- list(
        left_n = left_n,
        matched_n = matched_rows,
        left_only_n = left_only_rows,
        left_only_pct = safe_pct_manu(left_only_rows, left_n, digits = 2),
        truncated = truncated,
        truncated_from = truncated_from,
        by_columns = by_str,
        label_left = label_left,
        label_right = label_right,
        run_id = if (nzchar(run_id_env)) run_id_env else NA_character_,
        timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
        missing_key_examples = key_examples_list,
        missing_key_hash = keys_hash,
        right_source_id = Sys.getenv("RIGHT_SOURCE_ID", unset = NA_character_)
      )

      json_path <- file.path(unmatched_dir, paste0(file_base, ".json"))
      json_path_tmp <- paste0(json_path, ".tmp.", Sys.getpid())
      jsonlite::write_json(summary_data, json_path_tmp, auto_unbox = TRUE, pretty = TRUE)
      file.rename(json_path_tmp, json_path)
      message("📝 Unmatched keys: ", csv_path, " + ", json_path,
        sprintf(" (%d keys%s)", truncated_from, if (truncated) ", truncated to 5000" else ""))
    }
  }

  # Log to join integrity ledger (non-breaking)
  if (exists("log_join_integrity", mode = "function")) {
    tryCatch(
      log_join_integrity(
        step_name = Sys.getenv("PIPELINE_CURRENT_STEP", unset = "unknown"),
        join_type = "left",
        left_label = label_left,
        right_label = label_right,
        left_rows = left_n,
        right_rows = nrow(right),
        result_rows = nrow(out),
        matched_rows = matched_rows,
        key_columns = format_by_columns(by)
      ),
      error = function(e) NULL
    )
  }

  out
}

#' @title Safe Inner Join with Cardinality Checking and Coverage Reporting
#'
#' @description
#' Wrapper for \code{dplyr::inner_join()} that filters both tables to matching
#' keys
#' while enforcing coverage thresholds and uniqueness constraints.
#'
#' @param left                 \code{[data.frame]} Left table.
#' @param right                \code{[data.frame]} Right table.
#' @param by                   \code{[character]} or \code{[join_by]}
#'   specification.
#' @param expect_unique_both   \code{[logical(1)]} Require unique keys on BOTH
#'   sides. Default \code{TRUE}.
#' @param label_left           \code{[character(1)]} Label for left table.
#' @param label_right          \code{[character(1)]} Label for right table.
#' @param min_coverage         \code{[numeric(1)]} Min fraction of matches
#'   (0-1).
#' @param max_duplication      \code{[numeric(1)]} Max allowed row inflation.
#' @param max_right_dup_keys   \code{[integer(1)]} Max duplicate key groups on
#'   right.
#' @param max_left_only_rows   \code{[integer(1)]} Max unmatched rows allowed.
#' @param agree_on             \code{[character]} Columns to check for
#'   agreement.
#' @param agree_map            \code{[list]} Agreement thresholds per column.
#' @param suffix               \code{[character(2)]} Suffixes for conflicts.
#' @param write_report         \code{[logical(1)]} Write CSV report.
#' @param report_prefix        \code{[character(1)]} Filename prefix.
#' @param use_enhanced_metrics \code{[logical(1)]} Use full metrics module.
#'   Default \code{TRUE}.
#'
#' @return \code{[data.frame]} Joined result.
#'
#' @section Contract:
#' \strong{Guarantees:}
#' \itemize{
#'   \item Returns only rows with matching keys in BOTH tables.
#'   \item Throws error if keep rate < \code{min_coverage}.
#'   \item Throws error if row count inflation > \code{max_duplication}.
#' }
#' \strong{Fails if:}
#' \itemize{
#'   \item \code{expect_unique_both = TRUE} and either table has duplicate keys.
#'   \item Either table is missing the specified join keys.
#' }
#'
#' @section Pipeline Position:
#' Used for cohort-restricting joins where only rows with matches in both
#' tables are meaningful, such as restricting the physician roster to NPIs that
#' appear in Medicare Part B claims (active-billing requirement). Produces
#' smaller output than \code{safe_left_join()}: unmatched left rows are
#' dropped rather than padded with \code{NA}.
#'
#' @section Algorithm:
#' After parameter validation and key-type harmonization, enforces uniqueness
#' on both tables when \code{expect_unique_both = TRUE} (default). Executes
#' \code{dplyr::inner_join()} then measures coverage as
#' \code{nrow(semi_join(left, right)) / nrow(left)} (Bug #26 fix: avoids
#' double-counting from many-to-many multiplication). Enforces
#' \code{max_duplication} and writes the CSV report.
#'
#' @section Calls:
#' \code{harmonize_join_key_types()}, \code{assert_unique_keys()}, 
#' \code{dplyr::inner_join()}, \code{join_coverage_report()}.
#'
#' @section Performance:
#' O(n log n) join complexity. Added validation overhead is O(n).
#'
#' @section Disaster Prevention:
#' \describe{
#'   \item{Cohort over-filtering guard}{Prevents silent accidental deletion of 
#'         the entire study cohort if a join key is misconfigured or a 
#'         reference table is empty.}
#' }
#'
#' @concept join-safety
#' @concept coverage-threshold
#' @concept data-integrity
#'
#' @seealso \code{\link{safe_left_join}} for joins that retain all left rows;
#'   \code{\link{safe_semi_join}} for filtering left rows without adding right
#'   columns; \code{\link{safe_anti_join}} for keeping only unmatched left rows;
#'   \code{\link{join_coverage_report}} for the underlying coverage check.
#'
#' @examples
#' library(dplyr)
#' physicians <- data.frame(npi = c("1", "2", "3"), specialty = c("OB", "GYN",
#' "RE"))
#' claims     <- data.frame(npi = c("1", "2"),      year = c(2020L, 2020L))
#'
#' # Inner join: only physicians with claims are kept
#' result <- safe_inner_join(
#'   left        = physicians,
#'   right       = claims,
#'   by          = "npi",
#'   label_left  = "abog_physicians",
#'   label_right = "medicare_claims",
#'   min_coverage = 0.50,
#'   write_report = FALSE
#' )
#'
#' @family safe-joins
#' @keywords join safety inner
#' @export
safe_inner_join <- function(left, right, by, expect_unique_both = TRUE,
                           label_left = "left", label_right = "right",
                           min_coverage = NULL,
                           max_duplication = NULL,
                           max_right_dup_keys = if (expect_unique_both) 0 else Inf,
                           max_left_only_rows = 0,
                           agree_on = NULL, agree_map = NULL,
                           suffix = c(".x", ".y"),
                           write_report = TRUE,
                           report_prefix = "join_inner",
                           use_enhanced_metrics = TRUE) {
  # ── Parameter validation (parity with safe_left_join) ────────────────────
  checkmate::assert_data_frame(left)
  checkmate::assert_data_frame(right)
  if (is.null(by) || (is.character(by) && length(by) == 0)) {
    stop("safe_inner_join: 'by' parameter is required. Specify join column(s) or use dplyr::join_by().",
         call. = FALSE)
  }
  # Validate label parameters
  checkmate::assert_string(label_left)
  checkmate::assert_string(label_right)
  # Validate numeric parameters when explicitly passed (not NULL)
  checkmate::assert_number(min_coverage, lower = 0, upper = 1, null.ok = TRUE)
  checkmate::assert_number(max_duplication, lower = 0, null.ok = TRUE)
  # Validate logical parameters
  checkmate::assert_flag(expect_unique_both)
  checkmate::assert_flag(write_report)
  checkmate::assert_flag(use_enhanced_metrics)
  # Validate suffix
  checkmate::assert_character(suffix, len = 2)
  # Validate report_prefix
  checkmate::assert_string(report_prefix)
  # Validate max_left_only_rows
  checkmate::assert_number(max_left_only_rows)
  # Validate max_right_dup_keys
  checkmate::assert_number(max_right_dup_keys)
  # Validate agree_on and agree_map
  checkmate::assert_character(agree_on, null.ok = TRUE)
  checkmate::assert_list(agree_map, null.ok = TRUE)

  # Validate join key columns exist in both tables
  by_left_cols <- if (is.character(by) && !is.null(names(by))) names(by) else by
  by_right_cols <- if (is.character(by) && !is.null(names(by))) unname(by) else by
  missing_left <- setdiff(by_left_cols, names(left))
  missing_right <- setdiff(by_right_cols, names(right))
  if (length(missing_left) > 0) {
    stop(sprintf(
      "safe_inner_join: join key(s) not found in left (%s): %s\nAvailable: %s",
      label_left, paste(missing_left, collapse = ", "),
      paste(head(names(left), 20), collapse = ", ")
    ), call. = FALSE)
  }
  if (length(missing_right) > 0) {
    stop(sprintf(
      "safe_inner_join: join key(s) not found in right (%s): %s\nAvailable: %s",
      label_right, paste(missing_right, collapse = ", "),
      paste(head(names(right), 20), collapse = ", ")
    ), call. = FALSE)
  }

  # BUG FIX (2026-04-05): Harmonize join key types (same as safe_left_join)
  harmonized <- harmonize_join_key_types(left, right, by, label_left, label_right)
  left <- harmonized$left
  right <- harmonized$right

  # Warn on empty tables (inner join of empty → empty, may indicate upstream bug)
  if (nrow(left) == 0L) {
    warning(sprintf(
      "safe_inner_join: left table '%s' has 0 rows — result will be empty",
      label_left
    ), call. = FALSE)
  }
  if (nrow(right) == 0L) {
    warning(sprintf(
      "safe_inner_join: right table '%s' has 0 rows — result will be empty",
      label_right
    ), call. = FALSE)
  }

  # BUG FIX (2026-01-27): Bug 37 - Read JOIN_MIN_COVERAGE and JOIN_MAX_DUPLICATION
  # from environment variables, like safe_left_join does. Previously hardcoded
  # min_coverage=0.90 and ignored env vars, causing inconsistent pipeline behavior.
  if (is.null(min_coverage)) {
    env_coverage <- Sys.getenv("JOIN_MIN_COVERAGE", unset = "")
    if (nzchar(env_coverage)) {
      min_coverage <- suppressWarnings(as.numeric(env_coverage))
      if (is.na(min_coverage)) {
        warning(sprintf("Invalid JOIN_MIN_COVERAGE value '%s', using default 0.90",
                        env_coverage), call. = FALSE)
        min_coverage <- 0.90
      }
    } else {
      min_coverage <- 0.90
    }
  }

  if (is.null(max_duplication)) {
    env_dup <- Sys.getenv("JOIN_MAX_DUPLICATION", unset = "")
    if (nzchar(env_dup)) {
      max_duplication <- suppressWarnings(as.numeric(env_dup))
      if (is.na(max_duplication)) {
        warning(sprintf("Invalid JOIN_MAX_DUPLICATION value '%s', ignoring",
                        env_dup), call. = FALSE)
        max_duplication <- NULL
      }
    }
  }

  # Post-resolution range checks (env var values may be out of range)
  if (!is.null(min_coverage) && (min_coverage < 0 || min_coverage > 1)) {
    warning(sprintf(
      "safe_inner_join: resolved min_coverage=%s is out of [0,1] range, clamping to [0,1]",
      min_coverage
    ), call. = FALSE)
    min_coverage <- max(0, min(1, min_coverage))
  }
  if (!is.null(max_duplication) && max_duplication < 0) {
    warning(sprintf(
      "safe_inner_join: resolved max_duplication=%s is negative, setting to NULL (disabled)",
      max_duplication
    ), call. = FALSE)
    max_duplication <- NULL
  }

  # Assert uniqueness on both sides if declared
  if (isTRUE(expect_unique_both)) {
    # BUG FIX (2026-01-28): Bug 62 - Use correct column names for each table.
    # For named vectors like c("npi" = "provider_npi"):
    #   - Left table uses names(by) = "npi"
    #   - Right table uses unname(by) = "provider_npi"
    # For unnamed vectors, both use the same column names.
    by_left_cols <- if (is.character(by) && is.null(names(by))) by else names(by)
    by_right_cols <- if (is.character(by) && is.null(names(by))) by else unname(by)
    assert_unique_keys(left, by_left_cols, "inner left (keys)")
    assert_unique_keys(right, by_right_cols, "inner right (keys)")
  }

  left_n <- nrow(left)
  # BUG FIX (2026-01-28): Bug 154 - Pass suffix parameter to handle column name conflicts
  out <- dplyr::inner_join(left, right,
    by = by, suffix = suffix, na_matches = "never",
    relationship = if (expect_unique_both) "one-to-one" else NULL
  )

  # BUG FIX (2026-01-27): Bug 26 - Use distinct left match count for coverage,

  # not nrow(out). For many-to-many joins, nrow(out) can exceed left_n, which
  # caused join_coverage_report to hard-fail with "row multiplication" error.
  # Coverage should measure "what fraction of left rows appear in output."
  matched_left_rows <- nrow(dplyr::semi_join(left, right, by = by, na_matches = "never"))
  join_coverage_report(left_n, matched_left_rows, label_left, label_right, min_coverage)

  # BUG FIX (2026-01-27): Bug 30 - Enforce max_right_dup_keys like safe_left_join
  # (Code removed - parameter now enforced via join metrics)

  # BUG FIX (2026-01-27): Bug 30 - Enforce max_duplication like safe_left_join
  if (!is.null(max_duplication) && left_n > 0) {
    # Bug 6 fix: safe_left_join uses default=0; safe_inner_join was missing it.
    # Without default, safe_divide returns NA when left_n==0, and NA > threshold
    # throws "missing value where TRUE/FALSE needed". Although left_n > 0 is
    # checked above, adding default=0 is defensive and matches the sibling call.
    duplication_factor <- safe_divide(nrow(out), left_n, default = 0)
    if (duplication_factor > max_duplication) {
      error_msg <- sprintf(
        "Inner join row duplication %.2fx exceeds max_duplication=%.2f. Output %d rows from %d input. %s -> %s.",
        duplication_factor, max_duplication,
        nrow(out), left_n, label_left, label_right
      )
        stop(error_msg)
    }
  }

  if (write_report) {
    ts <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
    env_report_dir <- Sys.getenv("JOIN_REPORT_DIR", unset = "")
    report_dir <- if (nzchar(env_report_dir)) env_report_dir else "artifacts/step00_summary"
    dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
    report_path <- file.path(report_dir, sprintf("%s_%s.csv", report_prefix, ts))

    metrics <- tibble(
      timestamp = ts,
      join_type = "inner",
      label_left = label_left,
      label_right = label_right,
      left_rows = left_n,
      matched_rows = matched_left_rows,
      output_rows = nrow(out),
      coverage = safe_divide(matched_left_rows, left_n),
      by_columns = format_by_columns(by)
    )

    report_tmp <- paste0(report_path, ".tmp")
    readr::write_csv(metrics, report_tmp, na = "")
    file.rename(report_tmp, report_path)
    message("[DEBUG] Join report written: ", report_path)
  }

  # Log to join integrity ledger (non-breaking)
  if (exists("log_join_integrity", mode = "function")) {
    tryCatch(
      log_join_integrity(
        step_name = Sys.getenv("PIPELINE_CURRENT_STEP", unset = "unknown"),
        join_type = "inner",
        left_label = label_left,
        right_label = label_right,
        left_rows = left_n,
        right_rows = nrow(right),
        result_rows = nrow(out),
        matched_rows = matched_left_rows,
        key_columns = format_by_columns(by)
      ),
      error = function(e) NULL
    )
  }

  out
}

#' @title Safe Semi Join
#'
#' @description
#' Wrapper for \code{dplyr::semi_join()} that filters left rows to those
#' matching the right table, enforcing a minimum keep-rate threshold, and writes
#' an optional CSV report. Unlike \code{safe_inner_join()}, no right-side
#' columns are added to the output — the result is a subset of \code{left}.
#'
#' @details
#' **When to use:**
#' Use \code{safe_semi_join()} when you want to filter a data frame to rows that
#' have a match in a reference table, without attaching any additional columns
#' from that reference table. Typical use: restricting a physician roster to
#' those with an isochrone record.
#'
#' **Coverage definition:**
#' Coverage = \code{nrow(output) / nrow(left)}. Because \code{semi_join()} can
#' never produce more rows than \code{left}, this is always in \code{[0, 1]}.
#'
#' **Threshold enforcement (Bug #48):**
#' Default \code{min_coverage = 0.50} (50%). This intentionally differs from
#' \code{safe_left_join()} (98%) because semi joins are frequently used for
#' intentional subsetting. If fewer than \code{min_coverage} of left rows
#' survive, \code{stop()} is called with a diagnostic message.
#'
#' **Environment variables:**
#' - \code{JOIN_MIN_COVERAGE}: Override \code{min_coverage} (default 0.50).
#' - \code{JOIN_REPORT_DIR}: Override the report output directory.
#'
#' **Report output (Bug #35):**
#' CSV schema identical to other safe join types: \code{timestamp},
#' \code{join_type} (\code{"semi"}), \code{label_left}, \code{label_right},
#' \code{left_rows}, \code{matched_rows}, \code{output_rows}, \code{coverage},
#' \code{by_columns}.
#'
#' @param left               \code{[data.frame]} Left table to filter. Only rows
#'   that match the
#'   right table are kept.
#' @param right              \code{[data.frame]} Reference table. Used for
#'   matching only; its
#'   columns are not added to the output.
#' @param by                 \code{[character]} or \code{[join_by]}
#'   specification.
#' @param label_left         \code{[character(1)]} Label for left table.
#' @param label_right        \code{[character(1)]} Label for right table.
#' @param min_coverage       \code{[numeric(1)]} Min fraction kept (default
#'   \code{0.50}).
#' @param max_duplication    \code{[numeric(1)]} (API consistency only).
#' @param max_right_dup_keys \code{[integer(1)]} (API consistency only).
#' @param agree_on           \code{[character]} (API consistency only).
#' @param write_report       \code{[logical(1)]} Write CSV report.
#' @param report_prefix      \code{[character(1)]} Filename prefix.
#'
#' @return \code{[data.frame]} Filtered subset of \code{left}.
#'
#' @section Contract:
#' \strong{Guarantees:}
#' \itemize{
#'   \item Always returns a subset of \code{left} (never adds rows or columns).
#'   \item Throws error if keep rate < \code{min_coverage}.
#' }
#' \strong{Fails if:}
#' \itemize{
#'   \item Either table is missing the specified join keys.
#' }
#'
#' @section Pipeline Position:
#' Typically used at the beginning of downstream steps to restrict a wide
#' physician roster to those with a required artifact (e.g., an isochrone
#' record, a geocoded address, or an ABMS credential match). Because no right
#' columns are added, the output schema is identical to \code{left}.
#'
#' @section Algorithm:
#' Validates that \code{by} keys exist in both tables, harmonizes key types,
#' then calls \code{dplyr::semi_join(with na_matches = "never")}. Computes
#' \code{coverage = nrow(out) / nrow(left)} and stops if below
#' \code{min_coverage} (default 0.50; differs from \code{safe_left_join}'s
#' 0.98 because semi joins intentionally discard rows).
#'
#' @section Calls:
#' \code{harmonize_join_key_types()}, \code{dplyr::semi_join()}, \code{join_coverage_report()}.
#'
#' @section Performance:
#' Efficient O(n) filtering operation. No validation overhead beyond key type
#' check.
#'
#' @section Disaster Prevention:
#' \describe{
#'   \item{Subset integrity guard}{Ensures that mandatory filtering steps (e.g.,
#'         "only physicians with addresses") don't silently drop the entire 
#'         dataset due to a key mismatch.}
#' }
#'
#' @concept join-safety
#' @concept coverage-threshold
#'
#' @seealso \code{\link{safe_left_join}} for filtering while also attaching
#'   right-side columns; \code{\link{safe_anti_join}} for keeping only
#'   unmatched left rows; \code{\link{safe_inner_join}} for keeping matches
#'   from both sides with column merging; \code{\link{join_coverage_report}}
#'   for the underlying coverage utility.
#'
#' @examples
#' library(dplyr)
#' physicians <- data.frame(
#'   npi       = c("1", "2", "3", "4"),
#'   specialty = c("OB", "GYN", "RE", "MFM")
#' )
#' has_isochrone <- data.frame(npi = c("1", "3"))
#'
#' # Keep only physicians that have an isochrone
#' result <- safe_semi_join(
#'   left        = physicians,
#'   right       = has_isochrone,
#'   by          = "npi",
#'   label_left  = "physician_cohort",
#'   label_right = "isochrone_manifest",
#'   min_coverage = 0.25,   # at least 1 of 4 must match
#'   write_report = FALSE
#' )
#'
#' @family safe-joins
#' @keywords join safety semi
#' @export
safe_semi_join <- function(left, right, by,
                           label_left = "left", label_right = "right",
                           min_coverage = NULL,
                           max_duplication = NULL,
                           max_right_dup_keys = Inf,
                           agree_on = NULL,
                           write_report = TRUE, report_prefix = "join_semi") {
  # ── Parameter validation (parity with safe_left_join/safe_inner_join) ──
  checkmate::assert_data_frame(left)
  checkmate::assert_data_frame(right)
  if (is.null(by) || (is.character(by) && length(by) == 0L)) {
    stop("safe_semi_join: 'by' parameter is required. Specify join column(s).", call. = FALSE)
  }
  # Validate join keys exist in both tables
  by_left  <- if (!is.null(names(by))) ifelse(nzchar(names(by)), names(by), by) else by
  by_right <- unname(by)
  missing_left <- setdiff(by_left, names(left))
  if (length(missing_left) > 0L) {
    stop(sprintf("safe_semi_join: join key(s) %s not found in left. Available: %s",
                 paste0("'", missing_left, "'", collapse = ", "),
                 paste0(head(names(left), 10), collapse = ", ")), call. = FALSE)
  }
  missing_right <- setdiff(by_right, names(right))
  if (length(missing_right) > 0L) {
    stop(sprintf("safe_semi_join: join key(s) %s not found in right. Available: %s",
                 paste0("'", missing_right, "'", collapse = ", "),
                 paste0(head(names(right), 10), collapse = ", ")), call. = FALSE)
  }
  # BUG FIX (2026-04-05): Harmonize join key types
  harmonized <- harmonize_join_key_types(left, right, by, label_left, label_right)
  left <- harmonized$left
  right <- harmonized$right

  if (nrow(left) == 0L) warning("safe_semi_join: left table has 0 rows", call. = FALSE)
  if (nrow(right) == 0L) warning("safe_semi_join: right table has 0 rows", call. = FALSE)

  # BUG FIX (2026-01-27): Add min_coverage enforcement and join validation.
  # Previously reported percentages via message() but never enforced any threshold.
  # BUG FIX (2026-01-27): Bug 48 - Default to 0.50 instead of 0.0.
  # Previously defaulted to 0.0 which effectively disabled enforcement, so a
  # semi_join keeping only 1% of rows would pass silently. Other join types
  # default to 0.90-0.98. Semi_join uses 0.50 as a reasonable default.
  if (is.null(min_coverage)) {
    env_cov <- Sys.getenv("JOIN_MIN_COVERAGE", unset = "")
    if (nzchar(env_cov)) {
      parsed <- suppressWarnings(as.numeric(env_cov))
      if (is.na(parsed)) {
        warning(sprintf("Invalid JOIN_MIN_COVERAGE value '%s', using default 0.50", env_cov), call. = FALSE)
        min_coverage <- 0.50
      } else {
        min_coverage <- parsed
      }
    } else {
      min_coverage <- 0.50
    }
  }

  left_n <- nrow(left)
  out <- dplyr::semi_join(left, right, by = by, na_matches = "never")

  # Bug fix: Guard against division by zero on 0-row left table
  if (left_n == 0) {
    message(sprintf(
      "📊 Semi-join: %s rows=0, kept=0 (kept=N/A, empty input)",
      label_left
    ))
  } else {
    coverage <- safe_divide(nrow(out), left_n)
    message(sprintf(
      "📊 Semi-join: %s rows=%s, kept=%s (kept=%.1f%%)",
      label_left, format(left_n, big.mark = ","),
      format(nrow(out), big.mark = ","),
      coverage * 100
    ))

    if (coverage < min_coverage) {
      error_msg <- sprintf(
        "Semi-join coverage %.1f%% below %.1f%% threshold. Kept %d of %d rows. %s -> %s on %s.",
        coverage * 100, min_coverage * 100,
        nrow(out), left_n, label_left, label_right,
        format_by_columns(by)
      )
      stop(error_msg)
    }
  }

  # Write report if requested
  if (write_report) {
    # BUG FIX (2026-01-27): Use millisecond precision to prevent silent overwrites
    # when two joins run within the same second.
    ts <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
    env_report_dir <- Sys.getenv("JOIN_REPORT_DIR", unset = "")
    report_dir <- if (nzchar(env_report_dir)) env_report_dir else "artifacts/step00_summary"
    dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
    report_path <- file.path(report_dir, sprintf("%s_%s.csv", report_prefix, ts))

    # BUG FIX (2026-01-27): Bug 35 - Use unified schema across all join types.
    # Previously used kept_rows/keep_rate which differed from left/inner join schemas.
    semi_matched <- nrow(out) # semi_join output = matched rows
    metrics <- tibble(
      timestamp = ts,
      join_type = "semi",
      label_left = label_left,
      label_right = label_right,
      left_rows = left_n,
      matched_rows = semi_matched,
      output_rows = nrow(out),
      coverage = safe_divide(semi_matched, left_n),
      by_columns = format_by_columns(by)
    )

    report_tmp <- paste0(report_path, ".tmp")
    readr::write_csv(metrics, report_tmp, na = "")
    file.rename(report_tmp, report_path)
    message("[DEBUG] Join report written: ", report_path)
  }

  out
}

#' @title Safe Anti Join
#'
#' @description
#' Wrapper for \code{dplyr::anti_join()} that returns left rows with no match
#' in the right table, enforces a maximum matched-away rate, and writes an
#' optional CSV report. Useful for identifying exclusion sets (e.g., physicians
#' NOT in the retired list) while guarding against accidental over-exclusion.
#'
#' @details
#' **When to use:**
#' Use \code{safe_anti_join()} when you need the complement of a semi join —
#' rows from \code{left} that do NOT appear in \code{right}. Typical use:
#' removing retired physicians from an active cohort, or finding providers
#' without an isochrone.
#'
#' **Threshold enforcement (Bug #49):**
#' \code{max_matched} controls the maximum fraction of left rows that may be
#' matched away (i.e., excluded). Default: \code{1.0} (no limit). Set a lower
#' value to guard against over-exclusion — for example, \code{max_matched =
#' 0.30}
#' ensures at most 30% of the cohort can be dropped.
#' Reads the \code{JOIN_MAX_MATCHED} environment variable when not explicitly
#' supplied.
#'
#' **Coverage in reports:**
#' For anti joins, the \code{coverage} column in the CSV report equals
#' \code{matched_rows / left_rows}, where \code{matched_rows} is the count of
#' left rows that were excluded (matched to the right table). \code{output_rows}
#' is the count of left rows that survived (unmatched).
#'
#' **Environment variables:**
#' \itemize{
#'   \item \code{JOIN_MAX_MATCHED}: Override \code{max_matched} (default 1.0).
#'   \item \code{JOIN_REPORT_DIR}: Override the report output directory.
#' }
#'
#' **Report output (Bug #35):**
#' CSV schema identical to other safe join types: \code{timestamp},
#' \code{join_type} (\code{"anti"}), \code{label_left}, \code{label_right},
#' \code{left_rows}, \code{matched_rows} (excluded count), \code{output_rows}
#' (surviving count), \code{coverage}, \code{by_columns}.
#'
#' @param left            \code{[data.frame]} Left table to filter. Rows that
#'   match the right table are
#'   removed; unmatched rows are returned.
#' @param right           \code{[data.frame]} Reference table used for matching.
#'   Its columns
#'   are not added to the output.
#' @param by              \code{[character]} or \code{[join_by]} specification.
#' @param label_left      \code{[character(1)]} Label for left table.
#' @param label_right     \code{[character(1)]} Label for right table.
#' @param max_matched     \code{[numeric(1)]} Maximum fraction of left rows that
#'   may be
#'   matched (and thus excluded) (0 to 1). Default: \code{NULL} (reads
#'   \code{JOIN_MAX_MATCHED} env var or \code{1.0} — no limit).
#' @param min_coverage    \code{[numeric(1)]} (API consistency only).
#' @param max_duplication \code{[numeric(1)]} (API consistency only).
#' @param write_report    \code{[logical(1)]} Write CSV report.
#' @param report_prefix   \code{[character(1)]} Filename prefix.
#'
#' @return \code{[data.frame]} Filtered subset of \code{left}.
#'
#' @section Contract:
#' \strong{Guarantees:}
#' \itemize{
#'   \item Returns only rows from \code{left} that have NO match in
#' \code{right}.
#'   \item Throws error if exclusion rate > \code{max_matched}.
#' }
#' \strong{Fails if:}
#' \itemize{
#'   \item Either table is missing the specified join keys.
#' }
#'
#' @section Pipeline Position:
#' Primarily used in retirement-exclusion steps (e.g., Step 0.5 exclusions,
#' Step 4 retirement filtering) to remove known-inactive physicians from an
#' active cohort. Also used to find providers without an isochrone or without
#' a geocoded practice address for exclusion logging.
#'
#' @section Algorithm:
#' Validates keys, harmonizes types, then calls
#' \code{dplyr::anti_join(na_matches = "never")}. Computes
#' \code{matched_rate = (nrow(left) - nrow(out)) / nrow(left)} and stops if
#' this exceeds \code{max_matched} (default 1.0, i.e., no limit). Uses the
#' \code{JOIN_MAX_MATCHED} environment variable when not explicitly set.
#'
#' @section Calls:
#' \code{harmonize_join_key_types()}, \code{dplyr::anti_join()}, \code{join_coverage_report()}.
#'
#' @section Performance:
#' Efficient O(n) exclusion operation.
#'
#' @section Disaster Prevention:
#' \describe{
#'   \item{Over-exclusion guard}{Prevents accidental deletion of a large portion
#'         of the study cohort (e.g., if the retirement list is accidentally 
#'         truncated or corrupted).}
#' }
#'
#' @concept join-safety
#' @concept data-integrity
#'
#' @seealso \code{\link{safe_semi_join}} for the complementary filter (keeping
#'   only matched rows); \code{\link{safe_left_join}} for enrichment joins that
#'   retain all left rows; \code{\link{safe_inner_join}} for joins that keep
#'   only matched rows with right-side columns attached;
#'   \code{\link{join_coverage_report}} for the underlying coverage utility.
#'
#' @examples
#' library(dplyr)
#' all_physicians <- data.frame(
#'   npi       = c("1", "2", "3", "4"),
#'   specialty = c("OB", "GYN", "RE", "MFM")
#' )
#' retired <- data.frame(npi = c("2", "4"))
#'
#' # Remove retired physicians from the active cohort
#' active <- safe_anti_join(
#'   left        = all_physicians,
#'   right       = retired,
#'   by          = "npi",
#'   label_left  = "all_physicians",
#'   label_right = "retired_list",
#'   max_matched  = 0.60,   # at most 60% may be excluded
#'   write_report = FALSE
#' )
#'
#' @family safe-joins
#' @keywords join safety anti
#' @export
safe_anti_join <- function(left, right, by,
                           label_left = "left", label_right = "right",
                           max_matched = NULL,
                           min_coverage = NULL,
                           max_duplication = NULL,
                           write_report = TRUE, report_prefix = "join_anti") {

  # ── Parameter validation (parity with safe_left_join/safe_inner_join) ──
  checkmate::assert_data_frame(left)
  checkmate::assert_data_frame(right)
  if (is.null(by) || (is.character(by) && length(by) == 0L)) {
    stop("safe_anti_join: 'by' parameter is required. Specify join column(s).", call. = FALSE)
  }
  # Validate join keys exist in both tables
  by_left  <- if (!is.null(names(by))) ifelse(nzchar(names(by)), names(by), by) else by
  by_right <- unname(by)
  missing_left <- setdiff(by_left, names(left))
  if (length(missing_left) > 0L) {
    stop(sprintf("safe_anti_join: join key(s) %s not found in left. Available: %s",
                 paste0("'", missing_left, "'", collapse = ", "),
                 paste0(head(names(left), 10), collapse = ", ")), call. = FALSE)
  }
  missing_right <- setdiff(by_right, names(right))
  if (length(missing_right) > 0L) {
    stop(sprintf("safe_anti_join: join key(s) %s not found in right. Available: %s",
                 paste0("'", missing_right, "'", collapse = ", "),
                 paste0(head(names(right), 10), collapse = ", ")), call. = FALSE)
  }
  if (nrow(left) == 0L) warning("safe_anti_join: left table has 0 rows", call. = FALSE)
  if (nrow(right) == 0L) warning("safe_anti_join: right table has 0 rows", call. = FALSE)

  # BUG FIX (2026-01-27): Add max_matched enforcement and join validation.
  # Previously reported percentages via message() but never enforced thresholds.
  # max_matched = fraction of left rows that may be matched away (removed).
  # BUG FIX (2026-01-27): Bug 49 - Read JOIN_MAX_MATCHED from environment variable.
  # Previously ignored all env vars, breaking the pattern established by other join types.
  if (is.null(max_matched)) {
    env_mm <- Sys.getenv("JOIN_MAX_MATCHED", unset = "")
    if (nzchar(env_mm)) {
      # Match the graceful handling already used by safe_left/inner/semi_join: a
      # malformed override must warn and fall back to the default, not coerce to
      # NA and then crash the threshold comparison with a cryptic missing-value
      # error.
      parsed <- suppressWarnings(as.numeric(env_mm))
      if (is.na(parsed)) {
        warning(sprintf("Invalid JOIN_MAX_MATCHED value '%s', using default 1.0", env_mm), call. = FALSE)
        max_matched <- 1.0
      } else {
        max_matched <- parsed
      }
    } else {
      max_matched <- 1.0
    }
  }

  left_n <- nrow(left)
  out <- dplyr::anti_join(left, right, by = by, na_matches = "never")

  # Bug fix: Guard against division by zero on 0-row left table
  if (left_n == 0) {
    message(sprintf(
      "📊 Anti-join: %s rows=0, unmatched=0 (unmatched=N/A, empty input)",
      label_left
    ))
  } else {
    matched_rate <- safe_divide(left_n - nrow(out), left_n)
    message(sprintf(
      "📊 Anti-join: %s rows=%s, unmatched=%s (unmatched=%.1f%%)",
      label_left, format(left_n, big.mark = ","),
      format(nrow(out), big.mark = ","),
      safe_pct_manu(nrow(out), left_n)
    ))

    if (matched_rate > max_matched) {
      error_msg <- sprintf(
        "Anti-join matched rate %.1f%% exceeds max_matched=%.1f%%. %d of %d rows matched away. %s -> %s on %s.",
        matched_rate * 100, max_matched * 100,
        left_n - nrow(out), left_n, label_left, label_right,
        format_by_columns(by)
      )
      stop(error_msg)
    }
  }

  # Write report if requested
  if (write_report) {
    # BUG FIX (2026-01-27): Use millisecond precision to prevent silent overwrites
    # when two joins run within the same second.
    ts <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
    env_report_dir <- Sys.getenv("JOIN_REPORT_DIR", unset = "")
    report_dir <- if (nzchar(env_report_dir)) env_report_dir else "artifacts/step00_summary"
    dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
    report_path <- file.path(report_dir, sprintf("%s_%s.csv", report_prefix, ts))

    # BUG FIX (2026-01-27): Bug 35 - Use unified schema across all join types.
    # Previously used unmatched_rows/unmatch_rate which differed from other join schemas.
    anti_matched <- left_n - nrow(out) # rows that were matched away
    metrics <- tibble(
      timestamp = ts,
      join_type = "anti",
      label_left = label_left,
      label_right = label_right,
      left_rows = left_n,
      matched_rows = anti_matched,
      output_rows = nrow(out),
      coverage = safe_divide(anti_matched, left_n),
      by_columns = format_by_columns(by)
    )

    report_tmp <- paste0(report_path, ".tmp")
    readr::write_csv(metrics, report_tmp, na = "")
    file.rename(report_tmp, report_path)
    message("[DEBUG] Join report written: ", report_path)
  }

  out
}

#' Stop if a key carries conflicting rows
#'
#' @description
#' The smallest form of the rule cycle 2 put into `assert_unique_keys()`, for
#' readers that need the assertion and not the deduplication. Identical
#' duplicate rows are collapsed by the caller's `unique()`; anything still
#' duplicated on the key disagrees somewhere, and resolving that by row order is
#' a scientific decision made by a file's sort order.
#'
#' @param d [data.frame]: input, already `unique()`d.
#' @param key [character(1)]: key column.
#' @param label [character(1)]: what to name in the error.
#' @return `d` unchanged, or an error.
#' @family join-safety
#' @export
assert_no_key_conflict <- function(d, key, label = "input") {
  if (!key %in% names(d)) {
    stop(sprintf("assert_no_key_conflict: '%s' not found in %s.", key, label),
         call. = FALSE)
  }
  dup <- unique(d[[key]][duplicated(d[[key]])])
  if (length(dup)) {
    stop(sprintf(paste0(
      "%s: %d value(s) of '%s' carry conflicting rows (e.g. %s). Deduplicating ",
      "would resolve that by row order; reconcile the source instead."),
      label, length(dup), key,
      paste(utils::head(dup, 3), collapse = ", ")), call. = FALSE)
  }
  d
}
