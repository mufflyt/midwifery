# =============================================================================
# Banding and parsing contracts for Table 1
# =============================================================================
# These rules were inline in build_table1_midwives.R, where they could not be
# tested against anything except the one artifact they happened to run on. Each
# one held only because the current data satisfies an assumption the code never
# enforced:
#
#   * every RUCC value is in 1-9, so a case_when whose final branch is TRUE
#     labelled anything unexpected "Nonmetropolitan, remote (RUCC 7-9)";
#   * every enumeration_date is mm/dd/yyyy, so a parser that takes the last
#     four digit characters found the year.
#
# Neither is guaranteed by the contract. A vintage of RUCC carrying 99 for
# "not classified", or an NPPES export in ISO format, would produce confidently
# mislabelled output rather than an error.
#
# Sourced by build_table1_midwives.R; tested by tests/test_table1_bands.R.
# =============================================================================

#' Extract a four-digit enumeration year from a date of unknown format
#'
#' NPPES has shipped both mm/dd/yyyy and yyyy-mm-dd. The year is located by
#' pattern rather than by position: taking the last four digit characters
#' silently returns month-and-day for an ISO date (2007-05-12 -> 0512), which
#' then fails the plausibility window and becomes NA. That is a silent,
#' total loss of the variable disguised as missingness.
#'
#' @param x [character|factor]: dates in mm/dd/yyyy, yyyy-mm-dd, or mm-dd-yyyy.
#' @param min_year,max_year [integer(1)]: plausibility window. NPI enumeration
#'   began in 2005, so anything earlier indicates a parse failure, not an
#'   early adopter.
#' @return [integer] year, NA where no plausible year is present.
parse_enum_year <- function(x, min_year = 2005L, max_year = 2100L) {
  s <- trimws(as.character(x))
  yr <- rep(NA_integer_, length(s))

  # ISO first: a leading four-digit group is the year by definition.
  iso <- grepl("^[0-9]{4}[-/]", s)
  yr[iso] <- suppressWarnings(as.integer(substr(s[iso], 1, 4)))

  # Otherwise take a trailing four-digit group (mm/dd/yyyy, mm-dd-yyyy).
  trail <- !iso & grepl("[0-9]{4}\\s*$", s)
  yr[trail] <- suppressWarnings(as.integer(
    sub(".*?([0-9]{4})\\s*$", "\\1", s[trail])))

  yr[!is.na(yr) & (yr < min_year | yr > max_year)] <- NA_integer_
  yr
}

#' Band years since NPI enumeration
#'
#' Boundaries are closed on the left: 5 is the first year of "5-9 years", not
#' the last of "<5 years". Values outside the plausible window are NA rather
#' than being absorbed into the terminal band, which would inflate ">=20
#' years" with parse failures.
#'
#' @param yrs [numeric]: years since enumeration.
#' @param max_plausible [numeric(1)]: NPI enumeration began in 2005.
#' @return [character] band label, NA where not classifiable.
band_years_since_enum <- function(yrs, max_plausible = 25) {
  yrs <- suppressWarnings(as.numeric(yrs))
  bad <- is.na(yrs) | !is.finite(yrs) | yrs < 0 | yrs > max_plausible
  out <- rep(NA_character_, length(yrs))
  out[!bad & yrs <  5] <- "<5 years"
  out[!bad & yrs >=  5 & yrs < 10] <- "5-9 years"
  out[!bad & yrs >= 10 & yrs < 15] <- "10-14 years"
  out[!bad & yrs >= 15 & yrs < 20] <- "15-19 years"
  out[!bad & yrs >= 20] <- ">=20 years"
  out
}

#' Band years observed in the NPPES panel
#'
#' This is a PRESENCE span, not a measure of clinical activity: the count of
#' years from first to last annual snapshot containing the NPI, inclusive. One
#' appearance is one year, not zero. The panel begins in 2007, so the terminal
#' band is censored by the panel window rather than by anyone's career, and it
#' cannot be read as ">=15 years of practice".
#'
#' @param yrs [numeric]: inclusive span in years, >= 1 where observed at all.
#' @return [character] band label, NA where not observed.
band_years_observed <- function(yrs) {
  yrs <- suppressWarnings(as.numeric(yrs))
  bad <- is.na(yrs) | !is.finite(yrs) | yrs < 1
  out <- rep(NA_character_, length(yrs))
  out[!bad & yrs <  5] <- "<5 years"
  out[!bad & yrs >=  5 & yrs < 10] <- "5-9 years"
  out[!bad & yrs >= 10 & yrs < 15] <- "10-14 years"
  out[!bad & yrs >= 15] <- ">=15 years"
  out
}

#' Band a county by RUCC 2023 code
#'
#' A code outside 1-9 is not classifiable and returns NA. The inline version
#' used a trailing TRUE branch, so any unexpected code -- 0, 10, 99, a
#' sentinel for "not classified" -- was labelled "Nonmetropolitan, remote
#' (RUCC 7-9)". A rurality misclassification is not cosmetic here: rurality is
#' the stratifier for the access findings.
#'
#' This rule existed in three places -- build_table1_midwives.R,
#' represented_subset_access.R and characterize_isochrone_representation.R --
#' each with the same defect and TWO different label vocabularies ("Metropolitan"
#' vs "Metro"). Callers therefore pass their own labels rather than having
#' published output silently renamed; the validation is what is shared.
#'
#' @param rucc [numeric|character|factor]: RUCC 2023 code.
#' @param labels [character(3)]: labels for metro, adjacent, remote.
#' @return [character] band label, NA where the code is not valid.
RURALITY_LABELS_LONG <- c("Metropolitan (RUCC 1-3)",
                          "Nonmetropolitan, adjacent (RUCC 4-6)",
                          "Nonmetropolitan, remote (RUCC 7-9)")
RURALITY_LABELS_SHORT <- c("Metro (RUCC 1-3)",
                           "Nonmetro, adjacent (RUCC 4-6)",
                           "Nonmetro, remote (RUCC 7-9)")
# CYCLE 2. A THIRD vocabulary, used by the cohort-flow scripts (02, 05, 07),
# which cycle 1's sweep did not reach. It differs from _SHORT only in dropping
# "RUCC" from the second and third labels -- close enough to look like a typo
# and far enough to change a published column. Kept verbatim rather than
# unified, for the same reason the other two were.
RURALITY_LABELS_COHORT <- c("Metro (RUCC 1-3)",
                            "Nonmetro, adjacent (4-6)",
                            "Nonmetro, remote (7-9)")

band_rurality <- function(rucc, labels = RURALITY_LABELS_LONG) {
  stopifnot(length(labels) == 3L)
  # as.character() FIRST: as.integer() on a factor returns the level index, so
  # factor("7") silently becomes 2 and a remote county is published as
  # metropolitan. readxl and readr both hand back factors under some options.
  r <- suppressWarnings(as.integer(as.character(rucc)))
  bad <- is.na(r) | r < 1 | r > 9
  out <- rep(NA_character_, length(r))
  out[!bad & r <= 3] <- labels[1]
  out[!bad & r >= 4 & r <= 6] <- labels[2]
  out[!bad & r >= 7] <- labels[3]
  out
}

#' Build a county -> RUCC lookup, refusing to guess
#'
#' The inline version applied distinct(county, .keep_all = TRUE), which keeps
#' whichever row sorted first when one FIPS carries two different codes. That
#' resolves a data conflict by file order -- a county could be Metropolitan or
#' Remote depending on how the vintage was sorted. Identical duplicates are
#' harmless and collapse silently; CONFLICTING duplicates stop the run.
#'
#' @param fips [character]: 5-character county FIPS.
#' @param rucc [numeric]: RUCC code.
#' @return [data.frame] one row per county: county, rucc.
build_rucc_lookup <- function(fips, rucc) {
  d <- data.frame(county = sprintf("%05s", trimws(as.character(fips))),
                  rucc = suppressWarnings(as.integer(as.character(rucc))),
                  stringsAsFactors = FALSE)
  d <- unique(d)
  conflict <- names(which(table(d$county) > 1))
  if (length(conflict)) {
    stop(sprintf(paste0("%d county FIPS carry conflicting RUCC codes (e.g. %s). ",
                        "Resolve the vintage; do not let row order decide ",
                        "whether a county is metropolitan."),
                 length(conflict), paste(utils::head(conflict, 3), collapse = ", ")),
         call. = FALSE)
  }
  d
}

#' Band a certification date into its decade
#'
#' @description
#' Replaces `paste0(str_sub(certification_date, -4, -2), "0s")`, which was
#' live in `R/07-cohort-composition.R:158`. That rule counts characters from
#' the end of the string, so it encodes a date FORMAT as an offset: the US
#' form `05/12/2007` yields "2000s", while the ISO form `2007-05-12` yields
#' **"5-10s"**. Both forms have shipped from the registry, and the failure is
#' silent -- a garbage decade is still a character string, so it groups and
#' tabulates without complaint.
#'
#' Same class as the enumeration-year defect fixed in cycle 1. Parsing is
#' delegated to `parse_enum_year()` rather than reimplemented, so the two
#' cannot drift apart.
#'
#' @param x [character|factor]: certification dates in any format
#'   `parse_enum_year()` accepts.
#' @param min_year,max_year [integer(1)]: plausibility window. Certification
#'   predates NPI enumeration, so this defaults wider than `parse_enum_year()`.
#' @return [character] decade label such as "2000s"; `NA` where no plausible
#'   year is present. Zero-length input returns zero-length **character**.
#' @family table1-bands
#' Band Healthgrades age into 10-year groups
#'
#' @param age [numeric|character]: age in years as reported by Healthgrades.
#' @return [character] band label, NA where not classifiable.
band_hg_age <- function(age) {
  a <- suppressWarnings(as.numeric(as.character(age)))
  bad <- is.na(a) | !is.finite(a) | a < 18 | a > 120
  out <- rep(NA_character_, length(a))
  out[!bad & a <  35] <- "<35 years"
  out[!bad & a >= 35 & a < 45] <- "35-44 years"
  out[!bad & a >= 45 & a < 55] <- "45-54 years"
  out[!bad & a >= 55 & a < 65] <- "55-64 years"
  out[!bad & a >= 65] <- ">=65 years"
  out
}

band_cert_decade <- function(x, min_year = 1950L, max_year = 2100L) {
  y <- parse_enum_year(x, min_year = min_year, max_year = max_year)
  # NOT ifelse(): it is type-unstable on zero-length input, returning
  # logical(0) rather than character(0), which then poisons a downstream
  # bind_rows() or factor() with the wrong column type. Caught by T12a.
  out <- rep(NA_character_, length(y))
  ok <- !is.na(y)
  out[ok] <- paste0(as.integer(y[ok] %/% 10L) * 10L, "s")
  out
}
