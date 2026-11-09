#' Year-over-year migration rate and Wilson 95% CI, shared by
#' build_migration_rate_by_method.R and build_leave_one_source_out_
#' sensitivity.R (previously duplicated in both; factored out here).

source(file.path("R", "lib", "wilson_interval.R"))  # wilson_ci()

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

#' Move rate between each CONSECUTIVE pair of an explicitly ordered set of
#' observation labels, not necessarily one calendar year apart -- same
#' "valid pair" logic as compute_migration_rates(), generalized for
#' sub-annual vintages (e.g. "2017-04", "2017-12", "2018-12").
#'
#' @param states_df `data.frame` with `npi`, a label column, `state`.
#' @param labels_ordered Character vector of labels in chronological order;
#'   `length(labels_ordered) - 1` transitions are returned.
#' @param label_col Name of the label column in `states_df`. Default `"vintage"`.
#' @return Same shape as `compute_migration_rates()`, with `period_from`/
#'   `period_to` instead of `year_from`/`year_to`.
compute_consecutive_rates <- function(states_df, labels_ordered, label_col = "vintage") {
  rates <- dplyr::bind_rows(lapply(seq_len(length(labels_ordered) - 1), function(i) {
    l1 <- labels_ordered[i]; l2 <- labels_ordered[i + 1]
    before <- states_df[states_df[[label_col]] == l1, c("npi", "state")]
    names(before)[2] <- "state_before"
    after <- states_df[states_df[[label_col]] == l2, c("npi", "state")]
    names(after)[2] <- "state_after"
    pairs <- merge(before, after, by = "npi")
    n_pairs <- nrow(pairs)
    n_moved <- sum(pairs$state_before != pairs$state_after)
    tibble::tibble(period_from = l1, period_to = l2, n_pairs = n_pairs, n_moved = n_moved,
                   pct_moved = if (n_pairs > 0) round(100 * n_moved / n_pairs, 2) else NA_real_)
  }))
  rates <- rates[rates$n_pairs > 0, , drop = FALSE]
  dplyr::bind_cols(rates, wilson_ci(rates$n_moved, rates$n_pairs))
}
