#!/usr/bin/env Rscript
# =============================================================================
# Join keys: pad5, zip5_key, pad_ccn, norm_addr, zip5, zip9, phone10
# =============================================================================
# Deliberately HERMETIC. It reads no artifact, touches no network and needs
# only stringr, so it is the part of this suite that can run in CI. Every other
# test here loads a multi-megabyte artifact or reaches outside the repo (the
# name tests need ~/isochrones), which is why CI runs this one and not those.
#
# WHAT IT GUARDS. Key functions are where silent damage happens: a wrong key
# does not error, it just matches the wrong person or fails to match the right
# one, and the result reads as a finding. Three of these functions have already
# been duplicated with divergent behaviour in this repo -- pad5 was shadowed by
# a test, norm_addr existed four times, zip5 three -- so the properties that
# distinguish them are asserted here rather than left to a reader.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source("R/lib/common_helpers.R")
source("R/lib/address_keys.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- pad5 / zip5_key: padding is right for a code, wrong for a ZIP --\n")
chk(identical(pad5("123"), "00123"),        "pad5 zero-pads a short FIPS-like code")
chk(identical(zip5_key("02134-1234"), "02134"), "zip5_key truncates ZIP+4")
chk(identical(zip5_key(" 02134 "), "02134"),    "zip5_key strips surrounding space")
chk(identical(zip5_key("2134"), "02134"),   "zip5_key restores a lost leading zero")
chk(is.na(zip5_key(NA)),                    "zip5_key keeps NA missing rather than \"00000\"")

cat("\n-- zip5 vs zip5_key: the same input must NOT give the same answer --\n")
# This is the invariant that keeps the two from being merged by a future
# cleanup. zip5_key PADS, because a FIPS-like code loses leading zeros in
# spreadsheets. zip5 REFUSES, because in an address match "2134" is a damaged
# record and inventing "02134" forges a match against a real person.
chk(is.na(zip5("2134")) && identical(zip5_key("2134"), "02134"),
    "a 4-digit value: zip5 refuses it, zip5_key pads it")

cat("\n-- zip5 vs zip5_first_run: the documented divergence --\n")
chk(identical(zip5("021 34"), "02134"),     "zip5 concatenates digits, recovering a split ZIP")
chk(is.na(zip5_first_run("021 34")),        "zip5_first_run reads the string as written and refuses")
chk(identical(zip5_first_run("02134-1234"), "02134"),
    "both agree on well-formed ZIP+4")

cat("\n-- zip9: a 5-digit value must never pass as a ZIP+4 --\n")
chk(identical(zip9("02134-1234"), "021341234"), "zip9 accepts nine digits")
chk(is.na(zip9("02134")),                   "zip9 rejects five, so the strongest key cannot silently weaken")

cat("\n-- phone10 --\n")
chk(identical(phone10("+1 (617) 555-0100"), "6175550100"), "phone10 drops a leading country code")
chk(identical(phone10("617.555.0100"), "6175550100"),      "phone10 ignores punctuation")
chk(is.na(phone10("617555010")),            "phone10 rejects nine digits rather than padding into someone else's number")
chk(is.na(phone10("161755501000")),         "phone10 rejects twelve digits")

cat("\n-- norm_addr vs norm_addr_drop_unit: the unit decision --\n")
chk(identical(norm_addr("123 Main Street, Suite 4"), "123 MAIN ST STE 4"),
    "norm_addr abbreviates and KEEPS the unit")
chk(identical(norm_addr_drop_unit("123 Main Street Suite 4"), "123 MAIN ST"),
    "norm_addr_drop_unit discards the unit")
chk(!identical(norm_addr("1 Elm St Suite 2"), norm_addr("1 Elm St Suite 3")),
    "two suites in one building are DIFFERENT keys under norm_addr")
chk(identical(norm_addr_drop_unit("1 Elm St Suite 2"),
              norm_addr_drop_unit("1 Elm St Suite 3")),
    "the same two collapse to ONE key under norm_addr_drop_unit")
chk(identical(norm_addr("100 north main avenue"), "100 N MAIN AVE"),
    "directionals and street types abbreviate")
chk(is.na(norm_addr("")) && is.na(norm_addr("   ")),
    "an empty address is NA, not \"\", so it cannot join to another blank")

cat("\n-- pad_ccn: a CCN is not a number --\n")
chk(identical(pad_ccn("1T001"), "01T001"),  "a lettered CCN pads as a string")
chk(is.na(pad_ccn(NA)),                     "NA is preserved")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAIL",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
