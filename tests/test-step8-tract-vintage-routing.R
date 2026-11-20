# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-step8-tract-vintage-routing.R
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
# TEST: Step 8/9 tract boundary vintage routing (Defect #1 follow-on)
# =============================================================================
# Verifies that the shared resolve_tract_vintage() resolver correctly maps
# CENSUS_VINTAGE → tract boundary vintage string, and that Step 8 and Step 9
# use the same vintage-tagged subdirectory so batch files are never mixed
# across tract boundary vintages.
#
# Root cause context: Step 8 already calls get_acs(year = CENSUS_VINTAGE),
# so it fetches the correct boundary vintage.  The mismatch was a stale-batch
# problem: batch filenames (batch_t060_1.rds) carried no vintage tag, so
# Step 9 would read whatever existed on disk regardless of its GEOID vintage.
# =============================================================================

library(testthat)
library(here)

source(here("R", "utils", "resolve_tract_vintage.R"))

BASE_DIR <- "data/08-block-group-overlap/output"

# ---------------------------------------------------------------------------
# Test 1: resolver maps CENSUS_VINTAGE 2019 → "2010"
# ---------------------------------------------------------------------------
test_that("resolve_tract_vintage returns '2010' for CENSUS_VINTAGE <= 2019", {
  expect_equal(resolve_tract_vintage(2019), "2010")
  expect_equal(resolve_tract_vintage(2015), "2010")
  expect_equal(resolve_tract_vintage("2019"), "2010")
})

# ---------------------------------------------------------------------------
# Test 2: resolver maps CENSUS_VINTAGE 2020 → "2020" (cutoff year)
# ---------------------------------------------------------------------------
test_that("resolve_tract_vintage returns '2020' for CENSUS_VINTAGE 2020", {
  expect_equal(resolve_tract_vintage(2020), "2020",
               label = "2020 is the first year with 2020-boundary ACS tracts")
})

# ---------------------------------------------------------------------------
# Test 3: resolver maps CENSUS_VINTAGE 2022 → "2020"
# ---------------------------------------------------------------------------
test_that("resolve_tract_vintage returns '2020' for CENSUS_VINTAGE 2022", {
  expect_equal(resolve_tract_vintage(2022), "2020")
  expect_equal(resolve_tract_vintage(2023), "2020")
  expect_equal(resolve_tract_vintage("2022"), "2020")
})

# ---------------------------------------------------------------------------
# Test 4: step8_batch_dir produces paths that differ between 2010 and 2020
# ---------------------------------------------------------------------------
test_that("step8_batch_dir paths differ between tract vintages", {
  path_2010 <- step8_batch_dir(BASE_DIR, 2019)
  path_2020 <- step8_batch_dir(BASE_DIR, 2022)

  expect_false(
    identical(path_2010, path_2020),
    label = "2010-vintage and 2020-vintage batch directories must be distinct"
  )
  expect_match(path_2010, "tract_vintage_2010",
               label = "2010-vintage path contains 'tract_vintage_2010'")
  expect_match(path_2020, "tract_vintage_2020",
               label = "2020-vintage path contains 'tract_vintage_2020'")
})

# ---------------------------------------------------------------------------
# Test 5: Step 9 BATCH_INPUT_DIR matches Step 8 OUTPUT_DIR for same vintage
#   Verifies the shared resolver produces identical paths in both scripts.
# ---------------------------------------------------------------------------
test_that("Step 8 OUTPUT_DIR and Step 9 BATCH_INPUT_DIR are identical for same CENSUS_VINTAGE", {
  # Simulate what each script does independently with the same census_vintage
  simulate_step8_output_dir <- function(census_vintage) {
    step8_batch_dir(BASE_DIR, census_vintage)
  }
  simulate_step9_batch_input_dir <- function(census_vintage) {
    step8_batch_dir(BASE_DIR, census_vintage)  # same call — shared resolver
  }

  for (vintage in c(2019, 2020, 2021, 2022, 2023)) {
    out8 <- simulate_step8_output_dir(vintage)
    in9  <- simulate_step9_batch_input_dir(vintage)
    expect_identical(out8, in9,
                     label = sprintf("Paths match for CENSUS_VINTAGE=%d", vintage))
  }
})

# ---------------------------------------------------------------------------
# Test 6: Step 9 does NOT silently select 2010 batch dir when CENSUS_VINTAGE >= 2020
#   This is the concrete form of the original Defect #1 failure mode.
# ---------------------------------------------------------------------------
test_that("CENSUS_VINTAGE 2022 routes to tract_vintage_2020, not tract_vintage_2010", {
  dir_2022 <- step8_batch_dir(BASE_DIR, 2022)
  expect_match(dir_2022, "tract_vintage_2020",
               label = "CENSUS_VINTAGE=2022 must not resolve to tract_vintage_2010")
  expect_false(grepl("tract_vintage_2010", dir_2022),
               label = "CENSUS_VINTAGE=2022 path must not contain 'tract_vintage_2010'")
})
