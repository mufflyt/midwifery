# =============================================================================
# R/nightly/nightly_classify.R
# =============================================================================
# Classification aggregation and summary builder module.
# Enforces Sections 3, 4, and 25:
#   if any PIPELINE_FAILURE: PIPELINE_FAILURE (workflow_should_fail = TRUE)
#   else if any WORLD_DRIFT: WORLD_DRIFT (workflow_should_fail = FALSE)
#   else: PASS (workflow_should_fail = FALSE)
#
# End-to-End Status Distinction:
#   FULL_END_TO_END_PASS: All repo checks pass AND live Valhalla routing canary is ONLINE.
#   COMPREHENSIVE_OFFLINE_PASS: All repo checks pass BUT Valhalla routing canary is OFFLINE.
#   PIPELINE_FAILURE: Software defect or assertion failure.
# =============================================================================

nightly_classify <- function(observation) {
  events <- observation
  if (is.null(events) || nrow(events) == 0) {
    return(list(
      overall_classification = "PASS",
      e2e_classification = "COMPREHENSIVE_OFFLINE_PASS",
      workflow_should_fail = FALSE,
      counts = list(total = 0, pass = 0, world_drift = 0, pipeline_failure = 0),
      severity_counts = list(info = 0, warning = 0, error = 0, critical = 0)
    ))
  }

  n_total <- nrow(events)
  n_pass <- sum(events$classification == "PASS", na.rm = TRUE)
  n_drift <- sum(events$classification == "WORLD_DRIFT", na.rm = TRUE)
  n_pfail <- sum(events$classification == "PIPELINE_FAILURE", na.rm = TRUE)

  n_info <- sum(events$severity == "INFO", na.rm = TRUE)
  n_warn <- sum(events$severity == "WARNING", na.rm = TRUE)
  n_err <- sum(events$severity == "ERROR", na.rm = TRUE)
  n_crit <- sum(events$severity == "CRITICAL", na.rm = TRUE)

  # Check for unknown classifications
  valid_classes <- c("PASS", "WORLD_DRIFT", "PIPELINE_FAILURE")
  if (any(!events$classification %in% valid_classes)) {
    return(list(
      overall_classification = "PIPELINE_FAILURE",
      e2e_classification = "PIPELINE_FAILURE",
      workflow_should_fail = TRUE,
      counts = list(total = n_total, pass = n_pass, world_drift = n_drift, pipeline_failure = n_total),
      severity_counts = list(info = 0, warning = 0, error = 0, critical = n_total)
    ))
  }

  if (n_pfail > 0) {
    overall <- "PIPELINE_FAILURE"
    # Fails workflow if any ERROR or CRITICAL pipeline failure exists
    should_fail <- (n_err + n_crit) > 0
  } else if (n_drift > 0) {
    overall <- "WORLD_DRIFT"
    should_fail <- FALSE # World drift alone MUST remain non-failing
  } else {
    overall <- "PASS"
    should_fail <- FALSE
  }

  valhalla_online <- any(events$event_code == "VALHALLA_ROUTING_ONLINE_VERIFIED", na.rm = TRUE)
  if (n_pfail > 0) {
    e2e_status <- "PIPELINE_FAILURE"
  } else if (valhalla_online) {
    e2e_status <- "FULL_END_TO_END_PASS"
  } else {
    e2e_status <- "COMPREHENSIVE_OFFLINE_PASS"
  }

  list(
    overall_classification = overall,
    e2e_classification = e2e_status,
    workflow_should_fail = should_fail,
    counts = list(
      total = as.integer(n_total),
      pass = as.integer(n_pass),
      world_drift = as.integer(n_drift),
      pipeline_failure = as.integer(n_pfail)
    ),
    severity_counts = list(
      info = as.integer(n_info),
      warning = as.integer(n_warn),
      error = as.integer(n_err),
      critical = as.integer(n_crit)
    )
  )
}

