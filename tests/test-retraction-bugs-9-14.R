# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-retraction-bugs-9-14.R
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
# RETRACTION GUARDS: Regression Tests for Bugs 9-14
# =============================================================================
#
# Purpose: Three-modality regression tests (unit, property-based, integration)
#          for retraction-level and high-priority production bugs discovered in
#          the 2026-04-18 code audit.
#
# Bugs covered:
#   Bug 9:  Silent race category drop from factor level mismatch (Table 1)
#   Bug 10: Missing subspecialty guard in regression table (Table 2)
#   Bug 12: Silent NA->0 in MOE propagation (overlap_computation.R)
#   Bug 13: 0-row race group guard fires too late (Table 1)
#   Bug 14: Percentage scale mismatch in audit log (Table 1)
#
# Test modalities per bug:
#   Test 1: Unit test — minimal synthetic data that triggers the bug
#   Test 2: Property-based — randomized/fuzzed data, invariant checks
#   Test 3: Integration — full function call with realistic data
#
# Conventions:
#   - No grep/grepl for verification; all assertions use function return values
#   - Package:: prefix on every function call
#   - Descriptive variable names (no df, data, out, results)
#   - assertthat::assert_that() for validation
#
# Created: 2026-04-18
# =============================================================================

library(testthat)
library(here)

# ---------------------------------------------------------------------------
# Helpers shared across tests
# ---------------------------------------------------------------------------

#' Build a minimal access_data tibble for Table 1 / Table 2 tests.
#'
#' @param categories [character]: category keys that appear in the data
#' @param race_labels [list]: named list mapping category -> display label
#' @param n_rows_per_cat [integer]: rows per category (years)
#' @return tibble with columns category, range, year, total, count, percent
.make_access_tbl <- function(categories,
                              n_rows_per_cat = 3L,
                              range_val      = 3600L) {
  n_total <- length(categories) * n_rows_per_cat
  tibble::tibble(
    category = rep(categories, each = n_rows_per_cat),
    range    = range_val,
    year     = rep(2020L:(2020L + n_rows_per_cat - 1L), times = length(categories)),
    total    = sample(50000L:200000L, size = n_total, replace = TRUE),
    count    = sample(10000L:50000L,  size = n_total, replace = TRUE),
    percent  = stats::runif(n_total, min = 0.30, max = 0.95)
  )
}

#' Simulate the race_labels lookup + NA-guard logic from create_table1.
#'
#' Mirrors the post-Bug-9-fix logic: assigns race_ethnicity via element-wise
#' lookup, producing NA for unmapped keys, then stops if any NA is produced.
#' Uses vapply() rather than unlist(race_labels[category]) so that missing keys
#' yield NA_character_ (not a shorter vector that causes assignment errors).
#'
#' @param tbl_data [data.frame]: must have a 'category' column
#' @param race_labels [list]: named list of category -> label mappings
#' @return tbl_data with race_ethnicity column added (stops on NA)
.apply_race_label_guard <- function(tbl_data, race_labels) {
  tbl_data[["race_ethnicity"]] <- vapply(
    tbl_data[["category"]],
    function(cat_key) {
      lbl <- race_labels[[cat_key]]
      if (is.null(lbl)) NA_character_ else as.character(lbl)
    },
    FUN.VALUE = character(1L)
  )
  n_na <- sum(is.na(tbl_data[["race_ethnicity"]]))
  if (n_na > 0L) {
    na_cats <- unique(tbl_data[["category"]][is.na(tbl_data[["race_ethnicity"]])])
    stop(sprintf(
      paste0(
        "RETRACTION GUARD [Table 1 / Bug 9]: %d rows have NA race_ethnicity ",
        "after race_labels lookup. Categories without a mapping: %s."
      ),
      n_na, paste(na_cats, collapse = ", ")
    ), call. = FALSE)
  }
  tbl_data
}

#' Simulate the subspecialty completeness guard from create_table2.
#'
#' Mirrors the post-Bug-10-fix logic: stops if any expected subspecialty
#' is absent from access_data$subspecialty.
#'
#' @param access_data [data.frame]: must have a 'subspecialty' column
#' @param expected_subspecialties [character]: vector of required codes
#' @return access_data invisibly (stops if any are missing)
.apply_subspecialty_guard <- function(access_data,
                                       expected_subspecialties = c(
                                         "FPMRS", "GO", "MFM", "REI",
                                         "CFP", "MIGS", "PAG"
                                       )) {
  present  <- unique(access_data[["subspecialty"]])
  missing  <- setdiff(expected_subspecialties, present)
  if (length(missing) > 0L) {
    stop(sprintf(
      paste0(
        "RETRACTION GUARD [Table 2 / Bug 10]: %d subspecialt%s missing from ",
        "access_data before regression. Missing: %s."
      ),
      length(missing),
      ifelse(length(missing) == 1L, "y is", "ies are"),
      paste(missing, collapse = ", ")
    ), call. = FALSE)
  }
  invisible(access_data)
}

#' Simulate the conservative MOE allocation + Bug 12 warning.
#'
#' Mirrors the post-Bug-12-fix logic in 08-area-weighted-overlap.R:
#' coalesces NA MOE to 0 but emits a warning if any tract had overlap > 0
#' and a NA MOE.
#'
#' @param overlap_fraction [numeric]: vector of overlap fractions (0-1)
#' @param population_moe [numeric]: vector of ACS MOEs (may contain NA)
#' @param step_label [character]: label for the warning message
#' @return list with moe_allocated [numeric] and n_moe_na_substituted [integer]
.allocate_moe_with_bug12_guard <- function(overlap_fraction,
                                            population_moe,
                                            step_label = "test") {
  moe_if_overlap <- dplyr::if_else(overlap_fraction > 0, population_moe, 0)
  moe_allocated  <- dplyr::coalesce(moe_if_overlap, 0)

  n_substituted <- sum(overlap_fraction > 0 & is.na(population_moe), na.rm = TRUE)
  if (n_substituted > 0L) {
    warning(sprintf(
      "[%s / Bug 12] %d tract(s) had NA population_moe coalesced to 0.",
      step_label, n_substituted
    ), call. = FALSE)
  }
  list(moe_allocated = moe_allocated, n_moe_na_substituted = n_substituted)
}

#' Simulate the 0-row race group guard (Bug 13 fix).
#'
#' Mirrors the post-Bug-13-fix logic: check nrow > 0 BEFORE accessing
#' $mean_population to avoid NaN/Inf from numeric(0) operations.
#'
#' @param grp_df [data.frame]: filtered race group tibble (may be 0-row)
#' @param grp_name [character]: label for error messages
#' @return grp_df invisibly (stops if 0 rows or non-finite mean_population)
.apply_zero_row_guard <- function(grp_df, grp_name) {
  if (nrow(grp_df) == 0L) {
    stop(sprintf(
      "RETRACTION GUARD [Table 1 / Bug 13]: '%s' group has 0 rows. Check race_ethnicity labels.",
      grp_name
    ), call. = FALSE)
  }
  # Only access $mean_population AFTER confirming nrow > 0
  if (!is.finite(grp_df[["mean_population"]][1L])) {
    stop(sprintf(
      "RETRACTION GUARD [Table 1 / Bug 13]: '%s'$mean_population is non-finite.",
      grp_name
    ), call. = FALSE)
  }
  invisible(grp_df)
}

#' Simulate Bug 14 audit log formatting.
#'
#' safe_percent() returns 0-100. sprintf("%.1f%%", safe_percent(...)) is
#' correct.
#' The bug was using safe_percent() result directly with "%.1f%%" — correct
#' only if the function already scales to 0-100 (which it does). This helper
#' tests that the formatted string is in the range "0.0%"-"100.0%".
#'
#' @param part [numeric]: numerator
#' @param total [numeric]: denominator
#' @return character string like "45.3%"
.format_percent_audit <- function(part, total) {
  # safe_percent already multiplies by 100; sprintf expects a 0-100 value
  pct_scaled <- if (total == 0) 0 else round((part / total) * 100, digits = 1)
  sprintf("%.1f%%", pct_scaled)
}

# =============================================================================
# BUG 9: Silent race category drop from factor level mismatch
# =============================================================================

# --- Test 9.1: Unit test ---------------------------------------------------
test_that("Bug 9 unit: unmatched race category key raises RETRACTION GUARD, not silent drop", {
  # Minimal config: only 'total_female' and 'total_female_white_nh' are mapped
  race_labels_partial <- list(
    total_female        = "Total Female",
    total_female_white_nh = "White non-Hispanic"
  )

  # Data includes a category with no mapping in race_labels
  access_tbl_with_orphan <- .make_access_tbl(
    categories = c("total_female", "total_female_white_nh", "total_female_asian")
  )

  # The guard must stop(), not silently produce NA rows
  expect_error(
    .apply_race_label_guard(access_tbl_with_orphan, race_labels_partial),
    regexp = "RETRACTION GUARD.*Bug 9",
    info = "Unmatched category 'total_female_asian' must stop(), not produce silent NAs"
  )
})

# --- Test 9.2: Property-based test -----------------------------------------
test_that("Bug 9 property: guard fires for ANY subset of categories not in race_labels", {
  # Property: if ANY category key is absent from race_labels, the guard MUST stop.
  # We test this across 20 random samples of missing keys.
  all_categories <- c(
    "total_female", "total_female_white_nh", "total_female_black",
    "total_female_aian", "total_female_asian", "total_female_hipi",
    "total_female_two_or_more", "total_female_hispanic"
  )
  full_labels <- stats::setNames(
    as.list(paste("Label for", all_categories)),
    all_categories
  )

  set.seed(42L)
  for (trial_index in seq_len(20L)) {
    # Drop 1-3 random keys from the label map
    n_keys_to_drop <- sample(1L:3L, size = 1L)
    keys_to_drop   <- sample(all_categories, size = n_keys_to_drop)
    partial_labels <- full_labels[setdiff(names(full_labels), keys_to_drop)]

    access_tbl_full <- .make_access_tbl(categories = all_categories)

    expect_error(
      .apply_race_label_guard(access_tbl_full, partial_labels),
      regexp = "RETRACTION GUARD.*Bug 9",
      info   = sprintf(
        "Trial %d: dropping keys '%s' must trigger guard",
        trial_index, paste(keys_to_drop, collapse = ", ")
      )
    )
  }
})

# --- Test 9.3: Integration test --------------------------------------------
test_that("Bug 9 integration: complete race_labels mapping produces no error and no NA race_ethnicity", {
  all_categories <- c(
    "total_female", "total_female_white_nh", "total_female_black",
    "total_female_aian", "total_female_asian", "total_female_hipi",
    "total_female_two_or_more", "total_female_hispanic"
  )
  full_labels <- stats::setNames(
    as.list(paste("Census label for", all_categories)),
    all_categories
  )

  access_tbl_complete <- .make_access_tbl(categories = all_categories)

  # Must not stop()
  result_tbl <- expect_no_error(
    .apply_race_label_guard(access_tbl_complete, full_labels)
  )

  # Every row must have a non-NA race_ethnicity
  expect_true(
    all(!is.na(result_tbl[["race_ethnicity"]])),
    info = "All rows must have a non-NA race_ethnicity when all keys are mapped"
  )

  # Row count must be preserved (no silent drops)
  expect_equal(
    nrow(result_tbl), nrow(access_tbl_complete),
    info = "Row count must be identical before and after label assignment"
  )
})

# =============================================================================
# BUG 10: Missing subspecialty guard in regression table
# =============================================================================

# --- Test 10.1: Unit test --------------------------------------------------
test_that("Bug 10 unit: single missing subspecialty raises RETRACTION GUARD stop()", {
  # access_data has only 6 of 7 subspecialties — MIGS is absent
  six_subspecialty_tbl <- tibble::tibble(
    subspecialty = rep(c("FPMRS", "GO", "MFM", "REI", "CFP", "PAG"), each = 10L),
    percent      = stats::runif(60L),
    year         = 2020L,
    category     = "total_female",
    range        = 3600L
  )

  expect_error(
    .apply_subspecialty_guard(six_subspecialty_tbl),
    regexp = "RETRACTION GUARD.*Bug 10",
    info   = "Missing subspecialty 'MIGS' must cause stop(), not warning()"
  )
})

# --- Test 10.2: Property-based test ----------------------------------------
test_that("Bug 10 property: guard fires for every combination of missing subspecialties", {
  all_seven <- c("FPMRS", "GO", "MFM", "REI", "CFP", "MIGS", "PAG")
  set.seed(7L)
  for (trial_index in seq_len(20L)) {
    n_missing   <- sample(1L:6L, size = 1L)
    missing_set <- sample(all_seven, size = n_missing)
    present_set <- setdiff(all_seven, missing_set)

    access_tbl_partial <- tibble::tibble(
      subspecialty = present_set,
      percent      = stats::runif(length(present_set))
    )

    expect_error(
      .apply_subspecialty_guard(access_tbl_partial),
      regexp = "RETRACTION GUARD.*Bug 10",
      info   = sprintf(
        "Trial %d: missing '%s' must trigger guard",
        trial_index, paste(missing_set, collapse = ", ")
      )
    )
  }
})

# --- Test 10.3: Integration test -------------------------------------------
test_that("Bug 10 integration: all 7 subspecialties present passes guard without error", {
  complete_subspecialty_tbl <- tibble::tibble(
    subspecialty = rep(c("FPMRS", "GO", "MFM", "REI", "CFP", "MIGS", "PAG"), each = 20L),
    percent      = stats::runif(140L),
    year         = rep(2013L:2022L, times = 14L),
    category     = rep(c("total_female", "total_female_white_nh"), times = 70L),
    range        = 3600L
  )

  # Must not stop() — guard passes silently
  expect_no_error(
    .apply_subspecialty_guard(complete_subspecialty_tbl),
    message = "All 7 subspecialties present must pass guard"
  )

  # Returned value is the original data frame (invisible pass-through)
  returned <- .apply_subspecialty_guard(complete_subspecialty_tbl)
  expect_equal(nrow(returned), nrow(complete_subspecialty_tbl))
})

# =============================================================================
# BUG 12: Silent NA->0 in MOE propagation
# =============================================================================

# --- Test 12.1: Unit test --------------------------------------------------
test_that("Bug 12 unit: tract with overlap > 0 and NA MOE emits warning, not silent 0", {
  overlap_fractions <- c(0.8, 0.0, 0.5)
  population_moes   <- c(150, 200, NA_real_)  # third tract: overlap but NA MOE

  expect_warning(
    result_list <- .allocate_moe_with_bug12_guard(
      overlap_fraction = overlap_fractions,
      population_moe   = population_moes,
      step_label       = "unit_test"
    ),
    regexp = "Bug 12.*1 tract",
    info   = "One NA MOE with overlap must emit a warning about the substitution"
  )

  # The substituted value must be 0 (coalesced), not NA
  expect_equal(result_list[["moe_allocated"]][3L], 0,
               info = "NA MOE coalesced to 0 for overlapping tract")

  # Counter must reflect exactly 1 substitution
  expect_equal(result_list[["n_moe_na_substituted"]], 1L,
               info = "Substitution counter must equal 1")
})

# --- Test 12.2: Property-based test ----------------------------------------
test_that("Bug 12 property: n_moe_na_substituted always equals number of overlapping tracts with NA MOE", {
  set.seed(12L)
  for (trial_index in seq_len(30L)) {
    n_tracts   <- sample(10L:200L, size = 1L)
    overlaps   <- stats::runif(n_tracts)
    n_na_moes  <- sample(0L:n_tracts, size = 1L)
    na_indices <- sample(seq_len(n_tracts), size = n_na_moes)

    moes <- stats::runif(n_tracts, min = 50, max = 500)
    moes[na_indices] <- NA_real_

    # Count how many of the NA-MOE tracts have overlap > 0
    expected_substitutions <- sum(overlaps[na_indices] > 0, na.rm = TRUE)

    if (expected_substitutions > 0L) {
      suppressWarnings(
        result_list <- .allocate_moe_with_bug12_guard(overlaps, moes, "prop_test")
      )
    } else {
      result_list <- .allocate_moe_with_bug12_guard(overlaps, moes, "prop_test")
    }

    expect_equal(
      result_list[["n_moe_na_substituted"]],
      expected_substitutions,
      info = sprintf(
        "Trial %d: %d overlapping NA-MOE tracts, counter must match",
        trial_index, expected_substitutions
      )
    )

    # Invariant: no NA values in moe_allocated
    expect_true(
      all(!is.na(result_list[["moe_allocated"]])),
      info = sprintf("Trial %d: moe_allocated must have no NAs after coalesce", trial_index)
    )
  }
})

# --- Test 12.3: Integration test -------------------------------------------
test_that("Bug 12 integration: zero-overlap tracts with NA MOE produce no warning and 0 moe_allocated", {
  # Tracts that have NO overlap (fraction = 0) may have NA MOE — this is fine.
  # The warning should fire ONLY for tracts where overlap > 0 AND MOE is NA.
  overlap_fractions <- c(0.0, 0.0, 0.0)
  population_moes   <- c(NA_real_, NA_real_, NA_real_)

  # No warning expected: all NA MOEs are on zero-overlap tracts
  expect_no_warning(
    result_list <- .allocate_moe_with_bug12_guard(
      overlap_fraction = overlap_fractions,
      population_moe   = population_moes,
      step_label       = "integration_test"
    )
  )

  expect_equal(result_list[["n_moe_na_substituted"]], 0L)
  expect_equal(result_list[["moe_allocated"]], c(0, 0, 0))
})

# =============================================================================
# BUG 13: 0-row race group guard fires too late
# =============================================================================

# --- Test 13.1: Unit test --------------------------------------------------
test_that("Bug 13 unit: 0-row group raises RETRACTION GUARD BEFORE mean_population access", {
  empty_group_tbl <- tibble::tibble(
    race_ethnicity  = character(0),
    mean_population = numeric(0),
    mean_access     = numeric(0)
  )

  # The guard must stop before any numeric operation on the 0-row tibble.
  # If the guard fired AFTER mean_population access, the error message would
  # reference NaN/numeric(0) rather than the retraction guard message.
  expect_error(
    .apply_zero_row_guard(empty_group_tbl, "white_fem"),
    regexp = "RETRACTION GUARD.*Bug 13.*0 rows",
    info   = "0-row guard must fire before any $mean_population access"
  )
})

# --- Test 13.2: Property-based test ----------------------------------------
test_that("Bug 13 property: guard fires for every named race group when that group is empty", {
  group_names <- c("white_fem", "black_fem", "aian_fem", "asian_fem", "nhpi_fem")

  empty_group_tbl <- tibble::tibble(
    race_ethnicity  = character(0),
    mean_population = numeric(0),
    mean_access     = numeric(0)
  )

  for (grp_name in group_names) {
    expect_error(
      .apply_zero_row_guard(empty_group_tbl, grp_name),
      regexp = "RETRACTION GUARD.*Bug 13",
      info   = sprintf("Guard must fire for group '%s' with 0 rows", grp_name)
    )
  }
})

# --- Test 13.3: Integration test -------------------------------------------
test_that("Bug 13 integration: non-empty group with finite mean_population passes guard and returns data", {
  valid_group_tbl <- tibble::tibble(
    race_ethnicity  = c("White non-Hispanic", "White non-Hispanic"),
    mean_population = c(45000000, 46000000),
    mean_access     = c(0.82, 0.83)
  )

  # Must not stop(); guard passes and returns the tibble
  returned_tbl <- expect_no_error(
    .apply_zero_row_guard(valid_group_tbl, "white_fem")
  )

  expect_equal(nrow(returned_tbl), nrow(valid_group_tbl),
               info = "Guard must return original data unchanged when check passes")

  # Specifically: accessing mean_population[1] must now be safe
  expect_true(is.finite(returned_tbl[["mean_population"]][1L]),
              info = "mean_population[1] must be finite after guard passes")
})

# --- Test 13.4: Guard order invariant (regression for the original bug) ----
test_that("Bug 13 order: NaN is NEVER produced before guard fires on 0-row group", {
  # The original bug: mean(numeric(0)) was called before the 0-row check,
  # producing NaN silently. This test verifies the guard fires BEFORE any
  # numeric operation would produce NaN/Inf.

  empty_tbl <- tibble::tibble(
    race_ethnicity  = character(0),
    mean_population = numeric(0)
  )

  # Capture the error; assert it is the retraction guard (not an NaN/Inf warning)
  caught_error <- tryCatch(
    .apply_zero_row_guard(empty_tbl, "aian_fem"),
    error = function(e) e
  )

  expect_s3_class(caught_error, "error")
  expect_true(
    startsWith(conditionMessage(caught_error), "RETRACTION GUARD"),
    info = paste(
      "Error must be the retraction guard, not a NaN/Inf error. Got:",
      conditionMessage(caught_error)
    )
  )
})

# =============================================================================
# BUG 14: Percentage scale mismatch in audit log
# =============================================================================

# --- Test 14.1: Unit test --------------------------------------------------
test_that("Bug 14 unit: .format_percent_audit produces 0-100 scale output for realistic inputs", {
  # 800,000 of 1,000,000 = 80%
  formatted <- .format_percent_audit(part = 800000, total = 1000000)

  # Must show "80.0%", not "0.8%"
  expect_equal(formatted, "80.0%",
               info = "80% must display as '80.0%%', not '0.8%%' (scale mismatch bug)")

  # Verify it is NOT on 0-1 scale
  expect_false(
    formatted == "0.8%",
    info = "Value must NOT display as '0.8%%' — that would indicate 0-1 scale error"
  )
})

# --- Test 14.2: Property-based test ----------------------------------------
test_that("Bug 14 property: formatted percentage is always in range 0.0%-100.0% for any valid inputs", {
  set.seed(14L)

  for (trial_index in seq_len(50L)) {
    part  <- sample(0L:100000000L, size = 1L)
    total <- sample(part:max(part, 100000000L), size = 1L)  # total >= part

    formatted <- .format_percent_audit(part = part, total = total)

    # Parse the numeric value back out
    numeric_value <- as.numeric(sub("%$", "", formatted))

    expect_true(
      numeric_value >= 0 && numeric_value <= 100,
      info = sprintf(
        "Trial %d: part=%d, total=%d → '%s' (%.4f) must be in [0, 100]",
        trial_index, part, total, formatted, numeric_value
      )
    )

    # Key invariant: value must NOT be in (0, 1) for part/total > 1%
    # (that would indicate the 0-1 scale bug is present)
    if (part > 0L && total > 0L && (part / total) > 0.01) {
      expect_true(
        numeric_value > 1.0,
        info = sprintf(
          "Trial %d: %.0f%% should display as >1.0, not <1.0 (0-1 scale bug). Got '%s'",
          trial_index, (part / total) * 100, formatted
        )
      )
    }
  }
})

# --- Test 14.3: Integration test -------------------------------------------
test_that("Bug 14 integration: safe_percent() returns 0-100 scale and sprintf format is consistent", {
  # Verify safe_percent() is available and returns 0-100 scale
  safe_percent_fn <- tryCatch(
    {
      source(here::here("R", "safe_divide.R"), local = TRUE)
      get("safe_percent", envir = environment(), inherits = FALSE)
    },
    error = function(e) NULL
  )

  skip_if(is.null(safe_percent_fn), "safe_divide.R not loadable in this environment")

  # 40,000,000 / 50,000,000 = 80%
  pct_value <- safe_percent_fn(part = 40000000, total = 50000000)

  # safe_percent multiplies by 100 internally; result must be in 0-100 range
  expect_true(pct_value >= 0 && pct_value <= 100,
              info = sprintf("safe_percent() must return 0-100 scale, got %.4f", pct_value))

  expect_true(pct_value > 1,
              info = sprintf("safe_percent(40M, 50M) must return ~80, got %.4f (0-1 scale bug?)", pct_value))

  # sprintf("%.1f%%", pct_value) must produce "80.0%" not "0.8%"
  audit_string <- sprintf("%.1f%%", pct_value)
  numeric_from_string <- as.numeric(sub("%$", "", audit_string))
  expect_true(numeric_from_string > 1,
              info = sprintf("Formatted string '%s' must be >1%% (not 0-1 scale)", audit_string))
})
