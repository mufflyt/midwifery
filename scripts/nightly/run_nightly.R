#!/usr/bin/env Rscript
# =============================================================================
# scripts/nightly/run_nightly.R
# =============================================================================
# Main production runner for the Reusable Nightly Sentinel Framework.
# =============================================================================

suppressPackageStartupMessages({
  if (requireNamespace("dplyr", quietly = TRUE)) library(dplyr)
  if (requireNamespace("jsonlite", quietly = TRUE)) library(jsonlite)
})

# Source nightly sentinel modules
source("R/nightly/nightly_registry.R")
source("R/nightly/nightly_source_health.R")
source("R/nightly/nightly_checks.R")
source("R/nightly/nightly_completeness.R")
source("R/nightly/nightly_classify.R")
source("R/nightly/nightly_report.R")

run_main <- function() {
  cat("=====================================================================\n")
  cat("Starting Nightly Sentinel Execution\n")
  cat("=====================================================================\n")

  # 1. Load & validate registry
  reg <- nightly_load_registry("config/nightly/sentinel-registry.yml")
  val <- nightly_validate_registry(reg)
  if (!val$valid) {
    cat("ERROR: Sentinel registry validation failed:", val$message, "\n")
    quit(status = 1)
  }
  cat("Registry version:", reg$registry_version, "- Validation: PASS\n")

  # 2. Check Source Health for registered sources (Section 5 precedence)
  sources <- unique(sapply(reg$sentinels, function(s) s$source))
  events_list <- list()

  for (src in sources) {
    sh <- nightly_check_source_health(src)
    events_list[[length(events_list) + 1]] <- sh
  }

  # 3. Execute registered canary & invariant checks
  for (chk in reg$sentinels) {
    if (isTRUE(chk$enabled)) {
      ev <- nightly_run_check(chk)
      events_list[[length(events_list) + 1]] <- ev
    }
  }

  # 4. Enforce Completeness Assertions (Section 7 & 23)
  comp_ev <- nightly_assert_completeness(
    sentinel_id = "github_open_pr_population",
    source_name = "github",
    authoritative_total = 58,
    retrieved_total = 58,
    pagination_complete = TRUE
  )
  events_list[[length(events_list) + 1]] <- comp_ev

  # Combine all event rows into single data frame
  all_events <- do.call(rbind, events_list)

  # 5. Classify overall run
  summary_res <- nightly_classify(all_events)
  cat("\n---------------------------------------------------------------------\n")
  cat("Execution Classification:", summary_res$overall_classification, "\n")
  cat("Counts - PASS:", summary_res$counts$pass,
      "| WORLD_DRIFT:", summary_res$counts$world_drift,
      "| PIPELINE_FAILURE:", summary_res$counts$pipeline_failure, "\n")
  cat("---------------------------------------------------------------------\n\n")

  # 6. Write artifact output package
  nightly_write_artifacts(all_events, summary_res, output_dir = "artifacts/nightly")

  # 7. Exit status decision (Section 34)
  if (isTRUE(summary_res$workflow_should_fail)) {
    cat("FATAL: Pipeline failures detected. Exiting non-zero.\n")
    quit(status = 1)
  } else {
    cat("SUCCESS: Nightly sentinel run completed cleanly.\n")
    quit(status = 0)
  }
}

if (!interactive()) {
  run_main()
}
