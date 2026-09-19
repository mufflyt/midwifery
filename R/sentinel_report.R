#' @title Sentinel Report Generator
#'
#' @description
#' Formats machine-readable (sentinel_summary.json, sentinel_events.csv) and
#' human-readable markdown summaries for the midwifery external-world sentinel CI.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
})
source(file.path("R", "lib", "sentinel_engine.R"))

#' Write all sentinel run artifacts to output directory
#'
#' @param events_df Data frame of event rows
#' @param output_dir Target directory for artifacts
#' @return List of generated file paths
write_sentinel_reports <- function(events_df, output_dir = "artifacts/sentinel") {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  summary_info <- summarize_sentinel_run(events_df)
  summary_info$run_utc <- format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC", tz = "UTC")

  # 1. Write sentinel_summary.json
  json_path <- file.path(output_dir, "sentinel_summary.json")
  writeLines(jsonlite::toJSON(summary_info, auto_unbox = TRUE, pretty = TRUE), json_path)

  # 2. Write sentinel_events.csv
  events_path <- file.path(output_dir, "sentinel_events.csv")
  write_csv(events_df, events_path)

  # 3. Write sentinel_report.md
  md_path <- file.path(output_dir, "sentinel_report.md")
  md_lines <- c(
    "# Midwifery External-World Sentinel Report",
    "",
    sprintf("**Run UTC**: %s", summary_info$run_utc),
    sprintf("**Overall Status**: `%s`", summary_info$overall_status),
    "",
    "## Summary Metrics",
    "",
    sprintf("- **Total Sentinels Evaluated**: %d", summary_info$total_sentinels),
    sprintf("- **PASS**: %d", summary_info$pass_count),
    sprintf("- **WORLD_DRIFT**: %d", summary_info$world_drift_count),
    sprintf("- **PIPELINE_FAILURE**: %d", summary_info$pipeline_failure_count),
    sprintf("- **SOURCE_FAILURE**: %d", summary_info$source_failure_count),
    "",
    "## Event Ledger",
    "",
    "| Sentinel ID | Subsystem | Event Type | Expected | Observed | Verdict | Severity |",
    "|---|---|---|---|---|---|---|"
  )

  if (nrow(events_df) > 0) {
    for (i in seq_len(nrow(events_df))) {
      r <- events_df[i, ]
      md_lines <- c(md_lines, sprintf("| `%s` | %s | `%s` | %s | %s | **%s** | %s |",
                                      r$sentinel_id, r$subsystem, r$event_type,
                                      r$expected, r$observed, r$classification, r$severity))
    }
  } else {
    md_lines <- c(md_lines, "| - | - | - | - | - | PASS | INFO |")
  }

  writeLines(md_lines, md_path)

  list(
    json   = json_path,
    csv    = events_path,
    md     = md_path,
    status = summary_info$overall_status
  )
}
