#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: R/resolve_amcb_by_state_license.R
# =============================================================================
# tests/test_license_resolution.R covers normalize_license_number() and
# normalize_state() at a basic level, but normalize_identifier(),
# find_column(), build_license_resolution_summary() and
# extract_nppes_license_slots() had ZERO direct coverage before this file --
# confirmed by grep, not assumed. These tests also surface two real findings:
# a US-territory gap in normalize_state(), and a genuinely-reachable path
# into build_license_resolution_summary()'s own invariant guard (confirming
# that safety net isn't dead code).
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(tibble); library(dplyr); library(stringr)})
source(file.path(root, "R", "resolve_amcb_by_state_license.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- normalize_identifier(): whitespace, case, absence --\n")
{
  got <- normalize_identifier(c("  abc123  ", "", NA, "XYZ"))
  chk(identical(got, c("ABC123", NA_character_, NA_character_, "XYZ")),
      sprintf("T1 whitespace is trimmed, case upper-cased, blank and NA both become NA [%s]",
              paste(got, collapse = "|")))
}

cat("\n-- find_column(): the column-name probe, under absence --\n")
{
  # T2. The normal case: a candidate present among several real columns.
  chk(identical(find_column(c("NPI", "State"), c("Provider License Number_1", "NPI")), "NPI"),
      "T2 find_column() returns the matching candidate when it is present")

  # T3. No candidate present at all -> NA, not an error and not an empty
  # character(0) that would break a caller expecting a scalar.
  got3 <- find_column(c("State"), c("Provider License Number_1", "NPI"))
  chk(is.na(got3) && length(got3) == 1L,
      "T3 no matching candidate returns a scalar NA, not character(0) or an error")

  # T4. An EMPTY `available` vector (e.g. a zero-column data frame slipped
  # through) must not crash the %in% lookup -- confirmed to degrade to NA
  # cleanly rather than erroring on an empty haystack.
  got4 <- find_column(character(0), c("NPI"))
  chk(is.na(got4) && length(got4) == 1L,
      "T4 an empty `available` column-name vector also returns scalar NA, not an error")

  # T5. Candidate PRIORITY: when multiple candidates are present, the first
  # one in `candidates` order wins, not the first one in `available` order --
  # this matters because extract_nppes_license_slots() relies on exactly
  # this ordering to prefer the human-readable NPPES header over the
  # machine-cleaned snake_case fallback.
  got5 <- find_column(c("provider_license_number_1", "Provider License Number_1"),
                      c("Provider License Number_1", "provider_license_number_1"))
  chk(identical(got5, "Provider License Number_1"),
      sprintf("T5 the first CANDIDATE (not the first available column) wins when both are present [%s]", got5))
}

cat("\n-- normalize_license_number(): leading-zero equivalence, pinned exactly --\n")
{
  got <- normalize_license_number(c("0007", "7", "A007", "NONE", "none", "  12-34 ", "0000"))
  chk(identical(got[1], got[2]) && got[1] == "7",
      sprintf("T6 '0007' and '7' normalise to the same key ('7'), the documented leading-zero equivalence [%s]", got[1]))
  chk(got[3] == "A007",
      "T7 a letter-prefixed license ('A007') is left untouched -- only all-digit remainders get leading zeros stripped")
  chk(is.na(got[4]) && is.na(got[5]),
      "T8 the literal sentinel strings 'NONE'/'none' both normalise to NA, case-insensitively")
  chk(got[6] == "1234",
      sprintf("T9 punctuation and internal whitespace are stripped entirely ('12-34' -> '%s')", got[6]))
  # T10. CONFIRMED EDGE CASE: an all-zero license number ('0000') strips to a
  # single '0', not NA and not ''. This is DIFFERENT from '7'/'0007' (which
  # agree with each other) and different from a blank/NA input (which goes
  # to NA) -- a license number that is genuinely the string "0000" is its
  # own, third outcome. Worth knowing explicitly rather than assuming it
  # either matches "7" or vanishes to NA.
  chk(identical(got[7], "0") && !is.na(got[7]) && got[7] != got[1],
      sprintf("T10 an all-zero license number ('0000') normalises to '0' -- distinct from both '7' and NA [%s]", got[7]))
}

cat("\n-- normalize_state(): a real US-territory gap --\n")
{
  got <- normalize_state(c("colorado", "CO", "Colorado ", "Puerto Rico", "ZZ",
                           NA, "district of columbia"))
  chk(identical(got[1:3], c("CO", "CO", "CO")),
      "T11 full state name, abbreviation, and trailing-whitespace variants all normalise to the same two-letter code")
  chk(identical(got[6], NA_character_) && identical(got[5], NA_character_),
      "T12 a genuinely unrecognised code ('ZZ') and an NA input both fail to NA")
  chk(identical(got[7], "DC"),
      "T13 'district of columbia' resolves via the special-cased DC alias this function explicitly adds")
  # T14. CONFIRMED FINDING: 'Puerto Rico' -- a real US jurisdiction that can
  # legitimately issue a midwifery or nursing license -- is NOT in this
  # function's lookup (only the 50 states plus the explicitly-added DC
  # alias). It fails to NA, indistinguishable from genuine garbage input
  # like 'ZZ'. Any AMCB certificant or NPPES record carrying a Puerto Rico
  # (or Guam, US Virgin Islands, etc.) license state would silently fail to
  # normalise here. Reported, not fixed: fixing the allowlist is a scope
  # decision for whoever owns this pipeline's jurisdiction coverage.
  chk(is.na(got[4]),
      sprintf("T14 CONFIRMED GAP: 'Puerto Rico' normalises to NA, identical to genuine garbage ('ZZ') -- US territories are not in the lookup [got %s]",
              if (is.na(got[4])) "NA" else got[4]))
}

cat("\n-- build_license_resolution_summary(): is the invariant guard reachable? --\n")
{
  # T15. Handing the function a WIDER license universe than the roster does
  # NOT trigger the guard, because in_frame() restricts every numerator to
  # roster_ids BEFORE counting -- the fix this function's own comment
  # describes. Confirms that specific, most-obvious attack is closed.
  roster <- tibble(amcb_id_license = c("A", "B"))
  wide_universe <- tibble(amcb_id_license = c("A", "B", "C", "D", "E", "F", "G", "H"))
  res15 <- build_license_resolution_summary(
    roster, wide_universe, tibble(amcb_id_license = character(0)), tibble(),
    tibble(), tibble(amcb_id_license = character(0), npi = character(0)))
  chk(all(res15$pct_of_amcb <= 100),
      sprintf("T15 a license universe 4x the roster's size does not exceed 100%% -- in_frame() restricts it first [%s]",
              paste(sprintf("%.0f", res15$pct_of_amcb), collapse = ",")))

  # T16. CONFIRMED: the guard IS reachable through a different, realistic
  # path -- quarantine_n is NOT distinct()-counted the way the other
  # numerators are, so several quarantine rows for the SAME few roster
  # people (a person flagged for multiple distinct reasons) legitimately
  # pushes the count above the roster size. The guard fires with the exact,
  # named diagnostic rather than publishing an impossible percentage.
  quarantine_many <- tibble(amcb_id_license = c("A", "A", "A", "A", "A", "B"))
  got16 <- tryCatch({
    build_license_resolution_summary(
      roster, tibble(amcb_id_license = character(0)),
      tibble(amcb_id_license = character(0)), quarantine_many, tibble(),
      tibble(amcb_id_license = character(0), npi = character(0)))
    "no error"
  }, error = function(e) conditionMessage(e))
  chk(grepl("INVARIANT", got16) && grepl("license_quarantine_rows", got16),
      sprintf("T16 the invariant guard IS reachable: multiple quarantine rows per person trips it with a named diagnostic [%s]", got16))
}

cat("\n-- extract_nppes_license_slots(): the NPI-presence gate --\n")
{
  # T17. A data frame with no recognisable NPI column at all must fail
  # loudly and immediately, before any per-slot work, rather than silently
  # returning zero rows that look like "nobody had a license".
  bad <- data.frame(SomeOtherColumn = "x")
  got17 <- tryCatch(extract_nppes_license_slots(bad), error = function(e) conditionMessage(e))
  chk(grepl("does not contain NPI", got17),
      sprintf("T17 missing the NPI column entirely fails loudly, not silently-empty [%s]", got17))

  # T18. FIXED (was a confirmed crash). An NPI-only frame with no
  # license/state columns at any slot used to crash with "Column `npi` not
  # found" -- every per-slot lapply iteration returned NULL, and
  # bind_rows() on an all-NULL list drops every column, including npi,
  # before the subsequent filter() ever runs. The function now short-
  # circuits to a typed, zero-row result with the expected five-column
  # schema instead of reaching bind_rows() on nothing.
  npi_only <- data.frame(NPI = c("1234567890"))
  got18 <- extract_nppes_license_slots(npi_only, max_slots = 2L)
  chk(is.data.frame(got18) && nrow(got18) == 0L &&
      identical(names(got18), c("npi", "license_state", "license_number", "taxonomy_code", "taxonomy_slot")),
      sprintf("T18 FIXED: an NPI-only frame with no license/state columns at any slot now returns a clean, correctly-typed 0-row result [%d rows, cols: %s]",
              nrow(got18), paste(names(got18), collapse = ",")))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
