# =============================================================================
# tests/testthat/test-canary-must-fail.R
# =============================================================================
# Armed CI Canary Test.
# Verifies that planted defects and broken exit paths actually fail the runner job
# instead of reporting false-green.
#
# Armed when environment variable CI_CANARY_ENABLED=1 is set.
# =============================================================================

test_that("CI Canary armed failure check", {
  is_armed <- identical(Sys.getenv("CI_CANARY_ENABLED"), "1")
  
  if (is_armed) {
    stop("CI CANARY ARMED: Planted canary failure triggered to verify CI fails closed.")
  } else {
    expect_true(TRUE)
  }
})
