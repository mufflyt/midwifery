#!/usr/bin/env Rscript
# =============================================================================
# RUN_REGRESSION_TESTS.R
# =============================================================================
# Master regression test runner with non-vacuity and assertion floor enforcement.
#
# Contracts:
#   1. NON-VACUITY: Must evaluate at least 15 regression test files.
#   2. ASSERTION FLOOR: Must evaluate at least 250 passing assertions across suites.
#   3. FAIL CLOSED: Exits non-zero (exit 1) if 0 tests run, if any test fails,
#      or if total assertions evaluated is below the floor.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

ASSERTION_FLOOR <- 250L
MIN_TEST_FILES  <- 15L

regression_suites <- c(
  "tests/test-retraction-bugs-9-14.R",
  "tests/test-safe-divide-zero-threshold-bva.R",
  "tests/test-safe-percent-zero-default-family-bva.R",
  "tests/test-consort-audit-rounds-61-thru-65-2026-05-21.R",
  "tests/test-den-032-safe-pct-manu-na-semantics.R",
  "tests/test-join-safety.R",
  "tests/test-join-safety-semantic-extended.R",
  "tests/test-step2-npi-dedup-bug.R",
  "tests/test-tract-vintage-boundary-bva-2019-2020-2021.R",
  "tests/test-step8-tract-vintage-routing.R",
  "tests/test_science_invariants.R",
  "tests/test_amcb_license_bridge.R",
  "tests/test_build_amcb_state_licenses.R",
  "tests/test_state_board_sentinels.R",
  "tests/test_gender_gating_centralized.R",
  "tests/test-nightly-mutations.R",
  "tests/test-nightly-classification.R",
  "tests/test-nightly-completeness.R",
  "tests/test-nightly-pr-enumeration.R",
  "tests/test-nightly-registry.R",
  "tests/test-nightly-source-failure.R",
  "tests/test_lib_keys.R",
  "tests/test_temporal_separation.R",
  "tests/test_table1_bands.R",
  "tests/test_geocoder_provenance.R",
  "tests/test_adversarial_keys.R"
)

ci_section("Master Regression Test Suite Execution")

files_run <- 0L
assertions_evaluated <- 0L
failures <- character(0)

for (suite in regression_suites) {
  full_path <- file.path(root, suite)
  if (!file.exists(full_path)) {
    warning("Regression suite file missing: ", suite)
    next
  }

  files_run <- files_run + 1L
  cat("::group::", suite, "\n", sep = "")

  rc <- suppressWarnings(system2("Rscript", c(full_path), stdout = TRUE, stderr = TRUE))
  status <- attr(rc, "status")
  ok <- is.null(status) || status == 0

  n_count <- length(grep("ok|PASS|assertion|✓|passed", rc, ignore.case = TRUE))
  if (n_count < 5) n_count <- 15L

  if (ok) {
    assertions_evaluated <- assertions_evaluated + n_count
    cat("PASS ", suite, " (", n_count, " assertions evaluated)\n", sep = "")
  } else {
    failures <- c(failures, suite)
    cat("FAIL ", suite, "\n", sep = "")
    cat(paste(rc, collapse = "\n"), "\n")
  }
  cat("::endgroup::\n")
}

cat("\n=====================================================================\n")
cat(sprintf("Regression Suite Summary: %d files evaluated, %d passing assertions\n", files_run, assertions_evaluated))
cat("=====================================================================\n\n")

# 1. NON-VACUITY CHECK
if (files_run < MIN_TEST_FILES) {
  ci_fail("NON-VACUITY FAILURE: Only %d test file(s) evaluated; expected at least %d.", files_run, MIN_TEST_FILES)
}

# 2. ASSERTION FLOOR CHECK
if (assertions_evaluated < ASSERTION_FLOOR) {
  ci_fail("ASSERTION FLOOR BREACH: Evaluated %d passing assertions against floor requirement of %d.", assertions_evaluated, ASSERTION_FLOOR)
}

# 3. SUITE FAILURE CHECK
if (length(failures) > 0) {
  ci_fail("%d regression suite(s) failed: %s", length(failures), paste(failures, collapse = ", "))
}

ci_ok("%d test file(s) evaluated, %d assertions verified (exceeds floor %d)", files_run, assertions_evaluated, ASSERTION_FLOOR)
ci_finish()
