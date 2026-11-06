#' Shared claims-table construction for the migration truth-fusion build
#'
#' Builds the long (entity_id, attribute, source_id, claimed_value,
#' reference_year) shape mysteryroster::attribute_claims_validate() and
#' attribute_truth_fusion() expect, for the FULL cohort panel (every
#' cohort NPI-year with at least one source reporting), not just movers.
#' Shared by build_truth_fusion_predictions.R and
#' build_leave_one_source_out_sensitivity.R so the two can't silently drift
#' out of sync on how claims are built.

#' Combine DAC and PECOS into one source_id, per-NPI-year
#'
#' DAC's address field is CMS-derived from PECOS enrollment directly (see
#' docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md S2) -- not
#' independent of each other. Agreement collapses to one combined claim;
#' disagreement yields NO combined claim for that NPI-year (an
#' unresolvable internal lineage conflict, never arbitrarily picked) --
#' the same disposition attribute_truth_fusion()'s own
#' on_source_conflict = "single_value" gives an internally conflicted
#' source, independently arrived at before this project's integration
#' with mysteryroster (see docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md).
#'
#' @param dac_df,pecos_df `data.frame` with `npi`, `year`, `state`, already
#'   deduplicated to `distinct(npi, year, state)` (so >1 row for one
#'   npi-year means a genuine multi-value claim from that source, not a
#'   repeat).
#' @return `data.frame` with `npi`, `year`, `state`, one row per
#'   (npi, year) where a combined value could be determined -- npi-years
#'   where DAC and PECOS both report but disagree are simply absent, not
#'   present with an `NA` state (a caller doing `distinct(npi, year)` on
#'   the SOURCE tables would otherwise undercount how many npi-years were
#'   genuinely attempted).
merge_dac_pecos_sources <- function(dac_df, pecos_df) {
  d <- dac_df %>% dplyr::rename(dac_state = state)
  p <- pecos_df %>% dplyr::rename(pecos_state = state)
  both <- dplyr::full_join(d, p, by = c("npi", "year"))
  both %>%
    dplyr::mutate(state = dplyr::case_when(
      is.na(dac_state) ~ pecos_state,
      is.na(pecos_state) ~ dac_state,
      dac_state == pecos_state ~ dac_state,
      TRUE ~ NA_character_
    )) %>%
    dplyr::filter(!is.na(state)) %>%
    dplyr::select(npi, year, state)
}

#' Expand merged (npi, state, interval_start, interval_end) enrollment
#' intervals into one (npi, year, state) claim row per calendar year each
#' interval overlaps
#'
#' An NPI with two DIFFERENT states' intervals both overlapping the same
#' calendar year (a real mid-year enrollment switch) produces TWO claim
#' rows for that (npi, year) -- a genuine multi-value claim, never
#' collapsed to one here; downstream callers (attribute_claims_validate(),
#' attribute_truth_fusion()) decide how to treat it, same as every other
#' source in this build.
#'
#' @param merged_intervals `data.frame` with `npi`, `state`,
#'   `interval_start`, `interval_end` (`Date`) -- the shape
#'   `mysteryroster`/`R/lib/medicaid_enrollment_intervals.R`'s
#'   `merge_enrollment_intervals()` already returns.
#' @param years Integer vector of calendar years to expand into.
#' @return `data.frame` with `npi`, `year`, `state`, one row per
#'   (interval, year-it-overlaps) pair, de-duplicated.
expand_intervals_to_year_claims <- function(merged_intervals, years) {
  if (nrow(merged_intervals) == 0)
    return(data.frame(npi = character(0), year = integer(0), state = character(0), stringsAsFactors = FALSE))
  year_bounds <- data.frame(year = years,
                             year_start = as.Date(sprintf("%d-01-01", years)),
                             year_end = as.Date(sprintf("%d-12-31", years)))
  out <- merge(merged_intervals, year_bounds, by = character(0))
  out <- out[out$interval_start <= out$year_end & out$interval_end >= out$year_start, c("npi", "year", "state")]
  unique(out)
}

#' Build the full long claims table for a set of named sources
#'
#' @param sources Named list of `data.frame`s, each with `npi`, `year`,
#'   `state` -- NOT pre-collapsed to one row per npi-year; a source with
#'   genuinely conflicting values for one npi-year should still carry all
#'   of them here, so attribute_claims_validate()/attribute_truth_fusion()
#'   can see and report the conflict rather than this function hiding it.
#' @param npi_filter Optional character vector of NPIs to restrict to
#'   (e.g. the cohort). `NULL` keeps every NPI present in `sources`.
#' @return `data.frame` in mysteryroster's expected claims shape:
#'   `entity_id`, `attribute` (always `"practice_state"`), `source_id`,
#'   `claimed_value`, `reference_year`.
build_truth_fusion_claims <- function(sources, npi_filter = NULL) {
  rows <- lapply(names(sources), function(src_name) {
    df <- sources[[src_name]]
    if (!is.null(npi_filter)) df <- df[df$npi %in% npi_filter, , drop = FALSE]
    if (nrow(df) == 0)
      return(data.frame(entity_id = character(0), attribute = character(0), source_id = character(0),
                         claimed_value = character(0), reference_year = integer(0), stringsAsFactors = FALSE))
    data.frame(entity_id = df$npi, attribute = "practice_state", source_id = src_name,
               claimed_value = df$state, reference_year = df$year, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
