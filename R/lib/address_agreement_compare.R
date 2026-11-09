# =============================================================================
# Pure helpers for the compare_*_address.R family
# =============================================================================
# No I/O -- so they can be tested on small fixtures instead of each
# comparison script's own gitignored, person-level inputs. Every
# compare_*_address.R script (PECOS/DAC-vs-NPPES, Healthgrades-vs-NPPES,
# Healthgrades-vs-PECOS, PECOS-vs-Doximity, PECOS-vs-BON) used to carry its
# own copy of both functions below -- five near-identical copies of the same
# ~20 lines, extracted here (2026-10-23) once a sixth comparison would have
# made it six.
#
# Tested by tests/test_address_agreement_compare_saboteur.R and exercised
# against tests/mutation_catalogue.R.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(stringr); library(purrr); library(tibble)})

#' Normalize one source's raw address columns into the common npi/state/
#' city/zip5 shape every compare_*_address.R script joins on.
#'
#' @param df A data frame with character columns (read with
#'   col_types = cols(.default = "c") upstream -- this does not coerce).
#' @param npi_col,city_col Column names in `df` to read.
#' @param state_col,zip_col Column name to read state/zip5 from, or NULL
#'   when the source has no such field at all -- e.g. California's BRN
#'   roster carries a city and county but no zip, AND no independent state
#'   field (every row is already scoped to CA by construction of the source
#'   itself, so reusing some other state value would be circular, not a
#'   genuine board-reported comparison). NULL produces NA for every row at
#'   that field, which compare_address_pair()'s nzchar() check already
#'   excludes from comparable_n at that level (the same NA path fixed
#'   2026-10-23 for the "genuinely missing, not merely blank" case) -- a
#'   source missing one field still contributes real rows at the others.
#' @param zip_mode "substr" (default): zip5 is the first 5 characters of
#'   zip_col -- what every source except Doximity provides (a standalone
#'   zip/zip+4 column). "trailing5": zip5 is the last 5 digits of zip_col --
#'   for Doximity's combined "City, ST ZIP5" city_zip field, which carries no
#'   standalone zip column at all. Ignored when zip_col is NULL.
#' @return tibble(npi, state, city, zip5) -- state/city upper-cased and
#'   whitespace-squished; zip5 not validated as numeric (NA/short input
#'   passes through, caught downstream by compare_address_pair()'s nzchar() check).
shape_address <- function(df, npi_col, state_col = NULL, city_col, zip_col = NULL,
                          zip_mode = c("substr", "trailing5")) {
  zip_mode <- match.arg(zip_mode)
  if (is.null(zip_col)) {
    zip5 <- rep(NA_character_, nrow(df))
  } else {
    # Trimmed once, shared by both branches below -- state/city already go
    # through str_squish(); zip_col didn't, until this line (2026-10-23): a
    # leading/trailing space would have shifted a substr(1,5) extraction by
    # one character. No source currently has that whitespace (checked
    # directly), so this is a defensive hardening, not a correction.
    zip_col_trimmed <- str_trim(df[[zip_col]])
    zip5 <- if (zip_mode == "substr") {
      str_sub(zip_col_trimmed, 1, 5)
    } else {
      str_extract(zip_col_trimmed, "[0-9]{5}$")
    }
  }
  state <- if (is.null(state_col)) rep(NA_character_, nrow(df)) else str_to_upper(str_squish(df[[state_col]]))
  tibble(npi = df[[npi_col]],
        state = state,
        city = str_to_upper(str_squish(df[[city_col]])),
        zip5 = zip5)
}

#' Cascading-grain address agreement between two already-shaped
#' (npi, state, city, zip5) tables, one row per level.
#'
#' Inner-joined by NPI: a midwife absent from either side contributes to
#' neither the numerator nor the denominator at any level. Within a joined
#' pair, a level counts toward `comparable_n` only when BOTH sides have a
#' non-blank value at that level -- a side that scraped or matched nothing
#' for a given field is excluded from that level's denominator entirely,
#' not scored as a disagreement.
#'
#' @param a,b tibble(npi, state, city, zip5) -- see shape_address().
#' @param label,year_a,year_b,comparison_type Passed straight through into
#'   every output row -- source_pair spells out both sides (and their
#'   vintage, where one exists) so it is unambiguous on sight which two
#'   things were compared.
#' @param levels Which of state/city/zip5 to report. Street was dropped
#'   from every comparison in this project (2026-10-23): free-text street
#'   formatting never agreed cleanly enough across any source pair checked
#'   to be worth reporting.
#' @return tibble, one row per `levels` entry: comparison_type, source_pair,
#'   year_a, year_b, level, comparable_n, agree_n, agree_pct (NA when
#'   comparable_n is 0, never NaN).
compare_address_pair <- function(a, b, label, year_a, year_b, comparison_type,
                        levels = c("state", "city", "zip5")) {
  joined <- inner_join(a, b, by = "npi", suffix = c("_a", "_b"))
  map_dfr(levels, function(lv) {
    x <- joined[[paste0(lv, "_a")]]; y <- joined[[paste0(lv, "_b")]]
    # nzchar(NA) is TRUE, not FALSE (confirmed interactively, not assumed --
    # R treats an NA_character_ as having a "non-zero-char" representation).
    # Left unguarded, a genuinely missing value on both sides would count
    # toward comparable_n (nzchar(NA)&nzchar(NA) = TRUE) while scoring as a
    # disagreement (NA == NA is NA, dropped from agree_n by na.rm) --
    # silently inflating the denominator instead of being excluded the way
    # this function's own contract (see @param levels) says it should be.
    # Coercing NA to "" first makes nzchar() behave as "has a real value"
    # again. Verified against every comparison currently run in this
    # project (2026-10-23): zero rows are affected today -- this guards
    # against a future, gappier source, not a correction to a number
    # already reported.
    x[is.na(x)] <- ""; y[is.na(y)] <- ""
    comparable <- sum(nzchar(x) & nzchar(y), na.rm = TRUE)
    agree <- sum(nzchar(x) & nzchar(y) & x == y, na.rm = TRUE)
    tibble(comparison_type = comparison_type, source_pair = label,
          year_a = year_a, year_b = year_b, level = lv,
          comparable_n = comparable, agree_n = agree,
          agree_pct = if (comparable > 0) round(100 * agree / comparable, 1) else NA_real_)
  })
}
