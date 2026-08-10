# =============================================================================
# Field usability contracts for scraped attributes
# =============================================================================
# A completeness statistic answers "how many rows have a value", which is the
# wrong question on its own. `hg_years_experience` is 100% non-missing across
# 1,632 profiles and entirely worthless: every value is 0, because Healthgrades
# does not populate `roundedYearsOfExperience` for midwives. Reported as
# "100% complete" it looked like the BEST-covered variable in the set.
#
# Three distinct states get conflated by a naive coverage number, and each
# means something different scientifically:
#
#   EMPTY     every value NA          -- the field was never captured
#   CONSTANT  one distinct value      -- captured, but carries no information
#   VARIES    two or more values      -- usable, subject to coverage
#
# A second trap: coverage among PROFILES is not coverage of the COHORT. Most
# of the loss happens upstream, in the search stage, so a field can be 95%
# complete among fetched profiles and describe a third of the cohort.
#
# Sourced by build_table1_midwives.R; tested by tests/test_cycle6_field_quality.R.
# =============================================================================

#' Classify a field as EMPTY, CONSTANT or VARIES
#'
#' @param x [vector]: the column.
#' @return [list] n_distinct (non-NA), n_na, n, verdict.
field_variability <- function(x) {
  nd <- length(unique(x[!is.na(x)]))
  list(n_distinct = nd, n_na = sum(is.na(x)), n = length(x),
       verdict = if (nd == 0L) "EMPTY" else if (nd == 1L) "CONSTANT" else "VARIES")
}

#' Refuse to publish a field that carries no information
#'
#' Stops rather than warns. A constant column reaching a table produces a row
#' that looks like a finding ("0 years of experience, 100% of the cohort")
#' while being an artefact of what the source does not publish.
#'
#' @param x [vector]: the column.
#' @param name [character(1)]: field name, for the message.
#' @param allow_constant [logical(1)]: escape hatch for a field that is
#'   legitimately constant by construction; must be set deliberately.
#' @return [invisible(TRUE)] on success; stops otherwise.
assert_not_constant <- function(x, name, allow_constant = FALSE) {
  v <- field_variability(x)
  if (v$verdict == "VARIES" || isTRUE(allow_constant)) return(invisible(TRUE))
  stop(sprintf(paste0("%s is %s (%d distinct non-NA value%s across %d rows) and ",
                      "must not be published. A constant column is not a finding; ",
                      "it is what the source declines to populate. Set ",
                      "allow_constant = TRUE only if it is constant by design."),
               name, v$verdict, v$n_distinct,
               if (v$n_distinct == 1L) "" else "s", v$n), call. = FALSE)
}

#' Coverage of the COHORT, not of the rows that happen to exist
#'
#' @param value [vector]: attribute values, parallel to `key`.
#' @param key [character]: cohort identifier for each value.
#' @param cohort [character]: the full cohort of identifiers.
#' @return [list] n_cohort, n_with_value, pct.
cohort_coverage <- function(value, key, cohort) {
  stopifnot(length(value) == length(key))
  have <- unique(key[!is.na(value) & key %in% cohort])
  n <- length(unique(cohort))
  # Zero cohort would divide by zero; report 0 rather than NaN so a downstream
  # sprintf("%.1f%%") cannot print "NaN%" into a table.
  list(n_cohort = n, n_with_value = length(have),
       pct = if (n == 0L) 0 else 100 * length(have) / n)
}
