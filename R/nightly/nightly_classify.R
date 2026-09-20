# =============================================================================
# R/nightly/nightly_classify.R
# =============================================================================
# Classification aggregation and summary builder module.
# Enforces Sections 3, 4, and 25:
#   if any PIPELINE_FAILURE: PIPELINE_FAILURE (workflow_should_fail = TRUE)
#   else if any WORLD_DRIFT: WORLD_DRIFT (workflow_should_fail = FALSE)
#   else: PASS (workflow_should_fail = FALSE)
# =============================================================================

nightly_classify <- function(observation) {
  events <- observation
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

  # Check for unknown classifications
  valid_classes <- c("PASS", "WORLD_DRIFT", "PIPELINE_FAILURE")
  if (any(!events$classification %in% valid_classes)) {
    return(list(
      overall_classification = "PIPELINE_FAILURE",
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

  list(
    overall_classification = overall,
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

nightly_build_summary <- function(events, context = list()) {
  started_utc <- if (!is.null(context$started_at_utc)) context$started_at_utc else format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  finished_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  run_id <- if (!is.null(context$run_id)) context$run_id else Sys.getenv("GITHUB_RUN_ID", "local-dev-run")
  repo_sha <- if (!is.null(context$repository_sha)) context$repository_sha else tryCatch(trimws(system("git rev-parse HEAD", intern = TRUE)), error = function(e) "0000000000000000000000000000000000000000")

  res <- nightly_classify(events)

  sources_checked <- length(unique(events$source))
  sources_failed <- length(unique(events$source[events$classification == "PIPELINE_FAILURE"]))
  comp_eval <- sum(events$check_type == "completeness", na.rm = TRUE)
  comp_pass <- sum(events$check_type == "completeness" & events$classification == "PASS", na.rm = TRUE)
  comp_fail <- sum(events$check_type == "completeness" & events$classification == "PIPELINE_FAILURE", na.rm = TRUE)

  list(
    run_id = as.character(run_id),
    repository_sha = repo_sha,
    started_at_utc = started_utc,
    finished_at_utc = finished_utc,
    classification = res$overall_classification,
    workflow_should_fail = res$workflow_should_fail,
    counts = res$counts,
    severity_counts = res$severity_counts,
    sources_checked = as.integer(sources_checked),
    sources_failed = as.integer(sources_failed),
    completeness_assertions = list(
      evaluated = as.integer(comp_eval),
      passed = as.integer(comp_pass),
      failed = as.integer(comp_fail)
    )
  )
}
