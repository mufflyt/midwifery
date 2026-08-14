# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-den-032-safe-pct-manu-na-semantics.R
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
RENV_LIB <- file.path(here::here("renv", "library"), sprintf("R-%s", getRversion()[,1:2]), R.version$arch)
if (dir.exists(RENV_LIB)) .libPaths(c(RENV_LIB, .libPaths()))

source(here::here("R", "safe_divide.R"))

# DEN-032: safe_pct_manu in R/safe_divide.R must return NA_real_ (not 0)
# when the denominator is 0 or NA. The manuscript path
# (manuscript/R/00_manuscript_utils.R) already returns NA_real_. Having two
# definitions with opposite NA semantics means the Step 4/11 pipeline path can
# silently report 0% access as a "care desert" artifact when the denominator
# is legitimately missing.

test_that("DEN-032: safe_pct_manu returns NA_real_ when denominator is 0", {
  result <- safe_pct_manu(5, 0)
  expect_true(is.na(result),
    info = "safe_pct_manu(5, 0) must return NA_real_, not 0")
})

test_that("DEN-032: safe_pct_manu returns NA_real_ when denominator is NA", {
  result <- safe_pct_manu(5, NA_real_)
  expect_true(is.na(result),
    info = "safe_pct_manu(5, NA) must return NA_real_, not 0")
})

test_that("DEN-032: safe_pct_manu still computes correctly for valid inputs", {
  expect_equal(safe_pct_manu(1, 4), 25.0)
  expect_equal(safe_pct_manu(0, 100), 0.0)
  expect_equal(safe_pct_manu(100, 100), 100.0)
})

test_that("DEN-032: safe_pct_manu handles NULL numerator as NA", {
  result <- safe_pct_manu(NULL, 10)
  expect_true(is.na(result) || identical(result, NA_real_),
    info = "NULL numerator must not crash — return NA_real_")
})
