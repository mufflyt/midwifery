# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-join-safety.R
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
# =============================================================================
# UNIT TESTS - join_safety.R Functions
# =============================================================================
# Purpose: Test safe join functions with coverage validation and reporting
# Migrated from: test-safe-join.R (2026-02-14)
# Tests: safe_inner_join(), safe_left_join(), safe_semi_join(), safe_anti_join()
# =============================================================================

library(testthat)
library(dplyr)
library(here)

# Source the new join safety module
source(here::here("R", "join_safety.R"))

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 1. BASIC FUNCTIONALITY TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("safe_left_join performs standard left join correctly", {
  left <- data.frame(id = 1:5, value = letters[1:5])
  right <- data.frame(id = 3:7, data = LETTERS[3:7])

  result <- safe_left_join(left, right, by = "id",
                           label_left = "left", label_right = "right",
                           min_coverage = 0.60,  # 3 of 5 match
                           max_left_only_rows = 2,  # Allow 2 unmatched
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # All left rows preserved
  expect_equal(nrow(result), 5)
  expect_equal(result$id, 1:5)

  # Matched rows have data from right
  expect_equal(result$data[3:5], LETTERS[3:5])

  # Unmatched rows have NA from right
  expect_true(is.na(result$data[1]))
  expect_true(is.na(result$data[2]))
})

test_that("safe_inner_join performs inner join correctly", {
  left <- data.frame(id = 1:5, value = letters[1:5])
  right <- data.frame(id = 3:7, data = LETTERS[3:7])

  result <- safe_inner_join(left, right, by = "id",
                            label_left = "left", label_right = "right",
                            min_coverage = 0.60,  # 3 of 5 match
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # Only matching rows preserved
  expect_equal(nrow(result), 3)
  expect_equal(result$id, 3:5)
})

test_that("safe_left_join works with multiple join keys", {
  left <- data.frame(
    npi = c("1", "2", "3"),
    year = c(2020, 2020, 2021),
    name = c("A", "B", "C")
  )

  right <- data.frame(
    npi = c("1", "2", "3"),
    year = c(2020, 2020, 2020),
    status = c("active", "active", "retired")
  )

  result <- safe_left_join(left, right, by = c("npi", "year"),
                           label_left = "left", label_right = "right",
                           min_coverage = 0.66,  # 2 of 3 match
                           max_left_only_rows = 1,  # Allow 1 unmatched
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  expect_equal(nrow(result), 3)
  expect_equal(sum(!is.na(result$status)), 2)  # Only 2 matches
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 2. CARDINALITY DETECTION TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("safe_inner_join detects duplicate keys with expect_unique_both", {
  # Both sides have duplicate keys
  left <- data.frame(id = c(1, 1, 2), value = c("a", "b", "c"))
  right <- data.frame(id = c(1, 1, 2), data = c("x", "y", "z"))

  expect_error(
    safe_inner_join(left, right, by = "id",
                    expect_unique_both = TRUE,
                    label_left = "left", label_right = "right",
                    write_report = FALSE),
    "expected unique keys"
  )
})

test_that("safe_inner_join allows many-to-many when expect_unique_both=FALSE", {
  left <- data.frame(id = c(1, 1, 2), value = c("a", "b", "c"))
  right <- data.frame(id = c(1, 1, 2), data = c("x", "y", "z"))

  result <- safe_inner_join(left, right, by = "id",
                            expect_unique_both = FALSE,
                            label_left = "left", label_right = "right",
                            min_coverage = 1.0,
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # Cartesian product: 2×2 for id=1, 1×1 for id=2
  expect_equal(nrow(result), 5)  # (2*2) + (1*1) = 5
})

test_that("safe_left_join handles one-to-many joins (no error)", {
  # Left has unique keys, right has duplicates
  left <- data.frame(npi = c("1", "2", "3"), name = c("A", "B", "C"))
  right <- data.frame(
    npi = c("1", "1", "2", "3"),
    location = c("CA", "NY", "TX", "FL")
  )

  result <- safe_left_join(left, right, by = "npi",
                           expect_unique_right = FALSE,  # Allow duplicates
                           label_left = "left", label_right = "right",
                           min_coverage = 1.0,
                           max_duplication = 1.5,  # Allow 50% row growth
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # Row multiplication expected (1:M)
  expect_equal(nrow(result), 4)  # NPI 1 appears twice
})

test_that("safe_left_join handles many-to-one joins (no error)", {
  # Left has duplicates, right has unique keys
  left <- data.frame(
    npi = c("1", "1", "2", "3"),
    year = c(2020, 2021, 2020, 2020)
  )
  right <- data.frame(npi = c("1", "2", "3"), name = c("A", "B", "C"))

  result <- safe_left_join(left, right, by = "npi",
                           expect_unique_right = TRUE,
                           label_left = "left", label_right = "right",
                           min_coverage = 1.0,
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # All left rows preserved
  expect_equal(nrow(result), 4)
  expect_equal(result$name[1:2], c("A", "A"))  # NPI 1 matched twice
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 3. COVERAGE VALIDATION TESTS (Bug #26 Fix)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("safe_left_join preserves all left rows", {
  left <- data.frame(id = 1:100, value = 1:100)
  right <- data.frame(id = 50:150, data = 1:101)

  # Left join should preserve all 100 rows
  result <- safe_left_join(left, right, by = "id",
                           label_left = "left", label_right = "right",
                           min_coverage = 0.50,  # Only 51 of 100 match
                           max_left_only_rows = 49,  # Allow 49 unmatched
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  expect_equal(nrow(result), 100)
})

test_that("safe_left_join coverage validation works correctly", {
  left <- data.frame(id = 1:1000, value = 1:1000)
  right <- data.frame(id = 500:1500, data = 1:1001)

  result <- safe_left_join(left, right, by = "id",
                           label_left = "left", label_right = "right",
                           min_coverage = 0.50,  # 501 of 1000 match
                           max_left_only_rows = 499,  # Allow 499 unmatched
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  expect_equal(nrow(result), 1000)  # All left rows preserved
  expect_equal(sum(is.na(result$data)), 499)  # First 499 have no match
})

test_that("safe_left_join detects row multiplication", {
  left <- data.frame(npi = c("1", "2", "3"), name = c("A", "B", "C"))
  right <- data.frame(
    npi = c("1", "1", "1", "2", "3"),  # NPI 1 appears 3 times
    location = c("CA", "NY", "TX", "FL", "AZ")
  )

  # Should error with default max_duplication=1.02
  expect_error(
    safe_left_join(left, right, by = "npi",
                   expect_unique_right = FALSE,  # Allow duplicates to test duplication check
                   label_left = "left", label_right = "right",
                   min_coverage = 1.0,
                   use_enhanced_metrics = FALSE,
                   write_report = FALSE),
    "duplication.*exceeds"
  )
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 4. INPUT VALIDATION TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("safe_left_join validates 'by' parameter is required", {
  left <- data.frame(id = 1:3, value = letters[1:3])
  right <- data.frame(id = 1:3, data = LETTERS[1:3])

  expect_error(
    safe_left_join(left, right, by = NULL,
                   label_left = "left", label_right = "right"),
    "'by' parameter is required"
  )
})

test_that("safe_inner_join validates unique keys when declared", {
  left <- data.frame(id = c(1, 1, 2), value = c("a", "b", "c"))
  right <- data.frame(id = c(1, 2, 3), data = LETTERS[1:3])

  # Should error - left has duplicate keys but expect_unique_both=TRUE
  expect_error(
    safe_inner_join(left, right, by = "id",
                    expect_unique_both = TRUE,
                    label_left = "left", label_right = "right",
                    write_report = FALSE),
    "expected unique keys"
  )
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 5. SEMI/ANTI JOIN TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("safe_semi_join filters to matches only", {
  left <- data.frame(id = 1:5, value = letters[1:5])
  right <- data.frame(id = 3:7, data = LETTERS[3:7])

  result <- safe_semi_join(left, right, by = "id",
                           label_left = "left", label_right = "right",
                           min_coverage = 0.60,  # 3 of 5 match
                           write_report = FALSE)

  # Only rows with matches preserved
  expect_equal(nrow(result), 3)
  expect_equal(result$id, 3:5)
  # Semi join doesn't add columns from right
  expect_false("data" %in% names(result))
})

test_that("safe_anti_join filters to non-matches only", {
  left <- data.frame(id = 1:5, value = letters[1:5])
  right <- data.frame(id = 3:7, data = LETTERS[3:7])

  result <- safe_anti_join(left, right, by = "id",
                           label_left = "left", label_right = "right",
                           max_matched = 0.60,  # Allow 60% to be filtered
                           write_report = FALSE)

  # Only rows without matches preserved
  expect_equal(nrow(result), 2)
  expect_equal(result$id, 1:2)
  # Anti join doesn't add columns from right
  expect_false("data" %in% names(result))
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 6. REAL-WORLD SIMULATION TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("SIMULATION: ABOG-NPI matching preserves all ABOG rows", {
  set.seed(42)

  # Simulate 10,000 ABOG physicians
  abog <- data.frame(
    abog_id = 1:10000,
    physician_name = paste0("Doctor_", 1:10000)
  )

  # Simulate 84% match rate (realistic for ABOG-NPI)
  matched_ids <- sample(1:10000, 8400)
  npi_matches <- data.frame(
    abog_id = matched_ids,
    npi = sprintf("1%09d", 1:8400)
  )

  result <- safe_left_join(abog, npi_matches, by = "abog_id",
                           label_left = "ABOG", label_right = "NPI_matches",
                           min_coverage = 0.84,
                           max_left_only_rows = 1600,  # Allow 1600 unmatched (16%)
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # INVARIANT: All ABOG rows preserved
  expect_equal(nrow(result), 10000)

  # 84% should have NPI
  expect_equal(sum(!is.na(result$npi)), 8400)
})

test_that("SIMULATION: Retirement join catches duplicate keys", {
  # Simulate bug: RIGHT side has duplicate NPIs
  cohort <- data.frame(
    npi = sprintf("1%09d", 1:500),
    name = paste0("Physician_", 1:500)
  )

  # RIGHT: Retirement data has duplicate NPIs (multiple status changes)
  retirement_buggy <- data.frame(
    npi = c(sprintf("1%09d", 1:500), sprintf("1%09d", 1:500)),  # DUPLICATES on right!
    status = rep(c("active", "retired"), each = 500)
  )

  # safe_left_join should CATCH this with expect_unique_right=TRUE
  expect_error(
    safe_left_join(cohort, retirement_buggy, by = "npi",
                   expect_unique_right = TRUE,
                   label_left = "cohort", label_right = "retirement",
                   use_enhanced_metrics = FALSE,
                   write_report = FALSE),
    "expected unique keys"
  )
})

test_that("SIMULATION: Census tract join handles sparse matches", {
  set.seed(42)
  # Simulate isochrones (some tracts covered, others not)
  isochrones <- data.frame(
    fips_tract = paste0("44", sprintf("%09d", sample(1:74000, 5000)))  # 5000 tracts
  )

  # Census data for all 74,000 tracts
  census <- data.frame(
    fips_tract = paste0("44", sprintf("%09d", 1:74000)),
    population = rpois(74000, lambda = 4000)
  )

  result <- safe_left_join(isochrones, census, by = "fips_tract",
                           label_left = "isochrones", label_right = "census",
                           min_coverage = 0.99,  # Census has all tracts
                           use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # All isochrone rows preserved
  expect_equal(nrow(result), 5000)

  # All matched (census has all tracts)
  expect_equal(sum(!is.na(result$population)), 5000)
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 7. COVERAGE CALCULATION TESTS (Bug #26 Fix Verification)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("Bug #26 fix: Coverage uses semi_join, not output row count", {
  # Setup: Many-to-many join where output rows > input rows
  left <- data.frame(id = c(1, 1, 2), value = c("a", "b", "c"))
  right <- data.frame(id = c(1, 1, 2), data = c("x", "y", "z"))

  # With expect_unique_both=FALSE, this creates 5 output rows from 3 input
  result <- safe_inner_join(left, right, by = "id",
                            expect_unique_both = FALSE,
                            label_left = "left", label_right = "right",
                            min_coverage = 1.0,  # All 3 left rows match
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)

  # Output has 5 rows (row multiplication)
  expect_equal(nrow(result), 5)

  # But coverage should be 100% (all 3 left rows matched)
  # NOT >100% which would happen if using nrow(result)/nrow(left)
  # This test passes because safe_inner_join uses semi_join for coverage
})

test_that("Coverage threshold enforcement works correctly", {
  left <- data.frame(id = 1:100, value = 1:100)
  right <- data.frame(id = 50:100, data = 1:51)  # Only 51 of 100 match

  # Should error - only 51% coverage but min_coverage=0.90
  expect_error(
    safe_inner_join(left, right, by = "id",
                    label_left = "left", label_right = "right",
                    min_coverage = 0.90,
                    write_report = FALSE),
    "coverage.*below.*threshold"
  )

  # Should pass - 51% coverage with min_coverage=0.50
  result <- safe_inner_join(left, right, by = "id",
                            label_left = "left", label_right = "right",
                            min_coverage = 0.50,
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)
  expect_equal(nrow(result), 51)
})

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 8. ENVIRONMENT VARIABLE OVERRIDE TESTS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

test_that("JOIN_MIN_COVERAGE environment variable works", {
  left <- data.frame(id = 1:100, value = 1:100)
  right <- data.frame(id = 50:100, data = 1:51)  # 51% coverage

  # Set environment variable
  old_val <- Sys.getenv("JOIN_MIN_COVERAGE", unset = NA)
  Sys.setenv(JOIN_MIN_COVERAGE = "0.50")

  # Should pass with env var setting
  result <- safe_inner_join(left, right, by = "id",
                            label_left = "left", label_right = "right",
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)
  expect_equal(nrow(result), 51)

  # Restore environment
  if (is.na(old_val)) {
    Sys.unsetenv("JOIN_MIN_COVERAGE")
  } else {
    Sys.setenv(JOIN_MIN_COVERAGE = old_val)
  }
})

test_that("Explicit parameter overrides environment variable", {
  left <- data.frame(id = 1:100, value = 1:100)
  right <- data.frame(id = 90:100, data = 1:11)  # 11% coverage

  # Set high env var threshold
  old_val <- Sys.getenv("JOIN_MIN_COVERAGE", unset = NA)
  Sys.setenv(JOIN_MIN_COVERAGE = "0.90")

  # Should pass - explicit parameter (0.10) overrides env var (0.90)
  result <- safe_inner_join(left, right, by = "id",
                            label_left = "left", label_right = "right",
                            min_coverage = 0.10,  # Explicit parameter
                            use_enhanced_metrics = FALSE,
                           write_report = FALSE)
  expect_equal(nrow(result), 11)

  # Restore environment
  if (is.na(old_val)) {
    Sys.unsetenv("JOIN_MIN_COVERAGE")
  } else {
    Sys.setenv(JOIN_MIN_COVERAGE = old_val)
  }
})

cat("✅ Join safety tests complete: safe_inner_join(), safe_left_join(), safe_semi_join(), safe_anti_join()\n")
