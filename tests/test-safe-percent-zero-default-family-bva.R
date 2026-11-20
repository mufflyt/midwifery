# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-safe-percent-zero-default-family-bva.R
#
# Not one assertion is changed. This file tests a helper that exists in
# BOTH repositories, so the upstream contract applies here unaltered; the
# only edit is this header. If it starts failing, the local helper has
# diverged from the upstream contract -- decide which is right rather
# than editing the assertion to match the code.
#
# Verified before landing: passes 100% against this repo's helper, needs
# no artifact, no network, no ~/isochrones, and no file outside the repo.
# ============================================================================
#!/usr/bin/env Rscript
# =============================================================================
# BVA for the zero-denominator DEFAULT across the safe_divide() family
# (R/safe_divide.R). All four build on safe_divide's zero rule (|denom| < 1e-10
# -> zero), but they DIFFER intentionally in what a zero denominator returns:
#   safe_percent(part, total, default = 0)        -> 0    (empty tract = 0% access)
#   safe_rate(events, exposure, default = NA)     -> NA   (undefined rate)
#   safe_ratio(numerator, denom, default = NA)    -> NA   (undefined ratio)
#   safe_divide(num, den, default = NA)           -> NA   (undefined quotient)
#
# This 0-vs-NA split is a SEMANTIC boundary, not a bug: population-weighted access
# treats a zero-population tract as 0% (so it still contributes to the weighted
# mean as an underserved area), whereas a rate/ratio with no denominator is
# genuinely undefined. A refactor that made safe_percent return NA would silently
# DROP empty tracts from the denominator and inflate the reported access rate.
# The BVA pins the exact zero-input divergence and the overridable default.
# =============================================================================

library(testthat)
library(here)

suppressWarnings(suppressMessages(source(here::here("R", "safe_divide.R"))))
ZT <- 1e-10

# -----------------------------------------------------------------------------
# The zero-denominator DIVERGENCE: same input, percent->0, others->NA.
# -----------------------------------------------------------------------------
test_that("BVA: a zero denominator gives 0 for safe_percent but NA for the rest", {
  expect_identical(safe_percent(5, 0), 0)     # empty -> 0% (contributes to weighted mean)
  expect_true(is.na(safe_rate(5, 0)))          # undefined rate
  expect_true(is.na(safe_ratio(5, 0)))         # undefined ratio
  expect_true(is.na(safe_divide(5, 0)))        # undefined quotient
})

test_that("BVA: NA total behaves like zero total for each function's default", {
  expect_identical(safe_percent(5, NA_real_), 0)
  expect_true(is.na(safe_rate(5, NA_real_)))
  expect_true(is.na(safe_ratio(5, NA_real_)))
})

# -----------------------------------------------------------------------------
# The zero rule is inherited from safe_divide: |total| < 1e-10 -> default.
# -----------------------------------------------------------------------------
test_that("BVA: safe_percent treats a sub-threshold total as zero (-> 0)", {
  expect_identical(safe_percent(5, ZT / 2), 0)             # below threshold -> 0
  expect_equal(safe_percent(1, ZT), round(100 / ZT, 1))    # exactly threshold -> computes
})

# -----------------------------------------------------------------------------
# The default is overridable (so a caller CAN make an empty tract NA).
# -----------------------------------------------------------------------------
test_that("safe_percent default 0 is overridable to NA", {
  expect_identical(safe_percent(5, 0), 0)
  expect_true(is.na(safe_percent(5, 0, default = NA_real_)))
})

# -----------------------------------------------------------------------------
# Normal computation + rounding to `digits`.
# -----------------------------------------------------------------------------
test_that("safe_percent computes and rounds to digits", {
  expect_identical(safe_percent(3, 4), 75)          # 75.0
  expect_identical(safe_percent(1, 3), 33.3)        # rounded to 1 dp
  expect_identical(safe_percent(1, 3, digits = 3), 33.333)
  expect_identical(safe_percent(0, 5), 0)           # 0/5 = 0% (a REAL zero, not a guard)
})

test_that("safe_percent(0, 5) [real zero part] and safe_percent(5, 0) [zero total] both give 0 but for different reasons", {
  # 0/5 -> genuinely 0% ; 5/0 -> guard default 0. Same value, distinct paths.
  expect_identical(safe_percent(0, 5), safe_percent(5, 0))
  expect_true(is.na(safe_divide(0, 5)) == FALSE)   # 0/5 computes (0), not a guard hit
})

# -----------------------------------------------------------------------------
# Source contracts: the intentional default split must not be flattened.
# -----------------------------------------------------------------------------
test_that("regression: safe_percent defaults to 0; safe_rate/ratio default to NA", {
  src <- paste(readLines(here::here("R", "safe_divide.R"), warn = FALSE), collapse = "\n")
  expect_true(grepl("safe_percent\\s*<-\\s*function\\([^)]*default\\s*=\\s*0", src, perl = TRUE),
              info = "safe_percent must default to 0 (empty tract = 0% access)")
  expect_true(grepl("safe_rate\\s*<-\\s*function\\([^)]*default\\s*=\\s*NA_real_", src, perl = TRUE),
              info = "safe_rate must default to NA (undefined rate)")
  expect_true(grepl("safe_ratio\\s*<-\\s*function\\([^)]*default\\s*=\\s*NA_real_", src, perl = TRUE),
              info = "safe_ratio must default to NA (undefined ratio)")
})
