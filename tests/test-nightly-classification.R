# =============================================================================
# tests/test-nightly-classification.R
# =============================================================================
# Unit tests for classification rules and severity aggregation.
# Section 3, 4, 25:
#   - PASS -> workflow_should_fail = FALSE
#   - WORLD_DRIFT -> workflow_should_fail = FALSE (World drift alone is non-red)
#   - PIPELINE_FAILURE + ERROR/CRITICAL -> workflow_should_fail = TRUE
#   - E2E distinction: FULL_END_TO_END_PASS vs COMPREHENSIVE_OFFLINE_PASS
# =============================================================================

source("R/nightly/nightly_classify.R")

# Case 1: All PASS (Offline Valhalla -> COMPREHENSIVE_OFFLINE_PASS)
pass_events <- data.frame(
  classification = c("PASS", "PASS"),
  severity = c("INFO", "INFO"),
  event_code = c("EXPECTED_IDENTITY_CONFIRMED", "CHECK_PASSED"),
  stringsAsFactors = FALSE
)
res_pass <- nightly_classify(pass_events)
if (res_pass$overall_classification != "PASS" || isTRUE(res_pass$workflow_should_fail)) {
  stop("test-nightly-classification.R failed on PASS case")
}
if (res_pass$e2e_classification != "COMPREHENSIVE_OFFLINE_PASS") {
  stop("test-nightly-classification.R failed: expected COMPREHENSIVE_OFFLINE_PASS when Valhalla routing canary is offline")
}

# Case 1b: All PASS (Online Valhalla -> FULL_END_TO_END_PASS)
pass_valhalla_events <- data.frame(
  classification = c("PASS", "PASS"),
  severity = c("INFO", "INFO"),
  event_code = c("EXPECTED_IDENTITY_CONFIRMED", "VALHALLA_ROUTING_ONLINE_VERIFIED"),
  stringsAsFactors = FALSE
)
res_pass_v <- nightly_classify(pass_valhalla_events)
if (res_pass_v$e2e_classification != "FULL_END_TO_END_PASS") {
  stop("test-nightly-classification.R failed: expected FULL_END_TO_END_PASS when Valhalla routing canary is online")
}

# Case 2: WORLD_DRIFT
drift_events <- data.frame(
  classification = c("PASS", "WORLD_DRIFT"),
  severity = c("INFO", "WARNING"),
  event_code = c("CHECK_PASSED", "WORLD_SOURCE_DRIFT"),
  stringsAsFactors = FALSE
)
res_drift <- nightly_classify(drift_events)
if (res_drift$overall_classification != "WORLD_DRIFT" || isTRUE(res_drift$workflow_should_fail)) {
  stop("test-nightly-classification.R failed: WORLD_DRIFT must NOT fail the workflow")
}

# Case 3: PIPELINE_FAILURE
pfail_events <- data.frame(
  classification = c("PASS", "PIPELINE_FAILURE"),
  severity = c("INFO", "ERROR"),
  event_code = c("CHECK_PASSED", "SOURCE_FAILURE_503"),
  stringsAsFactors = FALSE
)
res_pfail <- nightly_classify(pfail_events)
if (res_pfail$overall_classification != "PIPELINE_FAILURE" || !isTRUE(res_pfail$workflow_should_fail)) {
  stop("test-nightly-classification.R failed: PIPELINE_FAILURE must fail the workflow")
}
if (res_pfail$e2e_classification != "PIPELINE_FAILURE") {
  stop("test-nightly-classification.R failed: expected PIPELINE_FAILURE for E2E status")
}

cat("PASS test-nightly-classification.R: Classification aggregation & E2E rules verified\n")
