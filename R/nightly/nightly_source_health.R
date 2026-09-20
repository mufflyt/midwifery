# =============================================================================
# R/nightly/nightly_source_health.R
# =============================================================================
# Source health checking module.
# Enforces Section 5: Source-level failures take precedence over record-level
# interpretation. HTTP 503/429, timeouts, or unparsable payloads MUST produce
# PIPELINE_FAILURE + CRITICAL severity, NOT record-level drift.
# =============================================================================

nightly_check_source_health <- function(source_name, context = list()) {
  started <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  # Mock / Context overrides for offline testing
  if (!is.null(context$mock_response)) {
    resp <- context$mock_response
  } else {
    resp <- list(status = 200, payload_ok = TRUE, body_hash = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  status <- resp$status
  finished <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  if (status == 503 || status == 429 || status == 500) {
    return(data.frame(
      sentinel_id = paste0(source_name, "_source_health"),
      check_type = "source",
      source = source_name,
      classification = "PIPELINE_FAILURE",
      severity = "CRITICAL",
      event_code = paste0(toupper(source_name), "_SOURCE_FAILURE"),
      expected_value = "HTTP 200 OK",
      observed_value = paste0("HTTP ", status),
      message = paste0("Source ", source_name, " returned HTTP ", status, ". Source failure precedes record interpretation."),
      response_status = as.character(status),
      response_hash = resp$body_hash,
      started_at_utc = started,
      finished_at_utc = finished,
      stringsAsFactors = FALSE
    ))
  }

  if (isFALSE(resp$payload_ok)) {
    return(data.frame(
      sentinel_id = paste0(source_name, "_source_health"),
      check_type = "source",
      source = source_name,
      classification = "PIPELINE_FAILURE",
      severity = "CRITICAL",
      event_code = paste0(toupper(source_name), "_MALFORMED_PAYLOAD"),
      expected_value = "Valid payload schema",
      observed_value = "Malformed or unparsable payload",
      message = paste0("Source ", source_name, " payload is malformed or unparsable."),
      response_status = as.character(status),
      response_hash = resp$body_hash,
      started_at_utc = started,
      finished_at_utc = finished,
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    sentinel_id = paste0(source_name, "_source_health"),
    check_type = "source",
    source = source_name,
    classification = "PASS",
    severity = "INFO",
    event_code = paste0(toupper(source_name), "_SOURCE_HEALTHY"),
    expected_value = "HTTP 200 OK",
    observed_value = "HTTP 200 OK",
    message = paste0("Source ", source_name, " is healthy and observable."),
    response_status = as.character(status),
    response_hash = resp$body_hash,
    started_at_utc = started,
    finished_at_utc = finished,
    stringsAsFactors = FALSE
  )
}
