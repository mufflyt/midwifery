# =============================================================================
# Agreement against the reference registry: the arithmetic behind every
# published percentage in the state-source audit
# =============================================================================
# WHY THESE MOVED HERE. add_coverage(), agree_same_year() and
# agree_current_only() produced every pct_agree in the audit -- Table 5 and
# Figure 4 of the manuscript, Section 3 of the technical appendix, the
# fitted DAC trend -- and lived inside build_state_source_audit.R where
# nothing could call them without running the whole audit, so nothing ever
# tested them. They also closed over `nppes` and `nppes_current` from the
# enclosing script, which made them untestable in principle: the comparison
# target was invisible in the signature. Both are now arguments.
#
# WHAT n_comparable COUNTS, SAID PLAINLY. It counts ROWS, not people. A
# source with several rows for one midwife in one year contributes all of
# them. Open Payments 2025 holds 21,890 payment records for 4,324 midwives:
# the median midwife has 2 rows, one has 127, and the busiest tenth of the
# cohort carries 42% of the weight. The resulting percentage is therefore
# weighted by payment volume, not by person, and a reader who takes
# "n comparable = 21,759" for a count of midwives will be wrong by a factor
# of five.
#
# That is a defensible estimand -- "of all the places this source says she
# practises, how often does the registry agree" -- but it was never stated,
# and the technical appendix describes Open Payments coverage in NPI-years,
# which these numbers are not. So n_npis_comparable is reported alongside,
# and the two together make the weighting visible instead of implied.
# Changing WHICH estimand is published is a scientific decision and is not
# made here.
# =============================================================================

#' Rows and distinct identifiers a source contributes per year
#'
#' @param source_id [character] name recorded in the output.
#' @param source_rows [data.frame] with `npi` and `year`.
#' @return [tbl_df] source, year, n_rows, n_npis.
#' @export
add_coverage <- function(source_id, source_rows) {
  source_rows %>%
    dplyr::count(.data$year, name = "n_rows") %>%
    dplyr::left_join(
      source_rows %>% dplyr::distinct(.data$npi, .data$year) %>%
        dplyr::count(.data$year, name = "n_npis"),
      by = "year", relationship = "one-to-one") %>%
    dplyr::mutate(source = source_id) %>%
    dplyr::select("source", "year", "n_rows", "n_npis")
}

#' Agreement with the registry, matched within the same year
#'
#' @param source_id [character] name recorded in the output.
#' @param source_rows [data.frame] with `npi`, `year`, `state`.
#' @param registry [data.frame] with `npi`, `year`, `nppes_state`.
#' @return [tbl_df] one row per year.
#' @export
state_agreement_same_year <- function(source_id, source_rows, registry) {
  compared <- source_rows %>%
    dplyr::inner_join(registry, by = c("npi", "year"),
                      relationship = "many-to-one") %>%
    dplyr::filter(!is.na(.data$state), !is.na(.data$nppes_state))
  compared %>%
    dplyr::group_by(.data$year) %>%
    dplyr::summarise(
      n_comparable = dplyr::n(),
      n_npis_comparable = dplyr::n_distinct(.data$npi),
      n_agree = sum(.data$state == .data$nppes_state), .groups = "drop") %>%
    dplyr::mutate(
      source = source_id, comparison_basis = "same_year",
      year = as.character(.data$year),
      pct_agree = round(100 * .data$n_agree / .data$n_comparable, 1)) %>%
    dplyr::select("source", "year", "comparison_basis", "n_comparable",
                  "n_npis_comparable", "n_agree", "pct_agree")
}

#' Agreement with the registry's current snapshot, for sources with no year
#'
#' @param source_id [character] name recorded in the output.
#' @param source_rows [data.frame] with `npi` and `state`.
#' @param registry_current [data.frame] with `npi` and `nppes_state`.
#' @param as_of_label [character] goes in the `year` column.
#' @return [tbl_df] a single row.
#' @export
state_agreement_current_only <- function(source_id, source_rows, registry_current,
                               as_of_label) {
  compared <- source_rows %>%
    dplyr::inner_join(registry_current, by = "npi") %>%
    dplyr::filter(!is.na(.data$state), !is.na(.data$nppes_state))
  n_comparable <- nrow(compared)
  n_agree <- sum(compared$state == compared$nppes_state)
  tibble::tibble(
    source = source_id, year = as_of_label,
    comparison_basis = "current_only", n_comparable = n_comparable,
    n_npis_comparable = dplyr::n_distinct(compared$npi), n_agree = n_agree,
    # A SOURCE WITH NOTHING COMPARABLE REPORTS NA, NOT NaN. 0/0 is NaN, which
    # prints as "NaN" in a table and sorts unpredictably; NA is the honest
    # value and every downstream formatter already handles it.
    pct_agree = if (n_comparable == 0L) NA_real_ else
      round(100 * n_agree / n_comparable, 1))
}
