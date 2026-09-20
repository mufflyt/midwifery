# =============================================================================
# R/nightly/nightly_classify.R
# =============================================================================
# Classification aggregation and severity policy module.
# Enforces Sections 3, 4, and 25:
#   if any PIPELINE_FAILURE: PIPELINE_FAILURE (workflow_should_fail = TRUE)
#   else if any WORLD_DRIFT: WORLD_DRIFT (workflow_should_fail = FALSE)
#   else: PASS (workflow_should_fail = FALSE)
# =============================================================================

nightly_classify <- function(events) {
  if (is.null(events) || nrow(events) == 0) {
    return(list(
      overall_classification = "PASS",
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

  list(
    overall_classification = overall,
    workflow_should_fail = should_fail,
    counts = list(
      total = n_total,
      pass = n_pass,
      world_drift = n_drift,
      pipeline_failure = n_pfail
    ),
    severity_counts = list(
      info = n_info,
      warning = n_warn,
      error = n_err,
      critical = n_crit
    )
  )
}
