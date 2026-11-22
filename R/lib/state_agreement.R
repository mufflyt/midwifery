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
# PAIRING IS PART OF THE ARITHMETIC. Neither function below could see what
# YEAR it was comparing. state_agreement_current_only() took the registry
# with its year column already stripped by the caller and a free-text
# `as_of_label` that nothing checked, so handing it a 2019 source and the
# 2026 registry produced a row stamped `year = 2026` and published it as a
# 2026 comparison. state_agreement_same_year() joins on year and so cannot
# mismatch, but when the two year sets did not meet AT ALL it returned zero
# rows and the source simply left the agreement table. Both now state the
# years they paired and refuse a pairing they cannot justify, through the
# guard in R/lib/source_vintage.R that already existed for this and that
# nothing had ever called.
# =============================================================================

if (!exists("assert_same_vintage_year", mode = "function")) {
  source(file.path("R", "lib", "source_vintage.R"))
}

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
  # A SOURCE THAT SHARES NO YEAR WITH THE REGISTRY COMPARED NOTHING. The
  # inner join on (npi, year) makes a cross-year pairing impossible, which is
  # the point of it -- but when the two year sets are disjoint it yields zero
  # rows, this function returns a zero-row tibble, and bind_rows() in the
  # audit drops the source out of state_source_audit_agreement.csv with no
  # error and no empty row to notice. The source does not look wrong; it
  # looks absent, which is how a truncated or re-keyed input publishes a
  # smaller study. Named here rather than discovered by a reader counting
  # sources in the output.
  source_years <- sort(unique(stats::na.omit(source_rows$year)))
  registry_years <- sort(unique(stats::na.omit(registry$year)))
  if (!length(intersect(source_years, registry_years))) {
    stop(sprintf(paste0(
      "state_agreement_same_year(): '%s' shares no year with the registry, so ",
      "nothing was compared and the source would vanish from the agreement ",
      "table rather than fail.\n  source years:   %s\n  registry years: %s\n",
      "  Supply the years the source actually covers, or drop the source ",
      "deliberately -- an empty comparison must not be published as absence."),
      source_id,
      if (length(source_years)) paste(source_years, collapse = ", ") else "<none: the source has no dated rows>",
      if (length(registry_years)) paste(registry_years, collapse = ", ") else "<none>"),
      call. = FALSE)
  }
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
#' THE LABEL WAS AN ASSERTION, AND THE YEAR HAD BEEN THROWN AWAY. This joins
#' on `npi` alone, which is the only option for a source that carries no
#' year -- a scrape, a board roster, a FHIR pull. But `as_of_label` is free
#' text that lands in the output's `year` column, nothing checked it, and
#' the caller passed `registry_current` with its `year` column already
#' dropped. So the function was structurally incapable of knowing which
#' registry snapshot it had been handed: a 2019 source against the 2026
#' registry returned a row labelled 2026 and 0% agreement, and the 0% read
#' as the source disagreeing rather than as seven years of drift.
#'
#' `source_year` now has to be stated and `registry_current` has to carry
#' its own `year`, so the one is checked against the other instead of
#' against a sentence. The label stays, because "2026-11 (6 boards
#' harvested; ...)" says more than a year does -- it is now a caption on a
#' pairing that has been verified rather than the only evidence for it.
#'
#' @param source_id [character] name recorded in the output.
#' @param source_rows [data.frame] with `npi` and `state`.
#' @param registry_current [data.frame] with `npi`, `nppes_state` and `year`.
#' @param as_of_label [character] goes in the `year` column.
#' @param source_year [integer] the year the source's snapshot is FROM.
#' @param max_months [numeric] how far apart the two sides may be before the
#'   pairing is refused. Widen it deliberately to measure across a gap.
#' @return [tbl_df] a single row.
#' @export
state_agreement_current_only <- function(source_id, source_rows, registry_current,
                               as_of_label, source_year, max_months = 6) {
  if (!"year" %in% names(registry_current)) {
    stop(sprintf(paste0(
      "state_agreement_current_only(): the registry passed for '%s' carries no ",
      "year column, so which snapshot it is cannot be checked and the pairing ",
      "cannot be shown to be same-year. Pass the registry WITH its year rather ",
      "than selecting it away."), source_id), call. = FALSE)
  }
  registry_year <- unique(stats::na.omit(registry_current$year))
  if (length(registry_year) != 1L) {
    stop(sprintf(paste0(
      "state_agreement_current_only(): the registry passed for '%s' spans %d ",
      "year(s) (%s), so there is no single snapshot to compare against. This ",
      "function matches on npi alone; handing it several years silently pools ",
      "them and lets one midwife match a row from any of them."),
      source_id, length(registry_year),
      if (length(registry_year)) paste(sort(registry_year), collapse = ", ") else "none"),
      call. = FALSE)
  }
  assert_same_vintage_year(source_year, registry_year,
                           sprintf("%s, as of %s", source_id, as_of_label),
                           "the registry's current snapshot", max_months)
  # relationship = "many-to-one": a source may hold several rows for one
  # midwife (a board roster with two licences, a scrape with two profiles), the
  # registry holds exactly one -- this function refuses a registry spanning
  # more than one year above, and the caller slices one row per npi. Declaring
  # it makes a duplicated registry row an error instead of a silent
  # multiplication of the denominator. tests/test_cycle9_joins.R T89 caps the
  # number of joins under R/ that do NOT declare their cardinality, and this
  # one entered that directory when these functions were extracted from
  # build_state_source_audit.R, which is exactly the case the ratchet is for.
  compared <- source_rows %>%
    dplyr::inner_join(registry_current, by = "npi",
                      relationship = "many-to-one") %>%
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
