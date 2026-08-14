# =============================================================================
# Address, ZIP and phone join keys for organisation matching
# =============================================================================
# WHY THIS FILE EXISTS. Four scripts defined `norm_addr`, three defined `zip5`,
# two each `zip9` and `phone10` -- and they did not agree. Two scripts keying
# the same address could therefore produce different keys and different
# affiliations, with nothing in either script saying so. Every definition now
# lives here.
#
# THE DISAGREEMENTS ARE PRESERVED, NOT RESOLVED AWAY. Where two call sites
# genuinely wanted different behaviour, the variant is a separate function with
# a name that says what it does, so a reader picks one on purpose. Silently
# imposing one behaviour would have changed match counts in a pipeline whose
# outputs are already published, which is a research finding changing, not a
# refactor.
#
# Sourced by: link_practice_locations_to_org_npi.R, resolve_org_ambiguity.R,
# match_open_payments_to_facility.R, build_rigorous_hospital_attributions.R.

suppressPackageStartupMessages(library(stringr))

.ADDR_ABBREV <- c(
  "\\bSTREET\\b" = "ST",   "\\bAVENUE\\b" = "AVE",  "\\bROAD\\b"     = "RD",
  "\\bDRIVE\\b"  = "DR",   "\\bBOULEVARD\\b" = "BLVD", "\\bPLACE\\b" = "PL",
  "\\bLANE\\b"   = "LN",   "\\bCOURT\\b"  = "CT",   "\\bPARKWAY\\b" = "PKWY",
  "\\bHIGHWAY\\b" = "HWY", "\\bSUITE\\b"  = "STE",  "\\bNORTH\\b"   = "N",
  "\\bSOUTH\\b"  = "S",    "\\bEAST\\b"   = "E",    "\\bWEST\\b"    = "W")

#' Normalise a street address into a join key, KEEPING the unit
#'
#' Uppercases, replaces punctuation with space, abbreviates street types and
#' directionals. Suite and unit designators are abbreviated ("SUITE" -> "STE")
#' but NOT removed: two suites in one building are different workplaces, and
#' merging them asserts an affiliation the source does not record.
#'
#' This is the behaviour three of the four original copies had.
#' @param x [vector]: address as recorded.
#' @return [character] key, NA where empty.
norm_addr <- function(x) {
  y <- toupper(str_trim(as.character(x)))
  y <- str_replace_all(y, "[.,#]", " ")
  y <- str_replace_all(y, "\\s+", " ")
  for (p in names(.ADDR_ABBREV)) y <- str_replace_all(y, p, .ADDR_ABBREV[[p]])
  y <- str_trim(str_replace_all(y, "\\s+", " "))
  y[!nzchar(y)] <- NA_character_
  y
}

#' Normalise a street address, DROPPING the suite or unit
#'
#' Everything from "SUITE", "STE" or "#" onward is discarded, so every unit in
#' a building collapses to one key. That is the right key when matching a
#' clinician to a BUILDING -- a hospital campus address recorded with and
#' without a suite is one place -- and the wrong key when distinguishing
#' tenants. build_rigorous_hospital_attributions.R wants the former.
#'
#' Kept as a separate function rather than a flag on norm_addr() because the
#' choice changes which affiliations are found, and a flag defaulting either
#' way would let a caller inherit the wrong one without noticing.
#' @param x [vector]: address as recorded.
#' @return [character] key with the unit removed.
norm_addr_drop_unit <- function(x) {
  y <- str_to_upper(trimws(as.character(x)))
  y <- str_replace_all(y, "\\bAVENUE\\b", "AVE")
  y <- str_replace_all(y, "\\bSTREET\\b", "ST")
  y <- str_replace_all(y, "\\bROAD\\b", "RD")
  y <- str_replace_all(y, "\\bBOULEVARD\\b", "BLVD")
  y <- str_replace_all(y, "\\bDRIVE\\b", "DR")
  y <- str_replace_all(y, "\\bPARKWAY\\b", "PKWY")
  y <- str_replace_all(y, "\\bSUITE\\b.*|\\bSTE\\b.*|#.*", "")
  str_trim(y)
}

#' Five-digit ZIP key from any ZIP representation
#'
#' Strips non-digits and takes the first five, returning NA when fewer than
#' five digits are present. NOT the same as zip5_key() in common_helpers.R,
#' which PADS a short value: padding is right for a FIPS-like code, and wrong
#' here, where "2134" is a damaged record rather than a ZIP whose leading zero
#' was eaten by a spreadsheet -- inventing "02134" would forge a match.
#' @param x [vector]: ZIP as recorded.
#' @return [character] five digits, or NA.
zip5 <- function(x) {
  d <- str_remove_all(as.character(x), "[^0-9]")
  ifelse(!is.na(d) & nchar(d) >= 5, substr(d, 1, 5), NA_character_)
}

#' Five-digit ZIP key, taken as the first five-digit RUN
#'
#' Differs from zip5() only on damaged input: "021 34" and "1234-5" yield NA
#' here and "02134"/"12345" from zip5(), because this reads the string as
#' written rather than concatenating its digits. Strictly the safer reading
#' when the field might not be a bare ZIP; the looser one recovers more rows.
#'
#' Retained as its own function because match_open_payments_to_facility.R was
#' written against it and its published match counts were produced with it.
#' The two should be reconciled deliberately, with the row-count difference
#' measured -- not merged during a cleanup.
#' @param x [vector]: ZIP as recorded.
#' @return [character] five digits, or NA.
zip5_first_run <- function(x) str_extract(as.character(x), "[0-9]{5}")

#' Nine-digit ZIP+4 key
#'
#' All nine digits must be present. A five-digit value must never masquerade as
#' a ZIP+4 match, which would silently weaken the strongest address key into
#' the weakest one.
#' @param x [vector]: ZIP as recorded.
#' @return [character] nine digits, or NA.
zip9 <- function(x) {
  # `>= 9` truncated instead of refusing: a ten-digit value -- an NPI pasted
  # into a ZIP column, a ZIP+4 with a stray digit -- silently became a
  # well-formed ZIP+4 belonging to somebody else. phone10() below already
  # requires an exact length for exactly this reason. Match it.
  d <- str_remove_all(as.character(x), "[^0-9]")
  ifelse(!is.na(d) & nchar(d) == 9, d, NA_character_)
}

#' Ten-digit phone key
#'
#' Drops a leading country code of 1, then requires exactly ten digits. Any
#' other length is NA rather than a truncation: a nine-digit phone is a data
#' error, and padding or trimming it would match somebody.
#' @param x [vector]: phone as recorded.
#' @return [character] ten digits, or NA.
phone10 <- function(x) {
  d <- str_remove_all(as.character(x), "[^0-9]")
  d <- ifelse(!is.na(d) & nchar(d) == 11 & substr(d, 1, 1) == "1",
              substr(d, 2, 11), d)
  ifelse(!is.na(d) & nchar(d) == 10, d, NA_character_)
}
