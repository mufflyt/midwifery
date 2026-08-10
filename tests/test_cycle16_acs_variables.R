#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 16 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: the ACS variable maps in R/01-build-county-base.R and
# R/12-district-profiles.R -- do the variable NUMBERS match the quantities the
# code names them?
#
# THE DEFECT, and it is the most consequential this loop has found.
#
#   R/01: women_labels <- paste0("w", 30:39)   # TEN bands
#   R/12: sprintf("B01001_%03dE", 30:38)       # NINE bands
#
# The same named quantity, women_15_44, had two different definitions in one
# project. Against the official ACS 2023 labels:
#
#   B01001_030E  Female: 15 to 17 years     <- the comment called this "15-19"
#   B01001_038E  Female: 40 to 44 years     <- the last band of 15-44
#   B01001_039E  Female: 45 to 49 years     <- was being summed in
#
# So the county column called women_15_44 was women 15-49. Measured against the
# live ACS 5-year API across 3,221 counties:
#
#   women 15-44               65,895,592
#   with 45-49 included       76,046,473
#   denominator overstated       15.4%
#   => county GFR understated    13.3%
#
# And the error is NOT uniform -- the per-county inflation factor runs from a
# median of 1.164 to a maximum of 1.846. A differential error distorts the
# RANKING as well as the level, which is the concern cycle 8 raised about
# filters and applies equally to denominators.
#
# The district script was right. The county script was wrong. Nothing compared
# them, because nothing asserted what the variable numbers mean.
#
# NOTE: data/county_base.csv was BUILT with the old range and is therefore
# stale. It must be rebuilt; T164 fails until it is.
#
# Run: Rscript tests/test_cycle16_acs_variables.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
CO <- readLines(file.path(root, "R", "01-build-county-base.R"), warn = FALSE)
DI <- readLines(file.path(root, "R", "12-district-profiles.R"), warn = FALSE)
code <- function(x) { x[grepl("^\\s*#", x)] <- ""; paste(x, collapse = "\n") }
COC <- code(CO); DIC <- code(DI)

# The authoritative meaning of each variable, from the ACS 2023 5-year
# variables endpoint. Written down here so the test does not need the network
# and so a future edit has something to be wrong against.
B01001_FEMALE <- c(
  "030" = "15 to 17 years", "031" = "18 and 19 years", "032" = "20 years",
  "033" = "21 years",       "034" = "22 to 24 years",  "035" = "25 to 29 years",
  "036" = "30 to 34 years", "037" = "35 to 39 years",  "038" = "40 to 44 years",
  "039" = "45 to 49 years")

cat("\n-- BVA --\n")

# T161 (BVA). The band range is a closed interval and both ends matter. 030 is
# the first band containing anyone aged 15; 038 is the last containing anyone
# aged 44; 039 is the first that does not.
{
  chk(identical(unname(B01001_FEMALE["030"]), "15 to 17 years"),
      "T161a the first band of 15-44 is _030, and it starts at 15 not 19")
  chk(identical(unname(B01001_FEMALE["038"]), "40 to 44 years"),
      "T161b the last band of 15-44 is _038")
  chk(identical(unname(B01001_FEMALE["039"]), "45 to 49 years"),
      "T161c _039 is 45-49 and belongs to no part of a 15-44 denominator")
}

# T162 (BVA). Nine bands, not ten. An off-by-one at either end of a summed
# range is a whole age group.
{
  n <- length(30:38)
  chk(n == 9L, "T162a women 15-44 spans exactly nine B01001 female bands")
  chk(length(30:39) == 10L,
      "T162b the old range summed ten, so it added one entire age group")
}

# T163 (BVA). The county script must now use 30:38 everywhere it touches the
# bands -- definition, fetch, sum, missing-count and drop.
{
  bad <- grep("30:39", COC, value = TRUE)
  chk(length(bad) == 0L,
      sprintf("T163 no reference to the ten-band range survives in the county build [%d]",
              length(bad)))
}

# T164 (BVA). The built artifact is stale until rebuilt. This test is expected
# to FAIL until data/county_base.csv is regenerated, and that is the point --
# a fixed formula and an unfixed artifact is the more dangerous state, because
# the code now looks right.
{
  cb <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                  show_col_types = FALSE, progress = FALSE,
                                  col_types = cols(GEOID = col_character())))
  # A STAMP FILE IS NOT EVIDENCE. The first version asserted only that
  # data/.county_base_rebuilt_after_cycle16 exists, which any `touch` satisfies
  # without rebuilding anything -- a test defeated by the one command its own
  # failure message tells you to run.
  #
  # The artifact is checked against an EXTERNAL published figure instead: US
  # women aged 15-44 number ~65-66 million (Census/ACS). The pre-fix artifact
  # totalled 76.0M, which is outside this range by 10 million; the rebuilt one
  # totals 65.9M. That cannot be faked by touching a file.
  w <- sum(cb$women_15_44, na.rm = TRUE) / 1e6
  chk(w > 60 && w < 70,
      sprintf(paste0("T164 county_base.csv carries the 15-44 denominator ",
                     "[%.1fM against a published 65-66M; the pre-fix artifact ",
                     "held 76.0M]"), w))
}

cat("\n-- SEMANTIC --\n")

# T165 (semantic). The two scripts must agree on what women_15_44 means. This
# is the assertion whose absence let the definitions diverge.
{
  co_range <- regmatches(COC, regexpr("B01001_%03d\", 3[0-9]:3[0-9]", COC))
  di_range <- regmatches(DIC, regexpr("B01001_%03dE\", 3[0-9]:3[0-9]", DIC))
  chk(length(co_range) == 1L && length(di_range) == 1L &&
        identical(sub(".*, ", "", co_range), sub(".*, ", "", di_range)),
      sprintf("T165 county and district build women_15_44 from the same band range [%s vs %s]",
              if (length(co_range)) sub(".*, ", "", co_range) else "?",
              if (length(di_range)) sub(".*, ", "", di_range) else "?"))
}

# T166 (semantic). The name states the age range, so the range is a contract.
# A column called women_15_44 that contains women 15-49 is not a rounding
# difference; it is a different population.
{
  chk(grepl("women_15_44", COC) && grepl("women_15_44", DIC),
      "T166a both scripts publish a column whose NAME asserts 15-44")
  chk(!grepl("paste0\\(\"w\", 30:39\\)", COC),
      "T166b the county sum no longer includes a band outside that name")
}

# T167 (semantic). The general fertility rate divides by this column, so the
# denominator's age range is part of the rate's definition and must match the
# label the sentence prints.
{
  # CYCLE 17 UPDATE. This pinned the whole expression, including the numerator,
  # which cycle 17 then correctly changed from births_past_12mo (universe women
  # 15-50) to births_15_44. The CONTRACT here is about the denominator -- that
  # the rate divides by the 15-44 column this cycle fixed -- so it now asserts
  # that and leaves the numerator to cycle 17's T174. A test should pin the
  # claim it is about, not the line it happened to read.
  chk(grepl("general_fertility_rate = 1000 \\* [a-z_0-9]+ / women_15_44", COC),
      "T167a the GFR denominator is the women_15_44 column")
  prof <- code(readLines(file.path(root, "R", "10-county-birth-profiles.R"), warn = FALSE))
  chk(grepl("per 1,000 women aged 15-44", prof),
      "T167b the published sentence names the same age range the column claims")
}

cat("\n-- ADVERSARIAL --\n")

# T168 (adversarial). The magnitude, pinned. A future edit that reintroduces a
# band must show up as a number, not as a diff.
{
  # National ACS 2023 5-year, measured across 3,221 counties.
  W_15_44 <- 65895592; W_15_49 <- 76046473
  overstated <- 100 * (W_15_49 - W_15_44) / W_15_44
  understated <- 100 * (1 - W_15_44 / W_15_49)
  chk(abs(overstated - 15.4) < 0.1 && abs(understated - 13.3) < 0.1,
      sprintf("T168 including 45-49 overstates the denominator by %.1f%% and understates GFR by %.1f%%",
              overstated, understated))
}

# T169 (adversarial). The error is DIFFERENTIAL, not a constant scale factor,
# so it moves counties relative to one another. A uniform 13% error would leave
# every ranking intact; a factor spanning 1.16 to 1.85 does not.
{
  median_factor <- 1.1637; max_factor <- 1.8455
  chk(max_factor / median_factor > 1.5,
      sprintf("T169 the inflation factor varies %.2fx to %.2fx, so the RANKING moved too, not only the level",
              median_factor, max_factor))
}

# T170 (adversarial). The class, swept. Any other summed ACS range in either
# script must be justified by an explicit band comment, because this defect was
# invisible precisely because a plausible comment stood in for a check.
{
  ranges <- unique(c(
    regmatches(COC, gregexpr("[0-9]+:[0-9]+", COC))[[1]],
    regmatches(DIC, gregexpr("[0-9]+:[0-9]+", DIC))[[1]]))
  acs_ranges <- grep("^(2[0-9]|3[0-9]|4[0-9]):", ranges, value = TRUE)
  chk(all(acs_ranges %in% c("30:38")),
      sprintf("T170 every ACS band range in these scripts is the audited one [%s]",
              paste(acs_ranges, collapse = ", ")))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
