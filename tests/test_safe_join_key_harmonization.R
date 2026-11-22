#!/usr/bin/env Rscript
# Test: every safe_*_join() harmonizes join key types
#
# WHY THIS EXISTS. The 2026-04-05 fix added harmonize_join_key_types() to
# safe_left_join(), safe_inner_join() and safe_semi_join() and missed
# safe_anti_join() -- the one whose own documentation already claimed it
# ("Validates keys, harmonizes types, then calls dplyr::anti_join()"). A
# character key against an integer key therefore aborted an anti-join with
# dplyr's "incompatible types" error where its three siblings coerced and
# continued. That is the exact shape this project is bitten by most often: a
# CSV read gives character NPIs, a parquet or RDS round-trip gives integer or
# double ones.
#
# PARITY, NOT ONE FUNCTION. Testing only safe_anti_join() would re-create the
# defect: the bug was that one of four diverged, so the test asserts all four
# behave the same. Reported by the complexity audit (2026-11-20), which measured
# the semi/anti pair at 0.78 structural similarity and then diffed them.
#
# THIS FILE IS THE TWIN of ~/isochrones/tests/ci/test-safe-join-key-harmonization.R.
# R/join_safety.R is vendored in both repos, and the 2026-11-20 fix first landed
# in isochrones only -- the same one-of-N-diverges shape a second time, one level
# up. Fix either copy of the function and port both the fix and this test.

library(testthat)
library(here)
suppressPackageStartupMessages(library(dplyr))

source(here("R", "join_safety.R"))

context("safe_*_join key-type harmonization")

# Left reads as character (CSV); right reads as integer (parquet/RDS).
mk_left  <- function() data.frame(npi = c("1", "2", "3"), x = 1:3,
                                  stringsAsFactors = FALSE)
mk_right <- function() data.frame(npi = 1:2, stringsAsFactors = FALSE)

test_that("a character key joins to an integer key in every safe_*_join", {
  L <- mk_left(); R <- mk_right()

  # 2 of 3 match, so the thresholds have to admit one unmatched left row --
  # min_coverage = 0 would trip the "complete data loss" warning and the
  # coverage-derived unmatched-row cap instead, which tests the thresholds
  # rather than the coercion this file is about.
  expect_equal(nrow(suppressMessages(
    safe_left_join(L, R, by = "npi", use_enhanced_metrics = FALSE,
                   min_coverage = 0.5, max_left_only_rows = 1,
                   write_report = FALSE))), 3L)

  expect_equal(nrow(suppressMessages(
    safe_inner_join(L, R, by = "npi", use_enhanced_metrics = FALSE,
                    min_coverage = 0.5, write_report = FALSE))), 2L)

  expect_equal(nrow(suppressMessages(
    safe_semi_join(L, R, by = "npi", min_coverage = 0.5,
                   write_report = FALSE))), 2L)

  # The regression: this raised "Can't join `x$npi` with `y$npi` due to
  # incompatible types" until 2026-11-20.
  expect_equal(nrow(suppressMessages(
    safe_anti_join(L, R, write_report = FALSE, by = "npi"))), 1L)
})

test_that("harmonization announces the coercion rather than doing it silently", {
  L <- mk_left(); R <- mk_right()
  expect_message(
    safe_anti_join(L, R, by = "npi", write_report = FALSE),
    "Key type mismatch")
})

test_that("matching key types are left alone", {
  L <- data.frame(npi = c("1", "2", "3"), stringsAsFactors = FALSE)
  R <- data.frame(npi = c("1", "2"), stringsAsFactors = FALSE)
  # Same classes on both sides: no coercion message, same answers.
  expect_equal(nrow(suppressMessages(
    safe_anti_join(L, R, by = "npi", write_report = FALSE))), 1L)
  expect_equal(nrow(suppressMessages(
    safe_semi_join(L, R, by = "npi", min_coverage = 0.5,
                   write_report = FALSE))), 2L)
})

cat("✅ safe_*_join key-type harmonization: all four coerce mismatched keys\n")
