#!/usr/bin/env Rscript
# =============================================================================
# clean_state() full-name and combined-form translation contract
# =============================================================================
# Real NPPES practice_state values include full names ("CALIFORNIA",
# "NEW YORK") and a "XX - FULL NAME" combined form ("TX - TEXAS"), not just
# bare 2-letter codes. clean_state() must translate these to their real
# abbreviation rather than treating a real, unambiguous state as unparseable
# -- while still refusing anything that isn't genuinely a US state/territory
# (a typo, a foreign place, a military postal code, a disagreeing combined
# form, or a non-US "XX - name" like a Canadian province).
# =============================================================================
source(file.path("R", "lib", "clean_state.R"))

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}

chk(identical(clean_state("CA"), "CA"), "a bare valid code passes through unchanged")
chk(identical(clean_state("ca"), "CA"), "a bare valid code is upper-cased")
chk(identical(clean_state("  CA  "), "CA"), "a bare valid code is trimmed")

chk(identical(clean_state("CALIFORNIA"), "CA"), "a full state name translates to its code")
chk(identical(clean_state("california"), "CA"), "a lower-case full name translates")
chk(identical(clean_state("New York"), "NY"), "a two-word full name translates")
chk(identical(clean_state("District of Columbia"), "DC"), "a full territory name translates")
chk(identical(clean_state("Puerto Rico"), "PR"), "a full territory name translates (Puerto Rico)")

chk(identical(clean_state("TX - TEXAS"), "TX"), "a 'code - name' combined form translates when consistent")
chk(identical(clean_state("CA - CALIFORNIA"), "CA"), "a second 'code - name' combined form translates")

chk(is.na(clean_state("ON - ONTARIO")),
    "a 'code - name' form is rejected when the prefix isn't a valid US code")
chk(is.na(clean_state("TX - CALIFORNIA")),
    "a 'code - name' form is rejected when the two halves disagree")
chk(is.na(clean_state("US - OUTLYING")),
    "a 'code - name' form is rejected when the suffix isn't a known full name")

chk(is.na(clean_state("N.Y.")), "a punctuated abbreviation is not guessed")
chk(is.na(clean_state("SEOUL")), "a foreign city is not a state")
chk(is.na(clean_state("JAPAN")), "a foreign country is not a state")
chk(is.na(clean_state("AE")), "a military postal code is not a state")
chk(is.na(clean_state("AP")), "a military postal code is not a state")
chk(is.na(clean_state("")), "a blank value is NA")
chk(is.na(clean_state(NA_character_)), "NA input stays NA")

multi <- clean_state(c("CA", "california", "TX - TEXAS", "SEOUL", NA))
chk(identical(multi, c("CA", "CA", "TX", NA_character_, NA_character_)),
    "vectorized input resolves each element independently")

if (fails > 0L) {
  cat(sprintf("\n%d check(s) FAILED\n", fails))
  quit(status = 1L)
}
cat("\nAll checks passed.\n")
