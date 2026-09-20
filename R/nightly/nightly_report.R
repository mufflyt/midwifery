# =============================================================================
# R/nightly/nightly_report.R
# =============================================================================
# Output artifact package and Markdown report generator module.
# Section 24, 25, 26, 35: Writes run_manifest.json, sentinel_summary.json,
# sentinel_events.csv, sentinel_events.jsonl, and nightly_report.md.
# =============================================================================

nightly_write_artifacts <- function(events,
                                   summary,
                                   manifest = NULL,
                                   output_dir = "artifacts/nightly") {

  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }

  started_utc <- if (!is.null(manifest$started_at_utc)) manifest$started_at_utc else format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  finished_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  run_id <- if (!is.null(manifest$run_id)) manifest$run_id else Sys.getenv("GITHUB_RUN_ID", "local-dev-run")
  repo_sha <- if (!is.null(manifest$repository_sha)) manifest$repository_sha else tryCatch(trimws(system("git rev-parse HEAD", intern = TRUE)), error = function(e) "0000000000000000000000000000000000000000")

  # 1. Write run_manifest.json
  manifest_obj <- list(
    run_id = as.character(run_id),
    run_attempt = as.integer(Sys.getenv("GITHUB_RUN_ATTEMPT", "1")),
    repository = Sys.getenv("GITHUB_REPOSITORY", "mufflyt/midwifery"),
    repository_sha = repo_sha,
    repository_ref = Sys.getenv("GITHUB_REF", "refs/heads/main"),
    framework_version = "v1.0.0",
    registry_version = "1.0.0",
    event_trigger = Sys.getenv("GITHUB_EVENT_NAME", "workflow_dispatch"),
    scheduled_for_utc = started_utc,
    started_at_utc = started_utc,
    finished_at_utc = finished_utc,
    runner_os = Sys.getenv("RUNNER_OS", R.version$os),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    random_seed = 20260920,
    read_only = TRUE
  )
  write(jsonlite::toJSON(manifest_obj, auto_unbox = TRUE, pretty = TRUE), file.path(output_dir, "run_manifest.json"))

  # 2. Write sentinel_summary.json
  sources_checked <- length(unique(events$source))
  sources_failed <- length(unique(events$source[events$classification == "PIPELINE_FAILURE"]))
  comp_eval <- sum(events$check_type == "completeness", na.rm = TRUE)
  comp_pass <- sum(events$check_type == "completeness" & events$classification == "PASS", na.rm = TRUE)
  comp_fail <- sum(events$check_type == "completeness" & events$classification == "PIPELINE_FAILURE", na.rm = TRUE)

  summary_obj <- list(
    run_id = as.character(run_id),
    repository_sha = repo_sha,
    started_at_utc = started_utc,
    finished_at_utc = finished_utc,
    classification = summary$overall_classification,
    workflow_should_fail = summary$workflow_should_fail,
    counts = summary$counts,
    severity_counts = summary$severity_counts,
    sources_checked = as.integer(sources_checked),
    sources_failed = as.integer(sources_failed),
    completeness_assertions = list(
      evaluated = as.integer(comp_eval),
      passed = as.integer(comp_pass),
      failed = as.integer(comp_fail)
    )
  )
  write(jsonlite::toJSON(summary_obj, auto_unbox = TRUE, pretty = TRUE), file.path(output_dir, "sentinel_summary.json"))

  # 3. Write sentinel_events.csv
  write.csv(events, file.path(output_dir, "sentinel_events.csv"), row.names = FALSE)

  # 4. Write sentinel_events.jsonl
  jsonl_lines <- unlist(lapply(1:nrow(events), function(i) {
    jsonlite::toJSON(as.list(events[i, ]), auto_unbox = TRUE)
  }))
  writeLines(jsonl_lines, file.path(output_dir, "sentinel_events.jsonl"))

  # 5. Write Executive Markdown Report (nightly_report.md)
  report_lines <- c(
    "# Nightly Sentinel Report",
    "",
    paste0("**Repository SHA**: `", repo_sha, "`"),
    paste0("**Run ID**: `", run_id, "`"),
    paste0("**Started**: `", started_utc, "`"),
    paste0("**Finished**: `", finished_utc, "`"),
    "",
    paste0("## Overall Classification: **", summary$overall_classification, "**"),
    "",
    paste0("- **Total checks evaluated**: ", summary$counts$total),
    paste0("- **PASS**: ", summary$counts$pass),
    paste0("- **WORLD_DRIFT**: ", summary$counts$world_drift),
    paste0("- **PIPELINE_FAILURE**: ", summary$counts$pipeline_failure),
    "",
    "### Severity Breakdown",
    paste0("- **INFO**: ", summary$severity_counts$info),
    paste0("- **WARNING**: ", summary$severity_counts$warning),
    paste0("- **ERROR**: ", summary$severity_counts$error),
    paste0("- **CRITICAL**: ", summary$severity_counts$critical),
    "",
    "---",
    "",
    "## Completeness Assertions",
    paste0("Evaluated: ", comp_eval, " | Passed: ", comp_pass, " | Failed: ", comp_fail),
    if (comp_fail > 0) "⚠️ Completeness assertion failures detected." else "✓ All completeness assertions passed.",
    "",
    "## Source Health Status",
    paste0("Sources Checked: ", sources_checked, " | Sources Failed: ", sources_failed),
    if (sources_failed > 0) "⚠️ Source-level failures detected." else "✓ All sources healthy and observable.",
    "",
    "## Execution Provenance",
    paste0("- **Framework Version**: `v1.0.0`"),
    paste0("- **Registry Version**: `1.0.0`"),
    paste0("- **R Version**: `", R.version.string, "`"),
    paste0("- **Runner OS**: `", R.version$os, "`"),
    paste0("- **Read-Only Mode**: `TRUE`"),
    ""
  )

  writeLines(report_lines, file.path(output_dir, "nightly_report.md"))

  message("Written nightly sentinel artifacts to: ", output_dir)
  summary_obj
}
