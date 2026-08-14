# =============================================================================
# Helpers that were defined in more than one pipeline script
# =============================================================================
# The numbered scripts are sourced in sequence into the same environment, so a
# helper defined twice is not two private copies -- it is one name whose
# meaning depends on LOAD ORDER. Four helpers were duplicated with identical
# bodies (harmless today, a divergence waiting to happen) and one, `%||%`, had
# already diverged:
#
#   R/03-geography-hierarchy.R   if (is.null(a)) b else a
#   R/14-geocode-ob-fallbacks.R  if (is.null(a) || length(a) == 0 || all(is.na(a))) b else a
#
# Same name, different answers for `NA %||% x` and `character(0) %||% x`, with
# the winner decided by which file was sourced last. That is the failure mode
# this project has hit repeatedly: a fix applied to one copy is a fix applied
# to none.
#
# The two `%||%` behaviours are BOTH wanted, in different places, so they are
# not merged -- merging would silently change one caller's semantics. They get
# distinct names instead: `%||%` keeps the standard null-coalesce, and the
# missing-aware variant becomes `%|na|%`, which says what it does.
#
# Sourced by the numbered pipeline scripts; tested by tests/test_cycle9_joins.R.
# =============================================================================

#' Pad a FIPS-like code to five characters
#' @param x [vector]: code.
#' @return [character] zero-padded to width 5.
pad5 <- function(x) stringr::str_pad(as.character(x), 5, "left", "0")

#' Reduce a postal ZIP to its five-digit join key
#'
#' pad5() alone is NOT this. A ZIP arrives as "02134-1234", " 02134 " or 2134,
#' and the three cases must collapse to one key or a comparison invents
#' disagreements that do not exist -- which is what the address-provenance guard
#' exists to detect, so a wrong key there manufactures the very failures it
#' reports. Strip non-digits, take the first five, then pad: ZIP+4 truncates, a
#' lost leading zero is restored, and surrounding space disappears.
#'
#' Named because eight production sites had spelled the same three-call
#' composition out by hand and a test had re-implemented it privately -- under
#' the name `pad5`, shadowing the helper above with different behaviour.
#' @param x [vector]: ZIP as recorded.
#' @return [character] five digits, NA preserved.
zip5_key <- function(x) {
  y <- pad5(stringr::str_sub(stringr::str_remove_all(as.character(x), "[^0-9]"),
                             1, 5))
  ifelse(is.na(x), NA_character_, y)
}

#' Pad a CMS Certification Number (CCN) to six characters
#'
#' A CCN is a six-character identifier and is NOT a number: 10,290 rows of the
#' CMS facility-affiliation file and 164 rows of cms_hospital_info carry a
#' letter (e.g. "01T001" for a swing-bed unit). Coercing through as.integer()
#' to zero-pad -- the obvious-looking move -- turns every one of those into NA
#' and silently drops the facility from any join. Pad the string instead.
#' @param x [vector]: CCN.
#' @return [character] zero-padded to width 6, NA preserved.
pad_ccn <- function(x) {
  x <- stringr::str_trim(as.character(x))
  x[!nzchar(x)] <- NA_character_
  stringr::str_pad(x, 6, "left", "0")
}

#' Read a CSV with every column as character
#'
#' Type guessing is the enemy of an identifier: readr reads a column of bare
#' F/M as logical, and a FIPS code as a number that loses its leading zero.
#' @param f [character(1)]: path.
#' @return [tbl_df]
chr <- function(f) readr::read_csv(f, show_col_types = FALSE,
                                   col_types = readr::cols(.default = readr::col_character()))

#' Format one number for a sentence, or return NULL if it is not printable
#'
#' Returns NULL rather than "NA" so callers can gate a whole clause on
#' availability -- a sentence that says "NA per 1,000" is worse than no
#' sentence.
#' @param x [numeric(1)]: value.
#' @param digits [integer(1)]: decimal places.
#' @param big [logical(1)]: thousands separator.
#' @return [character(1)] or NULL.
fmt <- function(x, digits = 0, big = TRUE) {
  if (is.null(x) || length(x) != 1L || is.na(x)) return(NULL)
  formatC(round(x, digits), format = "f", digits = digits,
          big.mark = if (big) "," else "")
}

#' Evaluate an expression with the working directory set to the isochrones repo
#' @param expr [expression]: evaluated with `ISO` as the working directory.
#' @return the value of `expr`.
with_iso_wd <- function(expr) {
  old <- getwd()
  setwd(ISO)
  on.exit(setwd(old), add = TRUE)
  force(expr)
}

#' Null-coalesce: the STANDARD meaning
#'
#' Replaces only NULL. `NA %||% 5` is NA, because NA is a value -- a recorded
#' "we looked and it is missing" is not the same as "we never looked".
#' @param a,b any.
#' @return `b` if `a` is NULL, else `a`.
`%||%` <- function(a, b) if (is.null(a)) b else a

#' Missing-coalesce: NULL, empty OR all-NA
#'
#' The variant R/14-geocode-ob-fallbacks.R needs, named so that a reader can
#' see it is not the standard operator. Use where an all-NA vector should fall
#' through to a fallback -- a geocode that returned nothing usable, say.
#' @param a,b any.
#' @return `b` if `a` is NULL, length 0, or entirely NA; else `a`.
`%|na|%` <- function(a, b) {
  if (is.null(a) || length(a) == 0L || all(is.na(a))) b else a
}
