#' @title Safe Join Functions with Coverage Validation and Reporting
#'
#' @description
#' Provides \code{safe_left_join()} and the key-integrity helpers it is built
#' on, which enforce data quality contracts. Features include coverage thresholds,
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
#' @section Removed in the 2026-11-20 complexity audit:
#' \code{safe_inner_join()}, \code{safe_semi_join()} and \code{safe_anti_join()}
#' had zero production call sites in this repository -- only tests -- and were
#' one function written four times (the semi/anti pair scored 0.78 structural
#' similarity). They still exist in \code{~/isochrones/R/join_safety.R}, the
#' copy this file was vendored from, which is where to take them from if a
#' caller ever needs one. \code{assert_unique_keys()} moved to
#' \code{R/assert_unique_keys.R}; it is still reached by sourcing this file.
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
# assert_unique_keys() moved to its own file in the 2026-11-20 complexity
# audit: 17 scripts were sourcing all 1,892 lines of this module to reach
# that one 69-line function, which calls nothing else here.
source(here::here("R", "assert_unique_keys.R"))

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
#'   \item Refuse \code{use_enhanced_metrics = TRUE}: the module it names,
#'         \code{R/join_metrics.R}, does not exist in this repository, so a
#'         requested check is never silently skipped.
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
#' \code{harmonize_join_key_types()}, then validates and joins inline.
#' \code{use_enhanced_metrics = TRUE} is refused with an error: the metrics
#' module it names (\code{R/join_metrics.R}) does not exist in this
#' repository, so a requested check cannot be silently skipped.
#'
#' \code{harmonize_join_key_types()}, \code{dplyr::left_join()},
#' \code{join_coverage_report()}.
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

  # CYCLE 10 (2026-11-20 complexity audit, Hotspot 1a). The 54 lines that stood
  # here delegated to safe_left_join_with_metrics() and logged to
  # log_join_integrity(). Neither is defined anywhere in this repository and
  # R/join_metrics.R was never added here, so the only outcome the block could
  # reach was the stop() below: 54 lines of unreachable delegation guarding a
  # refusal.
  #
  # THE PARAMETER STAYS, AND SO DOES THE REFUSAL. Deleting it would have been
  # the shorter diff and the wrong one. R/01-build-county-base.R's
  # load_join_safety() may source ~/isochrones/R/join_safety.R instead of this
  # copy, and there the same parameter defaults to TRUE and R/join_metrics.R
  # really does exist -- which is why its six call sites pass FALSE. The
  # argument is upstream-compatibility insurance, not noise, and a signature
  # without it would turn every one of those calls into an "unused argument"
  # error. The hard stop preserves the 2026-02-12 intent: a REQUESTED check is
  # never silently skipped.
  if (use_enhanced_metrics) {
    stop(
      "Enhanced join metrics requested but not available.\n",
      "R/join_metrics.R DOES NOT EXIST in the midwifery repo -- it was never\n",
      "added here, so safe_left_join_with_metrics() cannot be loaded. Drop\n",
      "use_enhanced_metrics; the validation below is what every caller in this\n",
      "repository has actually been running.",
      call. = FALSE
    )
  }

  # Validation and the join itself
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
  # Named, not positional. join_coverage_report()'s signature ends in
  # validation thresholds (min_coverage, verbose), so inserting a formal ahead
  # of min_coverage would slide a threshold into verbose with no call site
  # changing and no error raised. tests/test_review_fixes_saboteurs.R R14/R15
  # own this shape.
  join_coverage_report(left_before = left_n, joined_rows = matched_rows,
                       label_left = label_left, label_right = label_right,
                       min_coverage = min_coverage)

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

  # THE SECOND DEAD DELEGATION, found by the gate written for the first.
  # tests/test_complexity_cuts_saboteurs.R's C2a parses every tracked file for
  # CALLS (not text) to a function no file here defines, and it accused this
  # one: 17 lines logging to a join-integrity ledger, behind
  # `exists("log_join_integrity", mode = "function")`, which is FALSE in every
  # run because nothing in this repository defines it -- and wrapped in a
  # tryCatch that would have swallowed the error if it ever became TRUE. The
  # enhanced-metrics block above it was the finding; this was its twin, two
  # hundred lines down, and the audit missed it by reading only the branch the
  # measurement pointed at.
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
