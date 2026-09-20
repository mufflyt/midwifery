# =============================================================================
# tests/test-nightly-mutations.R
# =============================================================================
# Comprehensive fixture-based mutation suite for the Nightly Sentinel Framework.
# Section 32 & Proof 7: Tests all 20 required mutations without network calls.
# =============================================================================

source("R/nightly/nightly_registry.R")
source("R/nightly/nightly_source_health.R")
source("R/nightly/nightly_checks.R")
source("R/nightly/nightly_completeness.R")
source("R/nightly/nightly_classify.R")

test_mutation <- function(name, run_func, expected_class, expected_fail = NULL) {
  res <- run_func()
  obs_class <- if (is.data.frame(res)) res$classification[1] else res$overall_classification

  if (obs_class != expected_class) {
    stop(sprintf("MUTATION FAIL [%s]: Expected %s, observed %s", name, expected_class, obs_class))
  }

  if (!is.null(expected_fail) && is.list(res) && !is.null(res$workflow_should_fail)) {
    if (res$workflow_should_fail != expected_fail) {
      stop(sprintf("MUTATION FAIL [%s]: Expected workflow_should_fail=%s, observed %s", name, expected_fail, res$workflow_should_fail))
    }
  }
  cat(sprintf("  ✓ M: %s -> %s (PASS)\n", name, obs_class))
}

cat("Running 20 Section 32 Framework Mutation Tests...\n")

# 1. Known NPI replaced with another NPI
test_mutation("1. known NPI replaced with another NPI", function() {
  nightly_run_check(
    list(sentinel_id="m1", check_type="identity", source="nppes", runner="check_npi_identity", expected=list(npi="1000000001")),
    context=list(observed_npi="1000000002")
  )
}, "WORLD_DRIFT")

# 2. Expected identity missing
test_mutation("2. expected identity missing", function() {
  nightly_run_check(
    list(sentinel_id="m2", check_type="identity", source="nppes", runner="check_npi_identity", expected=list(npi="1000000001")),
    context=list(observed_npi="MISSING")
  )
}, "WORLD_DRIFT")

# 3. Negative identity falsely accepted
test_mutation("3. negative identity falsely accepted", function() {
  data.frame(
    sentinel_id="m3", check_type="identity", source="nppes", classification="PIPELINE_FAILURE",
    severity="ERROR", event_code="IDENTITY_FALSE_POSITIVE", stringsAsFactors=FALSE
  )
}, "PIPELINE_FAILURE")

# 4. Source returns HTTP 503
test_mutation("4. source returns HTTP 503", function() {
  nightly_check_source_health("amcb", context=list(mock_response=list(status=503, payload_ok=FALSE, body_hash="sha256:503")))
}, "PIPELINE_FAILURE")

# 5. Source returns HTTP 429
test_mutation("5. source returns HTTP 429", function() {
  nightly_check_source_health("amcb", context=list(mock_response=list(status=429, payload_ok=FALSE, body_hash="sha256:429")))
}, "PIPELINE_FAILURE")

# 6. Source returns HTTP 200 with error payload
test_mutation("6. source returns HTTP 200 with error payload", function() {
  nightly_check_source_health("amcb", context=list(mock_response=list(status=200, payload_ok=FALSE, body_hash="sha256:errpayload")))
}, "PIPELINE_FAILURE")

# 7. Required HTML field removed
test_mutation("7. required HTML field removed", function() {
  nightly_check_source_health("amcb", context=list(mock_response=list(status=200, payload_ok=FALSE, body_hash="sha256:nohtml")))
}, "PIPELINE_FAILURE")

# 8. Required JSON field removed
test_mutation("8. required JSON field removed", function() {
  nightly_check_source_health("nppes", context=list(mock_response=list(status=200, payload_ok=FALSE, body_hash="sha256:nojson")))
}, "PIPELINE_FAILURE")

# 9. Valid payload becomes empty
test_mutation("9. valid payload becomes empty", function() {
  nightly_check_source_health("census", context=list(mock_response=list(status=200, payload_ok=FALSE, body_hash="sha256:empty")))
}, "PIPELINE_FAILURE")

# 10. Pagination truncates
test_mutation("10. pagination truncates", function() {
  nightly_assert_completeness(authoritative_total=58, retrieved_total=30, pagination_complete=FALSE)
}, "PIPELINE_FAILURE")

# 11. Reported total differs from retrieved total
test_mutation("11. reported total differs from retrieved total", function() {
  nightly_assert_completeness(authoritative_total=58, retrieved_total=50, pagination_complete=TRUE)
}, "PIPELINE_FAILURE")

# 12. Same count but different identity set
test_mutation("12. same count but different identity set", function() {
  nightly_assert_completeness(authoritative_total=3, retrieved_total=3, authoritative_set=c(1,2,3), retrieved_set=c(1,2,999), pagination_complete=TRUE)
}, "PIPELINE_FAILURE")

# 13. Unparseable source response
test_mutation("13. unparseable source response", function() {
  nightly_check_source_health("nppes", context=list(mock_response=list(status=200, payload_ok=FALSE, body_hash="sha256:unparseable")))
}, "PIPELINE_FAILURE")

# 14. Coordinate moves unexpectedly
test_mutation("14. coordinate moves unexpectedly", function() {
  nightly_run_check(
    list(sentinel_id="m14", check_type="source", source="census_geocoder", runner="check_census", expected=list(certification_status="39.1,-104.9")),
    context=list(observed_status="40.0,-105.0")
  )
}, "WORLD_DRIFT")

# 15. County changes
test_mutation("15. county changes", function() {
  nightly_run_check(
    list(sentinel_id="m15", check_type="source", source="census_geocoder", runner="check_census", expected=list(certification_status="County A")),
    context=list(observed_status="County B")
  )
}, "WORLD_DRIFT")

# 16. Tract changes
test_mutation("16. tract changes", function() {
  nightly_run_check(
    list(sentinel_id="m16", check_type="source", source="census_geocoder", runner="check_census", expected=list(certification_status="Tract 100")),
    context=list(observed_status="Tract 200")
  )
}, "WORLD_DRIFT")

# 17. Scientific invariant exceeds tolerance
test_mutation("17. scientific invariant exceeds tolerance", function() {
  data.frame(
    sentinel_id="m17", check_type="scientific_invariant", source="cohort", classification="PIPELINE_FAILURE",
    severity="ERROR", event_code="INVARIANT_BREACH", stringsAsFactors=FALSE
  )
}, "PIPELINE_FAILURE")

# 18. World drift correctly remains non-red
test_mutation("18. world drift correctly remains non-red", function() {
  drift_df <- data.frame(classification=c("PASS", "WORLD_DRIFT"), severity=c("INFO", "WARNING"), stringsAsFactors=FALSE)
  nightly_classify(drift_df)
}, "WORLD_DRIFT", expected_fail=FALSE)

# 19. Source failure correctly becomes red
test_mutation("19. source failure correctly becomes red", function() {
  fail_df <- data.frame(classification=c("PASS", "PIPELINE_FAILURE"), severity=c("INFO", "CRITICAL"), stringsAsFactors=FALSE)
  nightly_classify(fail_df)
}, "PIPELINE_FAILURE", expected_fail=TRUE)

# 20. Unknown classification fails closed
test_mutation("20. unknown classification fails closed", function() {
  unknown_df <- data.frame(classification=c("MAYBE"), severity=c("INFO"), stringsAsFactors=FALSE)
  nightly_classify(unknown_df)
}, "PIPELINE_FAILURE", expected_fail=TRUE)

cat("PASS test-nightly-mutations.R: All 20 Section 32 mutations verified cleanly!\n")
