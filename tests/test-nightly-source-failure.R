# =============================================================================
# tests/test-nightly-source-failure.R
# =============================================================================
# Unit tests enforcing Section 5:
# Source-level failure takes precedence over record-level interpretation.
# HTTP 503/429 or unparsable payload MUST produce PIPELINE_FAILURE + CRITICAL,
# NOT individual record drift.
# =============================================================================

source("R/nightly/nightly_source_health.R")

# Case 1: HTTP 503 -> CRITICAL PIPELINE_FAILURE
res_503 <- nightly_check_source_health(
  source_name = "amcb",
  context = list(mock_response = list(status = 503, payload_ok = FALSE, body_hash = "sha256:503err"))
)
if (res_503$classification != "PIPELINE_FAILURE" || res_503$severity != "CRITICAL" || res_503$event_code != "AMCB_SOURCE_FAILURE") {
  stop("test-nightly-source-failure.R failed on HTTP 503 case")
}

# Case 2: Malformed payload -> CRITICAL PIPELINE_FAILURE
res_malformed <- nightly_check_source_health(
  source_name = "amcb",
  context = list(mock_response = list(status = 200, payload_ok = FALSE, body_hash = "sha256:badpayload"))
)
if (res_malformed$classification != "PIPELINE_FAILURE" || res_malformed$severity != "CRITICAL" || res_malformed$event_code != "AMCB_MALFORMED_PAYLOAD") {
  stop("test-nightly-source-failure.R failed on malformed payload case")
}

# Case 3: HTTP 200 OK -> PASS
res_200 <- nightly_check_source_health(
  source_name = "amcb",
  context = list(mock_response = list(status = 200, payload_ok = TRUE, body_hash = "sha256:1a2b3c"))
)
if (res_200$classification != "PASS" || res_200$severity != "INFO") {
  stop("test-nightly-source-failure.R failed on HTTP 200 OK case")
}

cat("PASS test-nightly-source-failure.R: Source failure precedence verified\n")
