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
#' @examples
#' pad5(c(1001, 8031))          # "01001" "08031"
#' pad5("8031")                 # "08031" -- character input is safe too
#' @family identifier padding
pad5 <- function(x) {
  # An empty string is not a code, and padding it produces "00000" -- a county
  # FIPS that does not exist but joins perfectly to every other blank. pad_ccn()
  # below already treats blank as missing; this did not, which is the same
  # inconsistency that let a private `pad5` shadow this one. Blank in, NA out.
  x <- stringr::str_trim(as.character(x))
  x[!nzchar(x)] <- NA_character_
  stringr::str_pad(x, 5, "left", "0")
}

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
  # Guarding `is.na(x)` alone was never enough. "", "  ", "NA" and "N/A" all
  # survive that check, strip to zero digits, and pad to "00000" -- one shared,
  # perfectly joinable key for every record whose ZIP is missing. That is the
  # class-2 defect in a different costume: a missing value wearing the face of
  # a real one. If nothing is left after stripping, nothing is what comes back.
  digits <- stringr::str_sub(
    stringr::str_remove_all(as.character(x), "[^0-9]"), 1, 5)
  digits[is.na(digits) | !nzchar(digits)] <- NA_character_
  pad5(digits)
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
#' @examples
#' pad_ccn(c("1234", "01T001", "010001"))   # "001234" "01T001" "010001"
#' pad_ccn(c(NA, ""))                       # NA NA
#' @family identifier padding
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
#' @examples
#' \dontrun{
#' chr("artifacts/county_base.csv")$GEOID   # "01001", leading zero intact
#' }
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
#' @examples
#' fmt(1234.56, digits = 1)     # "1,234.6"
#' fmt(NA)                      # NULL -- so a whole clause can be gated
#' if (!is.null(fmt(NA))) "printed" else "clause suppressed"
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

# -----------------------------------------------------------------------------
# 2026-08-15. Four more names were defined in two files each, caught by the
# duplicate-definition ratchet in tests/test_cycle9_joins.R when it went 0 -> 4.
#
# Two had byte-identical bodies and are merged here. The other two -- normalize_state
# and find_column -- had DIVERGENT bodies, so they are deliberately NOT merged.
# Following the doctrine already stated at the top of this file: the strict and
# lenient versions are both wanted, and collapsing them would silently change a
# caller's semantics. They keep distinct names in their own files instead.
#
# The divergence, for the record:
#   normalize_state  R/resolve_amcb_by_state_license.R  trimws, exact match
#                    R/build_amcb_state_licenses.R      str_squish, plus
#                                                       "WASHINGTON DC" variants
#   find_column      R/resolve_amcb_by_state_license.R  case-SENSITIVE
#                    R/build_amcb_state_licenses.R      case-INSENSITIVE
#
# Merging either would have LOOSENED license-key construction -- more states
# resolved, more columns matched, therefore more license keys and more candidate
# matches. That is a linkage change, and a linkage change does not belong in a
# de-duplication commit.
# -----------------------------------------------------------------------------

#' Normalize an NPI to ten digits, or NA
#'
#' Strips every non-digit and rejects anything that is not exactly ten
#' characters. Identical bodies previously lived in
#' R/resolve_amcb_by_state_license.R and R/15-build-birth-activity.R.
#' @param x NPI vector, any type.
#' @return [character] ten-digit NPIs, NA where the input was not one.
normalize_npi <- function(x) {
  normalized <- stringr::str_replace_all(as.character(x), "[^0-9]", "")
  normalized[nchar(normalized) != 10L] <- NA_character_
  normalized
}

#' Format an integer with thousands separators
#' @param x Numeric vector.
#' @return [character]
fmt_n <- function(x) format(x, big.mark = ",", trim = TRUE)
