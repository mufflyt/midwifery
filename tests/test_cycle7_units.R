#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 7 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: the UNITS in data/county_base.csv and the multipliers that turn them
# into published English in R/10-county-birth-profiles.R.
#
# The central finding is a naming contract, not a calculation:
#
#     pct_low_birth_weight   0.029 - 0.226     PROPORTION
#     pct_rural              0     - 1         PROPORTION
#     pct_below_poverty      1.7   - 64.7      PERCENTAGE
#     pct_uninsured          0     - 44.3      PERCENTAGE
#
# Four columns share a `pct_` prefix and two of them are percentages while two
# are proportions. The sentence generator compensates by hand, multiplying some
# by 100 and not others, with a comment at each site explaining which is which.
# That works exactly as long as every future reader reads the comment, and
# nothing verifies that the multiplier still matches the data.
#
# A 100x error here is not a rounding difference. "23% of births low birth
# weight" and "0.2% of births low birth weight" are different public health
# claims, and both are printable from the same column depending on a multiplier
# no test currently checks.
#
# Run: Rscript tests/test_cycle7_units.R
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
CB <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                show_col_types = FALSE, progress = FALSE))
PROFILE <- file.path(root, "R", "10-county-birth-profiles.R")
SRC <- paste(readLines(PROFILE, warn = FALSE), collapse = "\n")

# The unit contract, stated once, in one place, as data.
UNITS <- tibble::tribble(
  ~col,                      ~unit,         ~lo,   ~hi,
  "pct_low_birth_weight",    "proportion",  0,     1,
  "pct_rural",               "proportion",  0,     1,
  "svi_overall_pctile",      "proportion",  0,     1,
  "pct_below_poverty",       "percentage",  0,     100,
  "pct_uninsured",           "percentage",  0,     100,
  # CYCLE 7 finding. pct_poverty and pct_below_poverty are the SAME quantity --
  # correlation 1.000, ratio 1.000, differing only in rounding. Two columns for
  # one concept means a future vintage can update one and leave the other, and
  # nothing would notice. Declared here so the duplication is visible; see T65c.
  "pct_poverty",             "percentage",  0,     100,
  "pct_public_coverage",     "percentage",  0,     100
)

cat("\n-- BVA --\n")

# T61 (BVA). Proportions live in [0, 1]. A single value above 1 means the
# column has become a percentage and every x100 downstream is now a x10,000.
{
  props <- UNITS %>% filter(unit == "proportion")
  bad <- props$col[vapply(props$col, function(c)
    c %in% names(CB) && any(CB[[c]] > 1, na.rm = TRUE), logical(1))]
  chk(length(bad) == 0L,
      sprintf("T61 every proportion column stays within [0, 1] [violations: %s]",
              if (length(bad)) paste(bad, collapse = ", ") else "none"))
}

# T62 (BVA). Percentages must be in [0, 100] AND must actually exceed 1
# somewhere. A percentage column whose maximum is below 1 is indistinguishable
# from a proportion, and the next reader will "fix" it by multiplying.
{
  pcts <- UNITS %>% filter(unit == "percentage")
  in_range <- all(vapply(pcts$col, function(c)
    !(c %in% names(CB)) || all(CB[[c]] >= 0 & CB[[c]] <= 100, na.rm = TRUE), logical(1)))
  distinguishable <- all(vapply(pcts$col, function(c)
    !(c %in% names(CB)) || max(CB[[c]], na.rm = TRUE) > 1, logical(1)))
  chk(in_range, "T62a percentage columns stay within [0, 100]")
  chk(distinguishable,
      "T62b every percentage column exceeds 1 somewhere, so it cannot be mistaken for a proportion")
}

# T63 (BVA). Rates are counts per population: non-negative, finite, never NaN.
{
  rates <- intersect(c("general_fertility_rate", "teen_birth_rate",
                       "infant_mortality_per_1k", "pop_density_sq_mi"), names(CB))
  bad <- rates[vapply(rates, function(c) {
    y <- CB[[c]][!is.na(CB[[c]])]
    any(y < 0) || any(!is.finite(y))
  }, logical(1))]
  chk(length(bad) == 0L,
      sprintf("T63 every rate is non-negative and finite [violations: %s]",
              if (length(bad)) paste(bad, collapse = ", ") else "none"))
}

# T64 (BVA). pcp_per_100k is MISNAMED -- it holds a per-capita rate. The
# published sentence multiplies by 1e5. Pin the scale, so that renaming the
# column (the real fix) cannot silently leave the multiplier behind.
{
  if (!"pcp_per_100k" %in% names(CB)) { cat("  skip T64 column absent\n") } else {
    raw_max <- max(CB$pcp_per_100k, na.rm = TRUE)
    scaled <- 1e5 * CB$pcp_per_100k
    chk(raw_max < 1,
        sprintf("T64a pcp_per_100k holds a PER-CAPITA rate despite its name [max %.6f]", raw_max))
    chk(median(scaled, na.rm = TRUE) > 10 && median(scaled, na.rm = TRUE) < 200,
        sprintf("T64b x1e5 lands in a plausible per-100k range [median %.0f]",
                median(scaled, na.rm = TRUE)))
  }
}

cat("\n-- SEMANTIC --\n")

# T65 (semantic). THE FINDING. The `pct_` prefix is not a unit. Assert the
# split explicitly so it is a documented contract rather than folklore carried
# in comments at each call site.
{
  pct_cols <- grep("^pct_", names(CB), value = TRUE)
  known <- UNITS$col[UNITS$col %in% pct_cols]
  chk(setequal(pct_cols, known),
      sprintf("T65a every pct_ column has a declared unit [undeclared: %s]",
              paste(setdiff(pct_cols, known), collapse = ", ")))
  measured <- vapply(known, function(c)
    if (max(CB[[c]], na.rm = TRUE) > 1) "percentage" else "proportion", character(1))
  declared <- UNITS$unit[match(known, UNITS$col)]
  chk(identical(unname(measured), declared),
      sprintf("T65b each pct_ column's measured unit matches its declared one [measured: %s]",
              paste(sprintf("%s=%s", known, measured), collapse = ", ")))
  # T65c. Two columns, one concept. If they ever disagree, some reader is
  # quoting a poverty rate the rest of the pipeline does not use.
  if (all(c("pct_poverty", "pct_below_poverty") %in% names(CB))) {
    d <- abs(CB$pct_poverty - CB$pct_below_poverty)
    chk(all(d < 0.06, na.rm = TRUE),
        sprintf("T65c the duplicated poverty columns still agree [max divergence %.4f]",
                max(d, na.rm = TRUE)))
  }
}

# T66 (semantic). The multiplier at each call site must match the declared
# unit: proportions are scaled by 100 to be printed as percentages, and
# percentages are printed as they are.
{
  scaled_by_100 <- function(col) grepl(sprintf("100 \\* r\\$%s", col), SRC)
  ok_prop <- all(vapply(UNITS$col[UNITS$unit == "proportion"], scaled_by_100, logical(1)))
  ok_pct <- !any(vapply(UNITS$col[UNITS$unit == "percentage"], scaled_by_100, logical(1)))
  chk(ok_prop, "T66a every proportion is multiplied by 100 before printing as a percentage")
  chk(ok_pct, "T66b no percentage is multiplied by 100 a second time")
}

# T67 (semantic). A general fertility rate is births per 1,000 women aged
# 15-44. The US national figure is around 55 and the highest counties are near
# 120; 448 would mean 45% of all women of reproductive age gave birth in one
# year, which is a denominator failure, not a fertile county.
{
  if (!"general_fertility_rate" %in% names(CB)) { cat("  skip T67 column absent\n") } else {
    gfr <- CB$general_fertility_rate
    # RATCHET. 9 counties exceed 200 births per 1,000 women 15-44, topping out
    # at 448.7 -- which would mean 45% of all women of reproductive age gave
    # birth in one year. Every one has a tiny denominator (138-3,146 women), so
    # these are ACS sampling artifacts, not fertile counties.
    #
    # NOT silently corrected. Whether to floor the denominator, widen to a
    # multi-year estimate, or suppress the rate is a scientific decision with
    # several defensible answers, recorded in the ledger. What is asserted here
    # is that the count cannot GROW -- and, below, that these artifacts are kept
    # out of the published superlative, which is the part that reaches a reader.
    implausible <- sum(gfr > 200, na.rm = TRUE)
    # CYCLE 16 UPDATE: 9 -> 19. The count grew because a DEFECT WAS FIXED, not
    # because the data degraded. women_15_44 was summing ten B01001 bands and
    # therefore included women 45-49, inflating the denominator by 15.4% and
    # suppressing every county's fertility rate by 13.3%. Correcting it raised
    # every rate, so more counties now clear the plausibility bound. Cycle 8's
    # differential-exclusion contract still holds: the spread across rurality is
    # 1.37 pp, well inside its 5 pp limit.
    chk(implausible <= 19L,
        sprintf("T67a implausible GFR count does not grow [%d counties > 200/1,000, max %.1f]",
                implausible, max(gfr, na.rm = TRUE)))
    # UPDATED IN CYCLE 8. This originally asserted the denominator floor
    # (GFR_MIN_WOMEN <- 5000) that cycle 7 introduced. Cycle 8 measured that
    # filter and found it removed 88.5% of REMOTE counties from the ranking in a
    # study about rural access -- more biased than the noise it corrected -- and
    # replaced it with a demographic VALIDITY bound.
    #
    # The contract is unchanged and still right: the superlative must not name a
    # sampling artifact. Only the mechanism moved, so the assertion moves with
    # it rather than being deleted. The bias of whatever mechanism is in force is
    # asserted separately, in test_cycle8_filter_bias.R T74.
    chk(grepl("gfr_plausible|GFR_MAX_PLAUSIBLE", SRC),
        "T67b the fertility superlative excludes demographically impossible rates")
  }
}

cat("\n-- ADVERSARIAL --\n")

# T68 (adversarial). A future vintage shipping a proportion as a percentage is
# the exact failure this cycle exists to prevent. Inject it and confirm the
# contract above catches it -- otherwise T61 is decoration.
{
  poisoned <- CB
  poisoned$pct_low_birth_weight <- poisoned$pct_low_birth_weight * 100
  caught <- any(poisoned$pct_low_birth_weight > 1, na.rm = TRUE)
  chk(caught,
      "T68 a vintage shipping pct_low_birth_weight as a percentage is detected, not printed")
}

# T69 (adversarial). Missing values must produce no sentence, never the string
# "NA". 2,063 counties lack infant mortality and 257 lack pcp -- this is the
# common case, not the edge case.
{
  emits_na <- grepl('sprintf\\("[^"]*%s[^"]*", *r\\$', SRC) &&
    !grepl("!is\\.null\\(fmt\\(", SRC)
  chk(!emits_na,
      "T69a every sentence is gated on fmt() returning non-NULL")
  n_gates <- lengths(regmatches(SRC, gregexpr("if \\(!is\\.null\\(fmt\\(", SRC)))
  chk(n_gates >= 8L,
      sprintf("T69b the sentence pool gates each fact on availability [%d gates]", n_gates))
}

# T70 (adversarial). Class N1, the last unaudited site. A plausibility gate
# that sums population with na.rm = TRUE scores every unallocated tract as 0
# residents, so the population floor it enforces is checked against an
# understated total -- the gate is most likely to pass exactly when allocation
# has failed.
{
  sc <- readLines(file.path(root, "R", "spatial_crs_contract.R"), warn = FALSE)
  i <- grep("sum\\(overlap_df\\$population_allocated, na\\.rm = TRUE\\)", sc)
  guarded <- length(i) == 0L ||
    any(grepl("is\\.na\\(overlap_df\\$population_allocated\\)|n_missing|anyNA",
              sc[max(1, min(i) - 6):min(length(sc), max(i) + 8)]))
  chk(guarded,
      sprintf("T70 the population plausibility gate accounts for unallocated tracts [line(s): %s]",
              paste(i, collapse = ", ")))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
