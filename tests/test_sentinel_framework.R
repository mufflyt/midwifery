#!/usr/bin/env Rscript
# =============================================================================
# Unit & Mutation Test Suite for Sentinel Observability Framework
# =============================================================================
# Proves that the sentinel engine correctly classifies clean inputs (PASS),
# external attribute moves (WORLD_DRIFT), pipeline defects (PIPELINE_FAILURE),
# and network outages (SOURCE_FAILURE) without confusing one for another.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))

source(file.path(root, "R", "lib", "sentinel_engine.R"))
source(file.path(root, "R", "sentinel_report.R"))

ci_section("S1 Clean World Baseline Evaluation")

ev_clean1 <- classify_sentinel_event("SENTINEL-ID-001", "identity_linkage", "1000000001", "1000000001", "expected_match")
ev_clean2 <- classify_sentinel_event("SENTINEL-ID-001", "amcb", "ACTIVE", "ACTIVE", "amcb_status_check")

events_clean <- bind_rows(ev_clean1, ev_clean2)
summary_clean <- summarize_sentinel_run(events_clean)

if (summary_clean$overall_status == "PASS" && summary_clean$pass_count == 2) {
  ci_ok("clean world evaluation yields PASS status across all sentinels")
} else {
  ci_fail("S1: clean world evaluation failed (expected PASS, got %s)", summary_clean$overall_status)
}


ci_section("S2 World Drift Event Classification (External Fact Changed)")

# Case A: Provider changed state from CO to AZ
ev_drift_state <- classify_sentinel_event("SENTINEL-ID-017", "nppes", "CO", "AZ", "state_moved", difficulty_class = "mover")

# Case B: AMCB certification status changed from ACTIVE to LAPSED
ev_drift_status <- classify_sentinel_event("SENTINEL-ID-003", "amcb", "ACTIVE", "LAPSED", "amcb_status_change")

# Case C: Census Current tract shift
ev_drift_census <- classify_sentinel_event("SENTINEL-GEO-001", "geocoding", "002300", "002400", "census_current_shift")

events_drift <- bind_rows(ev_clean1, ev_drift_state, ev_drift_status, ev_drift_census)
summary_drift <- summarize_sentinel_run(events_drift)

if (summary_drift$overall_status == "WORLD_DRIFT" && summary_drift$world_drift_count == 3) {
  ci_ok("external fact changes (state move, AMCB status change, Census shift) correctly classified as WORLD_DRIFT (count=%d)",
        summary_drift$world_drift_count)
} else {
  ci_fail("S2: world drift classification failed (expected WORLD_DRIFT with 3 events, got %s with %d)",
          summary_drift$overall_status, summary_drift$world_drift_count)
}


ci_section("S3 Pipeline Integrity Failure Classification (Software / Matcher Defect)")

# Case A: Wrong NPI accepted
ev_pipe_wrong_npi <- classify_sentinel_event("SENTINEL-ID-001", "identity_linkage", "1000000001", "9999999999", "wrong_npi_accepted")

# Case B: Negative control violated (expected no match, NPI accepted)
ev_pipe_neg_viol <- classify_sentinel_event("SENTINEL-ID-024", "identity_linkage", "UNMATCHED", "1000000024", "negative_control_violation")

# Case C: Parser failure
ev_pipe_parser <- classify_sentinel_event("SENTINEL-ID-005", "amcb", "ACTIVE", "UNPARSEABLE", "parser_failure")

events_pipe <- bind_rows(events_drift, ev_pipe_wrong_npi, ev_pipe_neg_viol, ev_pipe_parser)
summary_pipe <- summarize_sentinel_run(events_pipe)

if (summary_pipe$overall_status == "PIPELINE_FAILURE" && summary_pipe$pipeline_failure_count == 3) {
  ci_ok("software/matcher defects (wrong NPI, negative control breach, parser crash) correctly classified as PIPELINE_FAILURE (count=%d)",
        summary_pipe$pipeline_failure_count)
} else {
  ci_fail("S3: pipeline failure classification failed (expected PIPELINE_FAILURE with 3 failures, got %s with %d)",
          summary_pipe$overall_status, summary_pipe$pipeline_failure_count)
}


ci_section("S4 External Source Outage Classification")

ev_src_outage <- classify_sentinel_event("SENTINEL-ID-001", "amcb", "200", "HTTP 503 Service Unavailable", "http_503_outage")

summary_outage <- summarize_sentinel_run(bind_rows(events_clean, ev_src_outage))

if (summary_outage$overall_status == "SOURCE_FAILURE" && summary_outage$source_failure_count == 1) {
  ci_ok("external source HTTP outage correctly classified as SOURCE_FAILURE without misclassifying as provider fact loss")
} else {
  ci_fail("S4: source outage classification failed (expected SOURCE_FAILURE, got %s)", summary_outage$overall_status)
}


ci_section("S5 Sentinel Artifact Report Generation")

temp_out_dir <- tempfile("sentinel_test_")
report_res <- write_sentinel_reports(events_drift, output_dir = temp_out_dir)

if (file.exists(report_res$json) && file.exists(report_res$csv) && file.exists(report_res$md) && report_res$status == "WORLD_DRIFT") {
  ci_ok("write_sentinel_reports successfully generated summary.json, events.csv, and report.md")
} else {
  ci_fail("S5: report generation failed to produce expected output files in %s", temp_out_dir)
}

unlink(temp_out_dir, recursive = TRUE)

ci_finish()
