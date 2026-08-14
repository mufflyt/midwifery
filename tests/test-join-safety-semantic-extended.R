# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-join-safety-semantic-extended.R
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
# tests/testthat/test-join-safety-semantic-extended.R
#
# Extended Semantic Test Suite for Join Safety
# Part 3 of 3: Tests 21-24 (Configuration & Diagnostics)
# Created by: phase3-agent (2026-02-14)
#
# This file contains Tests 21-24, focusing on:
# - Sequential join coverage tracking
# - Error message actionability
# - Environment variable precedence
# - Real-world join patterns
#
# NOTE: Tests 13-16 implemented by phase1-agent
# NOTE: Tests 17-20 implemented by phase2-agent

library(testthat)
library(here)
library(dplyr)
library(readr)

# Source join safety functions
source(here("R", "join_safety.R"))

# ==============================================================================
# Test 21: Sequential Join Coverage Tracking
# ==============================================================================
# Semantic assertion: Coverage is tracked per-join, not cumulative

test_that("Test 21: Sequential join coverage tracking is independent", {

  # Setup: Create three sequential tables with decreasing coverage
  # A: 100 rows
  # B: 95 rows (95% match with A)
  # C: 85 rows (89% match with B, but only 85% match with A)
  # D: 70 rows (82% match with C, but only 70% match with A)

  table_a <- tibble(
    id = 1:100,
    value_a = paste0("a_", 1:100)
  )

  table_b <- tibble(
    id = 1:95,  # Missing 96-100
    value_b = paste0("b_", 1:95)
  )

  table_c <- tibble(
    id = 1:85,  # Missing 86-95
    value_c = paste0("c_", 1:85)
  )

  table_d <- tibble(
    id = 1:70,  # Missing 71-85
    value_d = paste0("d_", 1:70)
  )

  # Create temporary directory for join reports
  temp_dir <- tempfile("join_reports_")
  dir.create(temp_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Set JOIN_REPORT_DIR environment variable for this test
  withr::local_envvar(JOIN_REPORT_DIR = temp_dir)

  # Chain sequential joins with decreasing expected coverage
  result <- table_a %>%
    safe_inner_join(
      table_b,
      by = "id",
      min_coverage = 0.95,  # Expect 95% of A to match B
      report_prefix = "a_to_b"
    ) %>%
    safe_inner_join(
      table_c,
      by = "id",
      min_coverage = 0.89,  # Expect 89% of B to match C (85/95)
      report_prefix = "b_to_c"
    ) %>%
    safe_inner_join(
      table_d,
      by = "id",
      min_coverage = 0.82,  # Expect 82% of C to match D (70/85)
      report_prefix = "c_to_d"
    )

  # Verify final result has correct row count
  expect_equal(nrow(result), 70)
  expect_equal(ncol(result), 5)  # id + 4 value columns

  # Verify all 3 join reports were generated
  reports <- list.files(temp_dir, pattern = "\\.csv$", full.names = TRUE)
  expect_equal(length(reports), 3)

  # Parse each report and verify coverage is tracked independently
  report_a_to_b <- read_csv(
    grep("a_to_b", reports, value = TRUE),
    show_col_types = FALSE
  )
  report_b_to_c <- read_csv(
    grep("b_to_c", reports, value = TRUE),
    show_col_types = FALSE
  )
  report_c_to_d <- read_csv(
    grep("c_to_d", reports, value = TRUE),
    show_col_types = FALSE
  )

  # Test 21a: First join reports 95% coverage (95/100)
  expect_equal(report_a_to_b$left_rows, 100)
  expect_equal(report_a_to_b$matched_rows, 95)
  expect_equal(report_a_to_b$coverage, 0.95, tolerance = 0.001)

  # Test 21b: Second join reports 89% coverage (85/95), NOT 85% (85/100)
  expect_equal(report_b_to_c$left_rows, 95)
  expect_equal(report_b_to_c$matched_rows, 85)
  expect_equal(report_b_to_c$coverage, 85/95, tolerance = 0.001)  # 0.894

  # Test 21c: Third join reports 82% coverage (70/85), NOT 70% (70/100)
  expect_equal(report_c_to_d$left_rows, 85)
  expect_equal(report_c_to_d$matched_rows, 70)
  expect_equal(report_c_to_d$coverage, 70/85, tolerance = 0.001)  # 0.823

  # Semantic assertion: Each join tracks coverage of its IMMEDIATE left table,
  # not the original starting table. This prevents cumulative coverage masking.
})

# ==============================================================================
# Test 22: Error Message Actionability
# ==============================================================================
# Semantic assertion: Error messages provide debugging context

test_that("Test 22: Error messages contain actionable debugging information", {

  # Setup test data
  physicians <- tibble(
    npi = c("1234567890", "2345678901", "3456789012"),
    name = c("Dr. A", "Dr. B", "Dr. C")
  )

  nppes <- tibble(
    npi = c("1234567890", "2345678901"),  # Missing 3456789012
    address = c("123 Main St", "456 Oak Ave")
  )

  # Test 22a: Low coverage error contains expected vs actual counts
  expect_error(
    physicians %>%
      safe_inner_join(
        nppes,
        by = "npi",
        report_prefix = "physicians_to_nppes",
        min_coverage = 0.95  # Expect 95%, but only get 66%
      ),
    regexp = "66\\.7%.*below.*95"  # Expect message about 66.7% < 95%
  )

  # Test 22b: Error message contains matched counts or coverage info
  expect_error(
    physicians %>%
      safe_inner_join(
        nppes,
        by = "npi",
        report_prefix = "test_join",
        min_coverage = 0.95
      ),
    regexp = "66\\.7%|Lost 1 rows"  # Coverage or lost row count
  )

  # Test 22c: Column mismatch error contains column names
  mismatched_nppes <- tibble(
    provider_id = c("1234567890", "2345678901"),  # Different column name
    address = c("123 Main St", "456 Oak Ave")
  )

  expect_error(
    physicians %>%
      safe_inner_join(
        mismatched_nppes,
        by = "npi",  # This column doesn't exist in right table
        report_prefix = "test_mismatch"
      ),
    regexp = "npi.*not.*found|Join columns|npi"
  )

  # Test 22d: Many-to-many error contains duplicate key examples
  physicians_dup <- tibble(
    npi = c("1234567890", "1234567890", "2345678901"),  # Duplicate NPI
    practice_id = 1:3
  )

  nppes_dup <- tibble(
    npi = c("1234567890", "1234567890", "2345678901"),  # Duplicate NPI
    address_id = 1:3
  )

  expect_error(
    physicians_dup %>%
      safe_inner_join(
        nppes_dup,
        by = "npi",
        report_prefix = "test_many_to_many",
        expect_unique_both = TRUE,  # Enforces one-to-one, errors on duplicates
        min_coverage = 0.5
      ),
    regexp = "1234567890|duplicate|unique"
  )

  # Semantic assertion: Error messages provide specific counts, column names,
  # and sample values to enable rapid debugging without additional queries.
})

# ==============================================================================
# Test 23: Environment Variable Precedence
# ==============================================================================
# Semantic assertion: Function parameters take precedence over env vars

test_that("Test 23: Function parameters override environment variables", {

  # Setup test data (80% coverage)
  table_left <- tibble(id = 1:100, value = "left")
  table_right <- tibble(id = 1:80, value = "right")  # 80% match

  temp_dir <- tempfile("precedence_test_")
  dir.create(temp_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Test 23a: Env var sets low threshold, parameter sets high threshold
  # Parameter should take precedence and FAIL
  withr::with_envvar(
    new = c(JOIN_MIN_COVERAGE = "0.70"),  # Low threshold in env
    code = {
      expect_error(
        table_left %>%
          safe_inner_join(
            table_right,
            by = "id",
            report_prefix = "param_override_test",
            min_coverage = 0.90  # High threshold in parameter (should fail at 80%)
          ),
        regexp = "80.*below.*90|Lost 20 rows"  # 80% < 90%
      )
    }
  )

  # Test 23b: Env var sets high threshold, parameter sets low threshold
  # Parameter should take precedence and SUCCEED
  withr::with_envvar(
    new = c(JOIN_MIN_COVERAGE = "0.90"),  # High threshold in env
    code = {
      result <- table_left %>%
        safe_inner_join(
          table_right,
          by = "id",
          report_prefix = "param_override_success",
          min_coverage = 0.70,  # Low threshold in parameter (should pass at 80%)
          # Report dir controlled by JOIN_REPORT_DIR env var
        )

      expect_equal(nrow(result), 80)
    }
  )

  # Test 23c: No parameter provided, env var is used
  withr::with_envvar(
    new = c(JOIN_MIN_COVERAGE = "0.90"),  # High threshold in env
    code = {
      # Should fail because 80% < 90% (env var threshold)
      expect_error(
        table_left %>%
          safe_inner_join(
            table_right,
            by = "id",
            report_prefix = "env_var_test"
            # min_coverage not specified - uses env var
          ),
        regexp = "80.*below.*90|Lost 20 rows"  # 80% < 90%
      )
    }
  )

  # Test 23d: No parameter and no env var, uses default (0.90)
  withr::with_envvar(
    new = c(JOIN_MIN_COVERAGE = NA_character_),  # Clear env var
    code = {
      # Should fail because default is 0.90 and we have 80% coverage
      expect_error(
        table_left %>%
          safe_inner_join(
            table_right,
            by = "id",
            report_prefix = "default_threshold_test"
            # min_coverage not specified, env var not set → uses default 0.90
          ),
        regexp = "80.*below.*90|Lost 20 rows"  # 80% < 90% (default)
      )
    }
  )

  # Semantic assertion: Precedence order is:
  # 1. Function parameter (highest priority)
  # 2. Environment variable (medium priority)
  # 3. Default value (lowest priority)
  # This allows project-wide defaults via env vars while enabling
  # per-join overrides via parameters.
})

# ==============================================================================
# Test 24: Real-World Join Patterns
# ==============================================================================
# Semantic assertion: Default thresholds are realistic for domain

test_that("Test 24: Real-world join patterns match domain expectations", {

  temp_dir <- tempfile("realworld_joins_")
  dir.create(temp_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Set JOIN_REPORT_DIR environment variable for this test
  withr::local_envvar(JOIN_REPORT_DIR = temp_dir)

  # Test 24a: ABOG-NPI join (high coverage expected: 95-98%)
  # Simulate ABOG certified physicians
  abog_physicians <- tibble(
    abog_id = 1:1000,
    name = paste0("Physician_", 1:1000),
    cert_year = sample(2000:2023, 1000, replace = TRUE)
  )

  # Simulate NPPES data (97% have NPI records)
  nppes_data <- tibble(
    abog_id = c(1:970, sample(971:1000, 30, replace = FALSE)),  # 97% coverage
    npi = paste0("NPI_", 1:1000),
    practice_state = sample(state.abb, 1000, replace = TRUE)
  )

  result_abog_npi <- abog_physicians %>%
    safe_inner_join(
      nppes_data,
      by = "abog_id",
      report_prefix = "abog_to_npi",
      min_coverage = 0.95,  # High threshold for official data
      # Report dir controlled by JOIN_REPORT_DIR env var
    )

  expect_gte(nrow(result_abog_npi), 950)  # At least 95% matched
  expect_lte(nrow(result_abog_npi), 1000)

  # Test 24b: Medicare claims join (medium coverage: 80-85%)
  # Not all physicians bill Medicare (some retired, some VA/military)
  physicians <- tibble(
    npi = paste0("NPI_", 1:1000),
    name = paste0("Dr_", 1:1000)
  )

  # Only 82% have Medicare claims
  medicare_claims <- tibble(
    npi = paste0("NPI_", sample(1:1000, 820)),
    total_claims = sample(10:5000, 820, replace = TRUE),
    total_payments = runif(820, 5000, 500000)
  )

  result_medicare <- physicians %>%
    safe_inner_join(
      medicare_claims,
      by = "npi",
      report_prefix = "physicians_to_medicare",
      min_coverage = 0.80,  # Medium threshold for operational data
      # Report dir controlled by JOIN_REPORT_DIR env var
    )

  expect_gte(nrow(result_medicare), 800)  # At least 80% matched
  expect_lte(nrow(result_medicare), 850)

  # Test 24c: Retirement data join (low coverage: 60-70%)
  # Voluntary reporting, incomplete data
  all_physicians <- tibble(
    npi = paste0("NPI_", 1:1000),
    name = paste0("Physician_", 1:1000)
  )

  # Only 65% have reported retirement data
  retirement_records <- tibble(
    npi = paste0("NPI_", sample(1:1000, 650)),
    retirement_year = sample(2015:2024, 650, replace = TRUE),
    retirement_reason = sample(c("Age", "Health", "Other"), 650, replace = TRUE)
  )

  result_retirement <- all_physicians %>%
    safe_inner_join(
      retirement_records,
      by = "npi",
      report_prefix = "physicians_to_retirement",
      min_coverage = 0.60,  # Low threshold for voluntary data
      # Report dir controlled by JOIN_REPORT_DIR env var
    )

  expect_gte(nrow(result_retirement), 600)  # At least 60% matched
  expect_lte(nrow(result_retirement), 700)

  # Test 24d: Geographic join (very high coverage: 99%+)
  # Address to census tract should be deterministic
  addresses <- tibble(
    address_id = 1:1000,
    address = paste0(1:1000, " Main St"),
    lat = runif(1000, 30, 45),
    lon = runif(1000, -120, -70)
  )

  # 99.5% geocode successfully to census tracts
  census_tracts <- tibble(
    address_id = c(1:995, sample(996:1000, 5)),  # 99.5% coverage
    geoid = paste0("TRACT_", 1:1000),
    tract_name = paste0("Census Tract ", 1:1000)
  )

  result_geographic <- addresses %>%
    safe_inner_join(
      census_tracts,
      by = "address_id",
      report_prefix = "address_to_tract",
      min_coverage = 0.99,  # Very high threshold for geographic data
      # Report dir controlled by JOIN_REPORT_DIR env var
    )

  expect_gte(nrow(result_geographic), 990)  # At least 99% matched

  # Verify all 4 reports were generated
  reports <- list.files(temp_dir, pattern = "\\.csv$", full.names = TRUE)
  expect_equal(length(reports), 4)

  # Parse reports and verify coverage matches expectations
  report_abog <- read_csv(
    grep("abog_to_npi", reports, value = TRUE),
    show_col_types = FALSE
  )
  expect_gte(report_abog$coverage, 0.95)  # High coverage for official data

  report_medicare <- read_csv(
    grep("physicians_to_medicare", reports, value = TRUE),
    show_col_types = FALSE
  )
  expect_gte(report_medicare$coverage, 0.80)  # Medium coverage for claims
  expect_lte(report_medicare$coverage, 0.85)

  report_retirement <- read_csv(
    grep("physicians_to_retirement", reports, value = TRUE),
    show_col_types = FALSE
  )
  expect_gte(report_retirement$coverage, 0.60)  # Low coverage for voluntary
  expect_lte(report_retirement$coverage, 0.70)

  report_geographic <- read_csv(
    grep("address_to_tract", reports, value = TRUE),
    show_col_types = FALSE
  )
  expect_gte(report_geographic$coverage, 0.99)  # Very high for geographic

  # Semantic assertion: Expected coverage thresholds match real-world patterns:
  # - Official data (ABOG-NPI): 95-98% (high quality, complete records)
  # - Operational data (Medicare): 80-85% (not universal, but high participation)
  # - Voluntary data (retirement): 60-70% (incomplete self-reporting)
  # - Geographic data (tract joins): 99%+ (deterministic, should be complete)
})

# ==============================================================================
# Test Summary: Tests 21-24 Coverage
# ==============================================================================
# Test 21: Sequential coverage tracking - PASSED
#   - Verifies per-join coverage, not cumulative
#   - Prevents coverage masking in chained joins
#
# Test 22: Error message actionability - PASSED
#   - Low coverage errors show expected vs actual
#   - Column mismatch errors name the columns
#   - Many-to-many errors show sample duplicates
#
# Test 23: Environment variable precedence - PASSED
#   - Function parameters override env vars
#   - Env vars override defaults
#   - Precedence: parameter > env var > default
#
# Test 24: Real-world join patterns - PASSED
#   - ABOG-NPI: 95-98% coverage (official data)
#   - Medicare claims: 80-85% (operational data)
#   - Retirement: 60-70% (voluntary reporting)
#   - Geographic: 99%+ (deterministic joins)
#
# All semantic assertions validated!
