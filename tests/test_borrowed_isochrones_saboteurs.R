#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs borrowed directly from /isochrones and run against the SAME code
# =============================================================================
# R/lib/isochrones_dep.R::load_isochrones_name_tools() does not vendor a copy
# of luhn_check_npi() -- it live-sources R/utils/npi_luhn_qa.R out of the
# isochrones checkout every time. So there is no "drift" question here: this
# file runs isochrones' own test vectors (from
# ~/isochrones/tests/testthat/test-npi-luhn-qa.R, cases C1-C8) against the
# exact function isochrones' own suite tests, just invoked from this repo.
#
# NOT INCLUDED, AND WHY: rank_one_to_one() is the higher-value target --
# unlike luhn_check_npi(), match_amcb_to_npi.R VENDORS its own copy (commit
# message: "replace a cross-repo source() of the same, pre-existing
# function"), so it is exactly the kind of copy that COULD have drifted from
# isochrones' ~/isochrones/tests/testthat/test-rank-one-to-one-bva.R
# expectations. It was not portable today: the function is defined inline in
# match_amcb_to_npi.R, a full pipeline script, immediately followed by a
# top-level guard (`for (fn in c("norm_name", "rank_one_to_one",
# "safe_pct")) if (!exists(fn)) stop(...)`) that only passes once norm_name()
# and safe_pct() are ALSO defined -- both earlier in that same script. Getting
# the function in isolation means either sourcing the whole pipeline script
# (unknown side effects, likely real file reads) or a fragile textual
# extraction. Flagged here as the identified next step, not forced into a
# brittle test today.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "isochrones_dep.R"))
load_isochrones_name_tools(quiet = TRUE)  # pulls in luhn_check_npi() live from ~/isochrones

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

cat("\n-- borrowed from isochrones tests/testthat/test-npi-luhn-qa.R (C1-C8) --\n")

# Same two CMS test-vector NPIs isochrones' own suite uses.
VALID_NPI_1 <- "1234567893"
VALID_NPI_2 <- "1225032279"

# C1/C2. Known-valid NPIs return TRUE.
chk(isTRUE(luhn_check_npi(VALID_NPI_1)), "C1 luhn_check_npi() is TRUE for the first known-valid CMS test NPI")
chk(isTRUE(luhn_check_npi(VALID_NPI_2)), "C2 luhn_check_npi() is TRUE for the second known-valid CMS test NPI")

# C3. Changing only the check digit (893 -> 890) must flip the verdict to
# FALSE -- confirms the function is actually checking the Luhn digit, not
# just the length/format.
chk(!isTRUE(luhn_check_npi("1234567890")),
    "C3 a valid NPI with only its check digit changed is correctly rejected")

# C4. Format guard: not-10-digits in every direction (short, long, letter,
# empty) is FALSE, not an error.
chk(!isTRUE(luhn_check_npi("12345")) && !isTRUE(luhn_check_npi("12345678901")) &&
    !isTRUE(luhn_check_npi("123456789X")) && !isTRUE(luhn_check_npi("")),
    "C4 too-short, too-long, letter-containing, and empty strings are all FALSE, not errors")

# C5. Numeric input (not just character) is accepted and coerced internally
# -- a real risk given this repo reads NPIs from mixed-type CSV columns.
chk(isTRUE(luhn_check_npi(as.numeric(VALID_NPI_1))),
    "C5 numeric input is accepted and validated the same as character input")

# C6. All-zeros is a format-valid but semantically-impossible NPI; must be
# FALSE, not accepted merely for having the right length and passing
# Luhn's arithmetic coincidentally.
chk(!isTRUE(luhn_check_npi("0000000000")), "C6 all-zeros is rejected despite being 10 digits")

# C7. Vectorized consistency: if a batch/vectorized path exists in the
# sourced file, it must agree with the scalar function element-wise --
# checked defensively since this file does not vendor luhn_validate_batch()
# into any `needed` list and its presence is not guaranteed.
if (exists("luhn_validate_batch", mode = "function")) {
  npis <- c(VALID_NPI_1, VALID_NPI_2, "1234567890", "9999999999")
  batch <- luhn_validate_batch(npis)
  elementwise <- vapply(npis, luhn_check_npi, logical(1))
  chk(identical(unname(batch), unname(elementwise)),
      "C7 luhn_validate_batch() agrees with element-wise luhn_check_npi() on a mixed vector")
} else {
  chk(TRUE, "C7 skipped: luhn_validate_batch() not loaded by load_isochrones_name_tools() (luhn_check_npi only)")
}

# C8. A real cohort NPI (not a synthetic test vector) from this project's
# own frozen linkage must also pass -- confirms the function works on this
# project's actual data shape, not just isochrones' CMS examples.
real_npi <- "1629453816"  # Hawa Al-Hassan, CNM2738 -- used earlier this session
chk(isTRUE(luhn_check_npi(real_npi)),
    "C8 a real AMCB-cohort NPI from this project's own data passes the Luhn check")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
