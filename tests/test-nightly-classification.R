# =============================================================================
# tests/test-nightly-classification.R
# =============================================================================
# Unit tests for classification rules and severity aggregation.
# Section 3, 4, 25:
#   - PASS -> workflow_should_fail = FALSE
#   - WORLD_DRIFT -> workflow_should_fail = FALSE (World drift alone is non-red)
#   - PIPELINE_FAILURE + ERROR/CRITICAL -> workflow_should_fail = TRUE
# =============================================================================

source("R/nightly/nightly_classify.R")

# Case 1: All PASS
pass_events <- data.frame(
  classification = c("PASS", "PASS"),
  severity = c("INFO", "INFO"),
  stringsAsFactors = FALSE
)
res_pass <- nightly_classify(pass_events)
if (res_pass$overall_classification != "PASS" || isTRUE(res_pass$workflow_should_fail)) {
  stop("test-nightly-classification.R failed on PASS case")
}

# Case 2: WORLD_DRIFT
drift_events <- data.frame(
  classification = c("PASS", "WORLD_DRIFT"),
  severity = c("INFO", "WARNING"),
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
  stringsAsFactors = FALSE
)
res_pfail <- nightly_classify(pfail_events)
if (res_pfail$overall_classification != "PIPELINE_FAILURE" || !isTRUE(res_pfail$workflow_should_fail)) {
  stop("test-nightly-classification.R failed: PIPELINE_FAILURE must fail the workflow")
}

cat("PASS test-nightly-classification.R: Classification aggregation rules verified\n")
