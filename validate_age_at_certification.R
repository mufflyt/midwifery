#!/usr/bin/env Rscript
# =============================================================================
# Age-at-certification validator and covariate
# =============================================================================
#
# A free consistency check on an acquired year-of-birth against a field the
# scrape already provides: `certification_date` (format MM/YYYY). Their
# difference is age at certification, which:
#
#   * flags impossible records -- a birth year that makes someone certified at
#     12, or "born" before certification, or born in an implausible year -- so
#     bad year-of-birth values are caught before they enter any age-stratified
#     estimate; and
#   * is a useful covariate in its own right (cohort / career stage).
#
# Year of birth (not full DOB) is all this needs: age is a year-resolution
# quantity. Where a birth year was itself derived from an age-at-snapshot it
# carries a +/-1 year ambiguity, so the plausibility bounds are deliberately
# permissive -- this rejects the impossible, not the merely unusual.
#
# The function only annotates and summarizes; it does not drop rows. It expects
# a `birth_year` column, which the current scrape does NOT provide -- it is
# wired up ready for an acquired year-of-birth source.
# =============================================================================

#' Validate year-of-birth against certification date and derive age-at-cert
#'
#' Computes age at certification (`certification_year - birth_year`), assigns a
#' plausibility flag, and returns the annotated roster plus a summary. Rows are
#' never dropped; implausible ones are labelled for review.
#'
#' @param roster A data frame with a certification-date column and a birth-year
#'   column.
#' @param cert_date_col Certification-date column, format `MM/YYYY` (the scrape
#'   default). Any value containing a 4-digit year 18xx/19xx/20xx is parsed.
#' @param birth_year_col Year-of-birth column (integer or coercible).
#' @param id_col Row identifier column, carried through for review.
#' @param min_cert_age Below this age at certification is implausible.
#' @param max_cert_age Above this age at certification is implausible.
#' @param min_birth_year Birth years before this are implausible.
#' @param reference_year "Now" for the born-in-the-future check; defaults to the
#'   current calendar year.
#' @return A list: `data` (roster + `certification_year`, `age_at_certification`,
#'   `age_flag`) and `summary` (counts and percent by `age_flag`).
#' @export
validate_age_at_certification <- function(
    roster,
    cert_date_col = "certification_date",
    birth_year_col = "birth_year",
    id_col = "certification_number",
    min_cert_age = 22L,
    max_cert_age = 75L,
    min_birth_year = 1920L,
    reference_year = base::as.integer(
      base::format(base::Sys.Date(), "%Y")
    )
) {
  required <- c(cert_date_col, birth_year_col)
  missing_cols <- base::setdiff(required, base::names(roster))
  if (base::length(missing_cols) > 0L) {
    base::stop(
      "Missing columns: ",
      base::paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }

  parse_year <- function(x) {
    # First plausible 4-digit calendar year in the string.
    base::suppressWarnings(
      base::as.integer(
        stringr::str_extract(
          base::as.character(x),
          "(?:18|19|20)[0-9]{2}"
        )
      )
    )
  }

  out <- roster |>
    dplyr::mutate(
      certification_year = parse_year(.data[[cert_date_col]]),
      .birth_year_int = base::suppressWarnings(
        base::as.integer(.data[[birth_year_col]])
      ),
      age_at_certification = .data$certification_year -
        .data$.birth_year_int,
      age_flag = dplyr::case_when(
        base::is.na(.data$certification_year) |
          base::is.na(.data$.birth_year_int) ~ "incomplete",
        .data$.birth_year_int < min_birth_year |
          .data$.birth_year_int > reference_year ~
          "implausible_birth_year",
        .data$age_at_certification < 0L ~
          "born_after_certification",
        .data$age_at_certification < min_cert_age ~
          "implausibly_young_at_certification",
        .data$age_at_certification > max_cert_age ~
          "implausibly_old_at_certification",
        TRUE ~ "plausible"
      )
    ) |>
    # age_at_certification is only meaningful once both inputs parsed and the
    # birth year itself is plausible; otherwise blank it so it can't leak into
    # a downstream mean.
    dplyr::mutate(
      age_at_certification = dplyr::if_else(
        .data$age_flag %in% c("incomplete", "implausible_birth_year"),
        NA_integer_,
        .data$age_at_certification
      )
    ) |>
    dplyr::select(-".birth_year_int")

  total_n <- base::nrow(out)
  summary <- out |>
    dplyr::count(.data$age_flag, name = "n") |>
    # No if_else guard needed: if total_n were 0 there would be no rows here,
    # so the division is never evaluated on an empty denominator.
    dplyr::mutate(pct = 100 * .data$n / total_n) |>
    dplyr::arrange(dplyr::desc(.data$n))

  implausible_n <- out |>
    dplyr::filter(
      !.data$age_flag %in% c("plausible", "incomplete")
    ) |>
    base::nrow()

  base::message(
    "Age-at-certification: ",
    base::format(total_n, big.mark = ","),
    " rows; ",
    base::format(implausible_n, big.mark = ","),
    " flagged implausible (excludes incomplete)."
  )

  base::list(data = out, summary = summary)
}
