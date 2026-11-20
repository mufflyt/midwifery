# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-tract-vintage-boundary-bva-2019-2020-2021.R
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
# TEST: ACS tract-boundary vintage cutoff — Boundary Value Analysis (BVA)
#       + off-by-one guard on the 2019 / 2020 / 2021 triplet
# =============================================================================
# WHY THIS FILE EXISTS
# --------------------
# The ACS 2010→2020 tract-boundary cutoff is keyed off CENSUS_VINTAGE (the
# get_acs(year=) value), and the rule is:
#
#     CENSUS_VINTAGE <= 2019  →  2010-boundary tracts  →  "2010"
#     CENSUS_VINTAGE >= 2020  →  2020-boundary tracts  →  "2020"   ← cutoff
#
# Authoritative source (CLAUDE.md, Walker "Analyzing US Census Data" ch.7):
# the 2016–2020 ACS is the FIRST ACS dataset to use 2020 Census boundaries.
# Data end-year 2020 is the boundary; 2022 is only the *release* date of that
# dataset. A prior bug conflated the two and wrote a wrong `>= 2022` edit.
#
# This is exactly the kind of cutoff where an off-by-one (`<` vs `<=`, `>` vs
# `>=`) silently produces a plausible-but-wrong tract universe — no crash, just
# 22,776 phantom-zeroed tracts (35.7% of GEOIDs) per the national probe.
#
# METHODOLOGY
# -----------
# Boundary Value Analysis: test at the exact boundary and one step on each
# side — 2019 (one below), 2020 (the boundary), 2021 (one above).
# Off-by-one: assert the specific mutants that a wrong comparison operator
# would produce are NOT what the function returns.
#
# Single source of truth: resolve_tract_vintage() is the ONLY place the cutoff
# lives. step8_batch_dir() delegates to it, and the R/09 DEFECT #1 guard
# mirrors its `>= 2020` predicate. So we anchor the BVA on this function and
# add a path-routing BVA on step8_batch_dir() to prove the flip propagates.
# =============================================================================

library(testthat)
library(here)

source(here("R", "utils", "resolve_tract_vintage.R"))

# The BVA triplet: one below the boundary, the boundary, one above.
YEAR_BELOW    <- 2019L  # last 2010-boundary vintage
YEAR_BOUNDARY <- 2020L  # FIRST 2020-boundary vintage (the cutoff)
YEAR_ABOVE    <- 2021L  # safely inside the 2020-boundary regime

# ---------------------------------------------------------------------------
# BVA point 1 — ONE BELOW the boundary (2019 → "2010")
# ---------------------------------------------------------------------------
test_that("BVA: CENSUS_VINTAGE 2019 (one below cutoff) resolves to '2010'", {
  expect_identical(resolve_tract_vintage(2019L), "2010")
  expect_identical(resolve_tract_vintage(2019),  "2010")   # numeric
  expect_identical(resolve_tract_vintage("2019"), "2010")  # character
})

# ---------------------------------------------------------------------------
# BVA point 2 — EXACTLY ON the boundary (2020 → "2020")
# This is the single most important assertion: 2020 is the FIRST 2020-boundary
# vintage. A `> 2020` off-by-one would wrongly send it to "2010".
# ---------------------------------------------------------------------------
test_that("BVA: CENSUS_VINTAGE 2020 (exactly on cutoff) resolves to '2020'", {
  expect_identical(resolve_tract_vintage(2020L), "2020")
  expect_identical(resolve_tract_vintage(2020),  "2020")
  expect_identical(resolve_tract_vintage("2020"), "2020")
})

# ---------------------------------------------------------------------------
# BVA point 3 — ONE ABOVE the boundary (2021 → "2020")
# ---------------------------------------------------------------------------
test_that("BVA: CENSUS_VINTAGE 2021 (one above cutoff) resolves to '2020'", {
  expect_identical(resolve_tract_vintage(2021L), "2020")
  expect_identical(resolve_tract_vintage(2021),  "2020")
  expect_identical(resolve_tract_vintage("2021"), "2020")
})

# ---------------------------------------------------------------------------
# OFF-BY-ONE MUTANT GUARDS
# Each block names the wrong operator a careless edit might introduce and
# asserts the output that mutant would produce is NOT what we get.
# ---------------------------------------------------------------------------
test_that("off-by-one: cutoff is `>= 2020`, NOT `>= 2019` (2019 must stay 2010-boundary)", {
  # Mutant `>= 2019` would push 2019 into the 2020 universe. Catch it.
  expect_false(
    resolve_tract_vintage(2019L) == "2020",
    info = "2019 leaking into the 2020-boundary universe = `>= 2019` off-by-one"
  )
  expect_identical(resolve_tract_vintage(2019L), "2010")
})

test_that("off-by-one: cutoff is `>= 2020`, NOT `> 2020` (2020 must be 2020-boundary)", {
  # Mutant `> 2020` (or `>= 2021`) would drop 2020 back to 2010. Catch it.
  expect_false(
    resolve_tract_vintage(2020L) == "2010",
    info = "2020 dropping to the 2010-boundary universe = `> 2020` off-by-one"
  )
  expect_identical(resolve_tract_vintage(2020L), "2020")
})

test_that("off-by-one: the transition happens BETWEEN 2019 and 2020, exactly once", {
  # The vintage string must flip exactly at the 2019→2020 step and nowhere else
  # in the adjacent neighborhood. A single, monotone transition rules out any
  # comparison-operator mutant in the 2018..2022 window.
  vintages <- vapply(2018:2022, function(y) resolve_tract_vintage(y), character(1))
  expect_identical(vintages, c("2010", "2010", "2020", "2020", "2020"))

  # Exactly one change-point, and it lands on the 2019→2020 edge.
  change_points <- which(vintages[-1] != vintages[-length(vintages)])
  expect_length(change_points, 1L)
  expect_identical((2018:2022)[change_points], 2019L)  # index before the flip
  expect_identical((2018:2022)[change_points + 1L], 2020L)  # the cutoff year
})

# ---------------------------------------------------------------------------
# BVA propagation — step8_batch_dir() path routing must flip at the same edge
# The cutoff is only useful if the batch directory it selects changes exactly
# at 2019→2020. Routing 2020 to the 2010 directory is the stale-batch bug.
# ---------------------------------------------------------------------------
BASE_DIR <- "data/08-block-group-overlap/output"

test_that("BVA: step8_batch_dir routes 2019 vs 2020 to DIFFERENT vintage dirs", {
  dir_below    <- step8_batch_dir(BASE_DIR, YEAR_BELOW)
  dir_boundary <- step8_batch_dir(BASE_DIR, YEAR_BOUNDARY)

  expect_match(dir_below,    "tract_vintage_2010$")
  expect_match(dir_boundary, "tract_vintage_2020$")
  expect_false(
    identical(dir_below, dir_boundary),
    info = "2019 and 2020 batches must never share a directory (stale-batch reuse)"
  )
})

test_that("BVA: step8_batch_dir routes 2020 and 2021 to the SAME (2020) vintage dir", {
  dir_boundary <- step8_batch_dir(BASE_DIR, YEAR_BOUNDARY)
  dir_above    <- step8_batch_dir(BASE_DIR, YEAR_ABOVE)

  expect_identical(dir_boundary, dir_above)
  expect_match(dir_above, "tract_vintage_2020$")
})

# ---------------------------------------------------------------------------
# BVA on the R/09 DEFECT #1 guard predicate
# The guard activates with `as.integer(CENSUS_VINTAGE) >= 2020`. It must agree
# with resolve_tract_vintage at every BVA point, or the runtime assertion and
# the path router could disagree about which years to check.
# ---------------------------------------------------------------------------
# Pure extraction of the guard's activation predicate (mirrors R/09 line ~460).
guard_active <- function(census_vintage) as.integer(census_vintage) >= 2020L

test_that("BVA: R/09 guard predicate agrees with resolver at 2019/2020/2021", {
  for (y in c(YEAR_BELOW, YEAR_BOUNDARY, YEAR_ABOVE)) {
    expect_identical(
      guard_active(y),
      resolve_tract_vintage(y) == "2020",
      info = sprintf("guard activation must match 2020-boundary resolution at %d", y)
    )
  }
  # Concretely: off below the cutoff, on at and above it.
  expect_false(guard_active(2019L))
  expect_true(guard_active(2020L))
  expect_true(guard_active(2021L))
})
