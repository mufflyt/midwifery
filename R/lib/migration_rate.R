#' Year-over-year migration rate and Wilson 95% CI, shared by
#' build_migration_rate_by_method.R and build_leave_one_source_out_
#' sensitivity.R (previously duplicated in both; factored out here).

#' Wilson 95% confidence interval for a proportion
#'
#' Same formula build_cross_source_comparison.R and
#' audit_migration_corroboration_by_transition.R already use.
#'
#' @param x,n Successes and trials, same length (vectorized).
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

#' Year-over-year move rate for one (npi, year, state) panel
#'
#' A transition counts only where BOTH years have a known state for that
#' npi ("valid pair") -- a missing year (NPPES snapshot absent, or a
#' fusion method abstained) is excluded from that transition's denominator
#' entirely, never backfilled from another year or method.
#'
#' @param states_df `data.frame` with `npi`, `year`, `state`.
#' @param years Integer vector of years to form consecutive transitions
#'   from (e.g. `2013:2026`); `length(years) - 1` transitions are returned.
#' @return `tibble` with `year_from`, `year_to`, `n_pairs`, `n_moved`,
#'   `pct_moved`, `ci_low`, `ci_high` -- one row per transition with
#'   `n_pairs > 0`.
compute_migration_rates <- function(states_df, years) {
  rates <- dplyr::bind_rows(lapply(years[-length(years)], function(y) {
    before <- states_df[states_df$year == y, c("npi", "state")]
    names(before)[2] <- "state_before"
    after <- states_df[states_df$year == y + 1, c("npi", "state")]
    names(after)[2] <- "state_after"
    pairs <- merge(before, after, by = "npi")
    n_pairs <- nrow(pairs)
    n_moved <- sum(pairs$state_before != pairs$state_after)
    tibble::tibble(year_from = y, year_to = y + 1, n_pairs = n_pairs, n_moved = n_moved,
                   pct_moved = if (n_pairs > 0) round(100 * n_moved / n_pairs, 2) else NA_real_)
  }))
  rates <- rates[rates$n_pairs > 0, , drop = FALSE]
  dplyr::bind_cols(rates, wilson_ci(rates$n_moved, rates$n_pairs))
}
