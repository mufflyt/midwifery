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
