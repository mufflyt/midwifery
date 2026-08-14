# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-safe-divide-zero-threshold-bva.R
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
# BVA / off-by-one for the canonical division guard safe_divide() (R/safe_divide.R,
# the pipeline SSOT for zero-denominator handling). A denominator is treated as
# "effectively zero" when
#     is.na(denominator) | abs(denominator) < zero_threshold   (default 1e-10)
# and those elements return `default` (NA_real_) instead of Inf/NaN. The strict
# `<` boundary is the edge: a denominator of EXACTLY zero_threshold is NOT zero
# (the quotient is computed), one epsilon below IS zero. A `<` -> `<=` slip would
# treat a legitimate tiny denominator as zero (dropping a real quotient); the
# opposite would let a near-zero denominator through and produce a huge/unstable
# quotient. safe_divide feeds population-weighted access rates and inline
# manuscript statistics throughout, so the zero edge is manuscript-critical.
#
# "One below / at / one above": zero_threshold - eps / zero_threshold /
# zero_threshold + eps, and denom 0.
# =============================================================================

library(testthat)
library(here)

suppressWarnings(suppressMessages(source(here::here("R", "safe_divide.R"))))
ZT <- 1e-10   # default zero_threshold

# -----------------------------------------------------------------------------
# The singularity guard: zero / NA denominator -> default, never Inf/NaN.
# -----------------------------------------------------------------------------
test_that("BVA: zero denominator returns default (NA), never Inf or NaN", {
  r <- safe_divide(10, 0)
  expect_true(is.na(r))
  expect_false(is.infinite(r))
  expect_false(is.nan(r))
})

test_that("BVA: NA denominator returns default", {
  expect_true(is.na(safe_divide(10, NA_real_)))
})

test_that("BVA: 0/0 returns default (not NaN)", {
  expect_true(is.na(safe_divide(0, 0)))
})

# -----------------------------------------------------------------------------
# Normal division and sign handling (abs is only for the zero-check).
# -----------------------------------------------------------------------------
test_that("normal division computes the quotient with correct sign", {
  expect_identical(safe_divide(10, 2), 5)
  expect_identical(safe_divide(10, -2), -5)   # abs is only for the zero-test
  expect_identical(safe_divide(-10, -2), 5)
})

# -----------------------------------------------------------------------------
# The zero_threshold edge (strict <): exactly the threshold is NOT zero.
# -----------------------------------------------------------------------------
test_that("BVA: |denom| == zero_threshold computes; one epsilon below is zero", {
  expect_equal(safe_divide(1, ZT), 1 / ZT)          # exactly threshold -> computes (1e10)
  expect_true(is.na(safe_divide(1, ZT / 2)))         # below threshold -> zero -> NA
  expect_equal(safe_divide(1, ZT * 2), 1 / (ZT * 2)) # above threshold -> computes
  # sign-symmetric via abs()
  expect_true(is.na(safe_divide(1, -ZT / 2)))        # tiny negative -> zero
  expect_equal(safe_divide(1, -ZT), 1 / (-ZT))       # -threshold magnitude -> computes
})

test_that("BVA: a custom zero_threshold shifts the edge", {
  expect_true(is.na(safe_divide(1, 0.4, zero_threshold = 0.5)))  # 0.4 < 0.5 -> zero
  expect_equal(safe_divide(1, 0.5, zero_threshold = 0.5), 2)     # 0.5 not < 0.5 -> computes
  expect_equal(safe_divide(1, 0.6, zero_threshold = 0.5), 1/0.6) # 0.6 -> computes
})

# -----------------------------------------------------------------------------
# Vectorized: the zero guard is element-wise.
# -----------------------------------------------------------------------------
test_that("BVA: vectorized division guards each zero denominator independently", {
  out <- safe_divide(c(10, 20, 30, 40), c(2, 0, 5, NA))
  expect_equal(out[1], 5)
  expect_true(is.na(out[2]))   # zero denom
  expect_equal(out[3], 6)
  expect_true(is.na(out[4]))   # NA denom
})

# -----------------------------------------------------------------------------
# default / on_zero behavior.
# -----------------------------------------------------------------------------
test_that("a custom default is returned on a zero denominator", {
  expect_identical(safe_divide(10, 0, default = -99), -99)
})

test_that("on_zero = 'error' stops on a zero denominator; 'silent' does not", {
  expect_error(safe_divide(10, 0, on_zero = "error"))
  expect_true(is.na(safe_divide(10, 0, on_zero = "silent")))
})

# -----------------------------------------------------------------------------
# Source contract: the zero-detection rule and default threshold unchanged.
# -----------------------------------------------------------------------------
test_that("regression: safe_divide zero rule is is.na | abs(denom) < zero_threshold (1e-10)", {
  src <- paste(readLines(here::here("R", "safe_divide.R"), warn = FALSE), collapse = "\n")
  expect_true(grepl("zero_threshold\\s*=\\s*1e-10", src),
              info = "default zero tolerance must be 1e-10")
  expect_true(grepl("is\\.na\\(denominator\\)\\s*\\|\\s*abs\\(denominator\\)\\s*<\\s*zero_threshold", src),
              info = "zero rule must be NA OR |denom| strictly < threshold")
  # must NOT relax to <= (would treat exactly-threshold denominators as zero)
  expect_false(grepl("abs\\(denominator\\)\\s*<=\\s*zero_threshold", src),
               info = "a <= would drop legitimate exactly-threshold denominators")
})
