# =============================================================================
# Wilson score interval
# =============================================================================
# ONE DEFINITION, because two consumers now report intervals that a reader is
# meant to compare side by side: report_org_resolution_ppv.R (human-adjudicated
# PPV per resolution rule) and build_trilliant_org_concordance.R (machine
# concordance per rule). If those two computed their intervals differently the
# comparison would be meaningless in a way no test would catch, so the math
# lives here and tests/ci_hygiene.R's H4 refuses a second copy.
#
# WHY WILSON AND NOT THE NORMAL APPROXIMATION. At the sample sizes these
# reports use -- 25 adjudications per stratum -- the normal approximation is
# not usable: it produces intervals that run past 0 or 1 and understates the
# width near the boundaries, which is exactly where a rule at 25/25 sits.
#
# Note the other two intervals in this repository are deliberately NOT this
# function: manuscript/R/build_stats_catalog.R::mw_wilson() and
# tests/ci_science_nightly.R::scn_wilson() take a z multiplier rather than a
# confidence level and are pinned by their own tests. They are named apart on
# purpose; do not merge them into this one without reading those tests.
# =============================================================================

#' Wilson score interval for a binomial proportion.
#'
#' @param x number of successes.
#' @param n number of trials; `n = 0` yields `c(NA, NA)` rather than NaN, so a
#'   stratum with nothing adjudicated reports "no interval" instead of a
#'   spurious one.
#' @param conf confidence level, default 0.95.
#' @return length-2 numeric: lower and upper bound.
wilson <- function(x, n, conf = 0.95) {
  if (n == 0) return(c(NA_real_, NA_real_))
  z <- qnorm(1 - (1 - conf) / 2); p <- x / n
  d <- 1 + z^2 / n
  c((p + z^2/(2*n) - z*sqrt((p*(1-p) + z^2/(4*n))/n))/d,
    (p + z^2/(2*n) + z*sqrt((p*(1-p) + z^2/(4*n))/n))/d)
}

#' Wilson score interval, vectorised, as percentage bounds in a tibble
#'
#' Same interval as [wilson()] above, in the shape the reporting scripts
#' consume: `x` and `n` are vectors (one row per stratum), and the bounds come
#' back as percentages rounded to one decimal, clamped to [0, 100].
#'
#' TWO FUNCTIONS, ONE FORMULA, ON PURPOSE. [wilson()] is scalar -- its
#' `n == 0` guard is an `if`, which sees only the first element of a vector --
#' and returns proportions, because its callers print one interval per
#' adjudicated stratum. This one is vectorised and returns percentages,
#' because its callers `bind_cols()` it onto a whole summary table. Collapsing
#' them would mean one of the two call sites doing its own rounding or its own
#' recycling, which is how the three separate copies this replaces arose
#' (R/lib/migration_rate.R, audit_migration_corroboration_by_transition.R and
#' build_cross_source_comparison.R each had one; tests/ci_hygiene.R's H4
#' refuses that).
#'
#' Note `n == 0` here yields `NaN` bounds rather than [wilson()]'s `NA`: the
#' callers filter empty strata before summarising, and a silent 0-wide
#' interval at 0/0 would read as a real measurement.
#'
#' @param x,n Successes and trials, same length (vectorised).
#' @param conf Confidence level, default 0.95.
#' @return `tibble` with `ci_low`, `ci_high` (percentages, 0-100).
wilson_ci <- function(x, n, conf = 0.95) {
  z <- stats::qnorm(1 - (1 - conf) / 2)
  p <- x / n
  denom <- 1 + z^2 / n
  center <- (p + z^2 / (2 * n)) / denom
  halfwidth <- (z / denom) * sqrt(p * (1 - p) / n + z^2 / (4 * n^2))
  tibble::tibble(ci_low = round(100 * pmax(0, center - halfwidth), 1),
                 ci_high = round(100 * pmin(1, center + halfwidth), 1))
}
