#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests for R/lib/address_agreement_compare.R
# =============================================================================
# Pairs with the 20 entries this cycle adds to tests/mutation_catalogue.R.
# Each test below is written to go RED under one specific, plausible bug a
# competent person could introduce into address_agreement_compare.R -- not
# just to confirm the happy path. Run standalone:
#
#   Rscript tests/test_address_agreement_compare_saboteur.R
#
# Exercised against the catalogue:
#
#   Rscript tests/ci_mutation_testing.R
#   MUTATION_ID=aac-agree-equality-flipped Rscript tests/ci_mutation_testing.R
#   (... one per id below)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path("R", "lib", "address_agreement_compare.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
errors <- function(expr) inherits(tryCatch(expr, error = function(e) e), "error")

# -----------------------------------------------------------------------------
# shape_address(): column normalization
# -----------------------------------------------------------------------------
raw <- tibble(
  id_col = c("1111111111", "2222222222"),
  st_col = c(" co ", "CO"),
  ct_col = c("denver", "DENVER "),
  zip_col = c(" 802271234", "80227")
)
shaped <- shape_address(raw, "id_col", "st_col", "ct_col", "zip_col")

# aac-zip-trim-removed
chk(shaped$zip5[1] == "80227",
    "A1 a leading space on the zip column doesn't shift the substr(1,5) extraction")

# aac-zipmode-branches-swapped, aac-zip5-substr-truncated
chk(identical(shaped$zip5, c("80227", "80227")),
    "A2 default (\"substr\") mode reads the first 5 characters of a standalone zip column")

# aac-trailing5-regex-truncated (and confirms trailing5 mode picks the LAST
# 5 digits, not the first -- the fixture's street number is a decoy)
raw_dox <- tibble(id_col = "1111111111", st_col = "CO", ct_col = "DENVER",
                  zip_col = "12345 Main St, Denver, CO 80227")
shaped_dox <- shape_address(raw_dox, "id_col", "st_col", "ct_col", "zip_col", zip_mode = "trailing5")
chk(shaped_dox$zip5 == "80227",
    "A3 trailing5 mode reads the LAST 5 digits even when an earlier 5-digit run (a street number) exists")

# aac-state-upper-removed
chk(shaped$state[1] == "CO" && shaped$state[2] == "CO",
    "A4 state is upper-cased and whitespace-trimmed (\" co \" and \"CO\" both normalize to \"CO\")")

# aac-city-squish-removed
chk(shaped$city[1] == "DENVER" && shaped$city[2] == "DENVER",
    "A5 city is upper-cased and whitespace-squished (\"denver\" and \"DENVER \" both normalize to \"DENVER\")")

# aac-npi-col-ignored
raw_altnpi <- tibble(hg_npi = "9999999999", st_col = "CO", ct_col = "DENVER", zip_col = "80227")
chk(!errors(shape_address(raw_altnpi, "hg_npi", "st_col", "ct_col", "zip_col")),
    "A6 npi_col names which column holds the NPI -- works for a non-\"npi\"-named column")
chk(shape_address(raw_altnpi, "hg_npi", "st_col", "ct_col", "zip_col")$npi == "9999999999",
    "A7 ... and reads the actual value from that column, not a hardcoded \"npi\" column")

# aac-match-arg-removed, aac-zip-mode-default-swapped
chk(!errors(shape_address(raw, "id_col", "st_col", "ct_col", "zip_col")),
    "A8 (control) omitting zip_mode doesn't error")
chk(shape_address(raw, "id_col", "st_col", "ct_col", "zip_col")$zip5[1] == "80227",
    "A9 omitting zip_mode defaults to \"substr\" (first 5 chars), not \"trailing5\"")

# -----------------------------------------------------------------------------
# compare_two(): cascading-grain agreement
# -----------------------------------------------------------------------------
# Row 1: city agrees (DENVER/DENVER), zip agrees (80202/80202).
# Row 2: city disagrees (DENVER/BOULDER), zip disagrees (80202/80302).
# Row 3: city agrees (AURORA/AURORA), zip disagrees (80010/80011).
# Row 4: a's city is blank -- excluded from the CITY level only; its zip
#        (80010/80010) is non-blank on both sides and DOES agree.
# Verified directly: city comparable_n=3 agree_n=2 (66.7%); zip5
# comparable_n=4 agree_n=2 (50.0%); state comparable_n=4 agree_n=4 (100%).
a <- tibble(npi = c("1", "2", "3", "4"), state = rep("CO", 4),
           city = c("DENVER", "DENVER", "AURORA", ""),
           zip5 = c("80202", "80202", "80010", "80010"))
b <- tibble(npi = c("1", "2", "3", "4"), state = rep("CO", 4),
           city = c("DENVER", "BOULDER", "AURORA", "80011"),
           zip5 = c("80202", "80302", "80011", "80010"))
out <- compare_two(a, b, "test", "2026", "2026", "test_type")
city_row <- out[out$level == "city", ]
zip_row <- out[out$level == "zip5", ]

# aac-agree-equality-flipped
chk(city_row$agree_n == 2,
    "B1 city: 2 of 3 comparable rows agree (DENVER/DENVER, AURORA/AURORA; DENVER/BOULDER does not)")

# aac-comparable-drops-x-check, aac-join-key-overspecified (an over-specified
# join on state/city/zip5 would drop rows 2-4 from the join entirely before
# comparison even runs, since their city or zip5 differ between a and b --
# comparable_n would fall to 1, not 3)
chk(city_row$comparable_n == 3,
    "B2 city: row 4 (a's city is blank) is excluded from comparable_n; rows 2-3's genuine mismatches still join and get compared")

# aac-comparable-drops-y-check specifically (B2 above has a's city blank,
# b's non-blank -- catches a dropped nzchar(x) check, not a dropped
# nzchar(y) check, since x's blank already excludes that row either way).
# Here it's reversed: a's value is real, b's is blank.
y_blank_a <- tibble(npi = "7", state = "CO", city = "DENVER", zip5 = "80202")
y_blank_b <- tibble(npi = "7", state = "CO", city = "", zip5 = "80202")
y_blank_out <- compare_two(y_blank_a, y_blank_b, "test", "2026", "2026", "test_type")
chk(y_blank_out[y_blank_out$level == "city", "comparable_n"][[1]] == 0,
    "B3 a blank city on side B (not side A) is still excluded from comparable_n")

# aac-agree-ignores-blanks. A blank-vs-blank pair must contribute 0 to
# BOTH comparable_n and agree_n -- checking comparable_n alone isn't
# enough, since the NA-guard on agree_pct (B5 below) would mask a wrong
# agree_n when comparable_n is also 0. Mixed with one genuine
# non-agreeing comparable row so agree_pct is an observable, non-NA value.
blank_a <- tibble(npi = c("9", "10"), state = c("CO", "CO"),
                  city = c("DENVER", ""), zip5 = c("80202", "80202"))
blank_b <- tibble(npi = c("9", "10"), state = c("CO", "CO"),
                  city = c("BOULDER", ""), zip5 = c("80302", "80203"))
blank_out <- compare_two(blank_a, blank_b, "test", "2026", "2026", "test_type")
blank_city <- blank_out[blank_out$level == "city", ]
chk(blank_city$comparable_n == 1 && blank_city$agree_pct == 0,
    "B4 a blank-vs-blank city pair contributes to neither comparable_n nor agree_n (the one real, disagreeing row scores 0%, not inflated by the blank pair)")

# aac-denominator-wrong-base
chk(city_row$agree_pct == round(100 * 2 / 3, 1),
    "B5 agree_pct divides by comparable_n (3), not the full joined row count (4)")

# aac-na-guard-removed
empty_a <- tibble(npi = character(0), state = character(0), city = character(0), zip5 = character(0))
empty_out <- compare_two(a, empty_a, "test", "2026", "2026", "test_type")
pct <- empty_out[empty_out$level == "state", "agree_pct"][[1]]
chk(is.na(pct) && !is.nan(pct),
    "B6 zero comparable records reports a clean NA, not NaN (0/0)")

# aac-rounding-digits-dropped (66.7% rounds differently at 1 vs 0 decimals;
# zip5's 50.0% would not have distinguished these)
chk(city_row$agree_pct == 66.7 && city_row$agree_pct != round(66.7),
    "B7 agree_pct is rounded to one decimal place (66.7), not zero (67)")

# aac-na-coercion-x-removed: a genuinely missing (NA) city on side A,
# paired with a real value on side B.
na_a <- tibble(npi = "8", state = "CO", city = NA_character_, zip5 = "80202")
na_b <- tibble(npi = "8", state = "CO", city = "DENVER", zip5 = "80202")
na_out <- compare_two(na_a, na_b, "test", "2026", "2026", "test_type")
chk(na_out[na_out$level == "city", "comparable_n"][[1]] == 0,
    "B8 a genuinely missing (NA) city on side A is excluded from comparable_n, same as a blank string")

# aac-na-coercion-y-removed: the mirror case, NA on side B instead -- B8
# alone doesn't catch a coercion dropped only for side B, since side A's
# own (still-present) coercion already excludes that row either way.
na_a2 <- tibble(npi = "11", state = "CO", city = "DENVER", zip5 = "80202")
na_b2 <- tibble(npi = "11", state = "CO", city = NA_character_, zip5 = "80202")
na_out2 <- compare_two(na_a2, na_b2, "test", "2026", "2026", "test_type")
chk(na_out2[na_out2$level == "city", "comparable_n"][[1]] == 0,
    "B9 a genuinely missing (NA) city on side B is excluded from comparable_n, same as a blank string")

# aac-levels-default-missing-zip5
default_out <- compare_two(a, b, "test", "2026", "2026", "test_type")
chk("zip5" %in% default_out$level,
    "B10 the default levels argument (used by every compare_*_address.R caller without passing levels explicitly) still includes zip5")

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
