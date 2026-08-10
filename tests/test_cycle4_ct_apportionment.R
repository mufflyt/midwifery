#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 4 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: R/lib/ct_county_crosswalk.R, the Connecticut apportionment, plus the
# class it belongs to.
#
# Cycle 3 found rowSums(na.rm = TRUE) scoring a suppressed ACS component as 0.
# The sweep this cycle found the same construction in 17 places, and split it
# into two subclasses:
#
#   N1  na.rm = TRUE in an AGGREGATION that builds a count or denominator.
#       A suppressed input contributes 0, so "we cannot say" is published as
#       "none". Three sites are in the CT crosswalk alone.
#
#   N2  na.rm = TRUE inside a VALIDATION GUARD. This is worse. The guard exists
#       to catch impossible data, and na.rm = TRUE makes it drop exactly the
#       rows it cannot evaluate -- so a guard reading
#           stopifnot(sum(a > b, na.rm = TRUE) == 0)
#       passes when a or b is missing. A guard that cannot fail on bad input is
#       not a guard.
#
# CT matters more than most: WONDER reports natality by LEGACY county and every
# other source uses 2022 planning regions, so every Connecticut birth count in
# this project passes through this function.
#
# Run: Rscript tests/test_cycle4_ct_apportionment.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "ct_county_crosswalk.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
W <- build_ct_legacy_to_region_weights()

cat("\n-- BVA --\n")

# T31 (BVA). Weights are a partition: each legacy county's shares sum to
# exactly 1. Anything less silently deletes births; anything more invents them.
{
  s <- W %>% group_by(county_fips_2020) %>% summarise(t = sum(weight), .groups = "drop")
  chk(nrow(s) == 8L && all(abs(s$t - 1) < 1e-9),
      sprintf("T31a all 8 legacy counties' weights sum to 1 [range %.12f-%.12f]",
              min(s$t), max(s$t)))
  chk(n_distinct(W$ce_fips_2022) == 9L,
      "T31b all 9 planning regions are represented")
  chk(all(W$weight > 0) && all(W$weight <= 1),
      "T31c every weight is in (0, 1] -- no zero or negative shares")
}

# T32 (BVA). Zero is a real observed count, not missingness, and must survive
# apportionment as zero.
{
  o <- apportion_ct_legacy(data.frame(GEOID = "09001", births = 0), "GEOID", "births")
  chk(nrow(o) > 0L && all(o$births == 0) && !any(is.na(o$births)),
      "T32 an observed zero apportions to zeros, not to NA")
}

# T33 (BVA). Empty and all-non-CT input must return zero rows, not error.
{
  e <- apportion_ct_legacy(data.frame(GEOID = character(0), births = numeric(0)),
                           "GEOID", "births")
  chk(nrow(e) == 0L, "T33a empty input returns zero rows")
  n <- apportion_ct_legacy(data.frame(GEOID = c("08031", "36061"), births = c(5, 6)),
                           "GEOID", "births")
  chk(nrow(n) == 0L, "T33b input with no Connecticut rows returns zero rows")
}

# T34 (BVA). Middlesex (09007) is the only legacy county nested wholly in one
# planning region, so its apportionment must be exact, not approximate.
{
  mw <- W %>% filter(county_fips_2020 == "09007")
  o <- apportion_ct_legacy(data.frame(GEOID = "09007", births = 137), "GEOID", "births")
  chk(nrow(mw) == 1L && abs(mw$weight - 1) < 1e-12 &&
        nrow(o) == 1L && abs(o$births - 137) < 1e-9,
      sprintf("T34 the wholly-nested county transfers exactly [%d region(s), births %.6f]",
              nrow(mw), if (nrow(o)) o$births[1] else NA_real_))
}

cat("\n-- SEMANTIC --\n")

# T35 (semantic). THE DEFECT. WONDER suppresses any county below 10 births, so
# a suppressed Connecticut county arrives as NA. sum(.x, na.rm = TRUE) turns
# that into 0 for every planning region drawing from it -- and a region fed
# ONLY by the suppressed county is published as a hard 0. "We may not say" is
# not "none", and the difference is a county with no midwife-attended births.
{
  o <- apportion_ct_legacy(
    data.frame(GEOID = c("09001", "09003"), births = c(NA_real_, 100)),
    "GEOID", "births")
  fed_only_by_suppressed <- W %>%
    group_by(ce_fips_2022) %>%
    filter(all(county_fips_2020 == "09001")) %>%
    pull(ce_fips_2022) %>% unique()
  vals <- o$births[o$GEOID %in% fed_only_by_suppressed]
  chk(length(vals) == 0L || all(is.na(vals)),
      sprintf("T35 a region fed only by a suppressed county is NA, not 0 [got: %s]",
              paste(round(vals, 4), collapse = ", ")))
}

# T36 (semantic). The conservation guard must be ABLE to fail. It compares
# sum(before, na.rm = TRUE) with sum(after, na.rm = TRUE), so NA -> 0 leaves
# both sides at 0 and the invariant passes over precisely the corruption it
# exists to detect. Subclass N2.
{
  src <- paste(readLines(file.path(root, "R", "lib", "ct_county_crosswalk.R"),
                         warn = FALSE), collapse = "\n")
  guarded <- grepl("n_missing_before|is\\.na\\(legacy\\[\\[v\\]\\]\\)", src)
  chk(guarded,
      "T36 the conservation guard accounts for missing inputs, not only totals")
}

# T37 (semantic). An apportioned value is an estimate. Every row must say so,
# because a planning-region birth count that looks observed will be read as one.
{
  o <- apportion_ct_legacy(data.frame(GEOID = "09001", births = 50), "GEOID", "births")
  chk(all(o$ct_apportioned), "T37a every apportioned row is flagged as an estimate")
  chk(!any(abs(o$births - round(o$births)) < 1e-12 & o$births > 0) ||
        nrow(o) == 1L,
      "T37b apportioned counts are not silently rounded to look like observations")
}

cat("\n-- ADVERSARIAL --\n")

# T38 (adversarial). apportion_ct_legacy() returns ONLY the CT rows, so a
# caller that does not recombine loses every other county in the country. The
# contract is easy to misread as "returns d with CT fixed".
# My first version of this test asserted the recombination with a regex and
# FAILED -- wrongly. R/11-wonder-county-ingest.R does recombine, via
#   ident <- ident %>% filter(!GEOID %in% ct_legacy$GEOID)
#   ident <- bind_rows(ident, mutate(ct_app, suppressed = FALSE))
# The premise was right and the pattern was too narrow. Rewritten to test the
# behaviour, which also exposed the real defect on the next line: that
# `suppressed = FALSE` is hard-coded, so a row apportioned FROM a suppressed
# county is stamped as an observation.
{
  ingest <- file.path(root, "R", "11-wonder-county-ingest.R")
  src <- paste(readLines(ingest, warn = FALSE), collapse = "\n")
  chk(grepl("bind_rows\\(ident,", src) && grepl("!GEOID %in% ct_legacy\\$GEOID", src),
      "T38a the caller removes legacy CT rows and binds the apportioned ones back")
  chk(!grepl("mutate\\(ct_app, suppressed = FALSE\\)", src),
      "T38b apportioned rows do not hard-code suppressed = FALSE")
}

# T39 (adversarial). Subclass N2 across the repo. A guard of the form
# sum(a > b, na.rm = TRUE) == 0 cannot fail when a or b is NA.
{
  a <- c(5, NA_real_); b <- c(1, 1)
  blind <- sum(a > b, na.rm = TRUE)          # 1: catches the real violation
  a2 <- c(1, NA_real_); b2 <- c(5, 1)
  still_blind <- sum(a2 > b2, na.rm = TRUE)  # 0: NA row silently dropped
  chk(blind == 1L && still_blind == 0L,
      "T39a na.rm=TRUE guards drop unevaluable rows rather than failing on them")
  dp <- paste(readLines(file.path(root, "R", "12-district-profiles.R"), warn = FALSE),
              collapse = "\n")
  n_blind <- lengths(regmatches(dp, gregexpr("stopifnot\\(sum\\([^)]*na\\.rm = TRUE\\) == 0\\)", dp)))
  chk(n_blind == 0L,
      sprintf("T39b no district-profile guard is blinded by na.rm=TRUE [found %d]", n_blind))
}

# T40 (adversarial). R/string_normalization.R is a shim that sources the
# canonical implementation from ~/isochrones. If that repo is absent the shim
# must fail LOUDLY with instructions -- the standing rule for this project is
# no silent fallback to a local reimplementation.
{
  shim <- file.path(root, "R", "string_normalization.R")
  src <- paste(readLines(shim, warn = FALSE), collapse = "\n")
  informative <- grepl("stop\\(", src) &&
    grepl("ISOCHRONES_R", src) && grepl("file\\.exists", src)
  chk(informative,
      "T40 the isochrones shim checks for its target and fails with instructions")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
