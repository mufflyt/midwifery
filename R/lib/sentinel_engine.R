#' @title Midwifery External-World Sentinel Classification Engine
#'
#' @description
#' Governed observability and classification engine for the midwifery workforce
#' project. Distinguishes three fundamentally distinct outcome classes:
#'   - PASS: External world matches governed expectation.
#'   - WORLD_DRIFT: Pipeline worked correctly, but external fact changed
#'                  (e.g., AMCB status update, provider address move, Census Current shift).
#'   - PIPELINE_FAILURE: Software, matcher, parser, or source structure broke
#'                       (e.g. wrong NPI accepted, negative control violated, parser crash).
#'
#' Read-only by design: NEVER mutates production scientific datasets or frozen cohorts.

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

#' Classify a single sentinel observation event
#'
#' @param sentinel_id Character ID of sentinel
#' @param subsystem Subsystem name ("amcb", "nppes", "identity_linkage", "geocoding")
#' @param expected_val Character/list expected value
#' @param observed_val Character/list observed value
#' @param event_type Specific event type string
#' @param difficulty_class Complexity tier of sentinel
#' @return A single-row tibble with event classification details
classify_sentinel_event <- function(sentinel_id,
                                    subsystem,
                                    expected_val,
                                    observed_val,
                                    event_type,
                                    difficulty_class = "straightforward") {

  expected_str <- as.character(coalesce(expected_val, "NA"))
  observed_str <- as.character(coalesce(observed_val, "NA"))

  classification <- "PASS"
  severity       <- "INFO"
  desc           <- "Observed attribute matches expected baseline."

  if (identical(expected_str, observed_str)) {
    classification <- "PASS"
    severity       <- "INFO"
  } else {
    case_type <- tolower(event_type)

    if (grepl("wrong_npi|negative_control_violation|parser_failure|expected_npi_missing", case_type)) {
      classification <- "PIPELINE_FAILURE"
      severity       <- "ERROR"
      desc           <- sprintf("Pipeline integrity failure: expected [%s], observed [%s]", expected_str, observed_str)
    } else if (grepl("http_500|http_503|source_unavailable|timeout", case_type)) {
      classification <- "SOURCE_FAILURE"
      severity       <- "WARNING"
      desc           <- sprintf("External source unavailable: %s", observed_str)
    } else if (grepl("amcb_status_change|state_moved|zip_changed|census_current_shift", case_type)) {
      classification <- "WORLD_DRIFT"
      severity       <- "WARNING"
      desc           <- sprintf("External fact changed: expected [%s], observed [%s]", expected_str, observed_str)
    } else {
      # Default fallback for discrepancies
      classification <- "WORLD_DRIFT"
      severity       <- "INFO"
      desc           <- sprintf("Attribute discrepancy: expected [%s], observed [%s]", expected_str, observed_str)
    }
  }

  tibble::tibble(
    sentinel_id      = as.character(sentinel_id),
    subsystem        = as.character(subsystem),
    event_type       = as.character(event_type),
    expected         = expected_str,
    observed         = observed_str,
    classification   = classification,
    severity         = severity,
    difficulty_class = as.character(difficulty_class),
    description      = desc
  )
}


#' Summarize a full sentinel run into high-level metrics
#'
#' @param events_df Data frame of events produced by classify_sentinel_event
#' @return List of overall metrics and verdict
summarize_sentinel_run <- function(events_df) {
  if (is.null(events_df) || nrow(events_df) == 0) {
    return(list(
      overall_status         = "PASS",
      total_sentinels        = 0L,
      pass_count             = 0L,
      world_drift_count      = 0L,
      pipeline_failure_count = 0L,
      source_failure_count   = 0L
    ))
  }

  pass_n     <- sum(events_df$classification == "PASS", na.rm = TRUE)
  drift_n    <- sum(events_df$classification == "WORLD_DRIFT", na.rm = TRUE)
  pipe_fail  <- sum(events_df$classification == "PIPELINE_FAILURE", na.rm = TRUE)
  src_fail   <- sum(events_df$classification == "SOURCE_FAILURE", na.rm = TRUE)
  total_n    <- nrow(events_df)

  overall <- if (pipe_fail > 0) {
    "PIPELINE_FAILURE"
  } else if (src_fail > 0) {
    "SOURCE_FAILURE"
  } else if (drift_n > 0) {
    "WORLD_DRIFT"
  } else {
    "PASS"
  }

  list(
    overall_status         = overall,
    total_sentinels        = total_n,
    pass_count             = pass_n,
    world_drift_count      = drift_n,
    pipeline_failure_count = pipe_fail,
    source_failure_count   = src_fail
  )
}
