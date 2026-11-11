#!/usr/bin/env Rscript
# =============================================================================
# A2 before/after: what correcting the Medicaid reduction actually changed
# =============================================================================
# Spec A2 requires the before/after effect on headline estimates to be
# recorded, not asserted. This compares the mrost_* tables produced before the
# date-range expansion against the ones produced after it.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE Rscript -e. The first version of this
# artifact was generated inline, and its sidecar came out with
# code_sha256 = null and code = []. write_with_provenance() resolves the
# producing code through .code_closure(), which reads the --file= entry of
# commandArgs(); under `Rscript -e` there is no such entry, so the artifact
# recorded its inputs but not the code that made them. An artifact whose
# sidecar cannot name its producer is not reproducible, which is the whole
# point of the sidecar.
#
# THE HEADLINE RESULT IS A NEGATIVE ONE. The expansion was predicted to move
# medicaid_enrollment's odd-one-out rate and fusion agreement. It did not:
# 0.166 -> 0.163 and 77.5% -> 77.6%. The reduction error is real (14.4% of
# NPI-years) but concentrated in 2013-2017, while both metrics are computed
# on the current-snapshot slice where old and new already agreed to within
# 5.7%. The prediction was wrong and the artifact records that.
#
# Inputs : BEFORE_* snapshots (scratchpad, taken before the rebuild)
#          artifacts/mrost_odd_one_out_rate.csv
#          artifacts/mrost_truth_fusion_agreement.csv
# Outputs: artifacts/a2_medicaid_before_after.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

# The BEFORE_* snapshots are taken outside the repo, immediately before the
# rebuild, and are session-local by nature -- they are the only copy of the
# pre-correction state. The path is therefore required from the environment
# rather than defaulted: an absolute scratchpad path baked into a tracked
# script resolves to nothing on any other machine, and ci_repo_integrity
# flags it (correctly) as an absolute-path finding.
BEFORE_DIR <- Sys.getenv("A2_BEFORE_DIR", "")

#' Pair one metric's before and after values by source
#'
#' @param before_path,after_path [character] the two CSVs.
#' @param value_col [character] the column holding the metric.
#' @param metric [character] label written into the output.
#' @return [data.frame] metric, source, before, after.
pair_metric <- function(before_path, after_path, value_col, metric) {
  b <- readr::read_csv(before_path, show_col_types = FALSE)
  a <- readr::read_csv(after_path, show_col_types = FALSE)
  dplyr::left_join(
    dplyr::transmute(b, metric = metric, source,
                     before = .data[[value_col]]),
    dplyr::transmute(a, source, after = .data[[value_col]]),
    by = "source")
}

if (sys.nframe() == 0L) {
  if (!nzchar(BEFORE_DIR) || !dir.exists(BEFORE_DIR)) {
    base::message(paste(
      "A2_BEFORE_DIR is not set to a directory holding BEFORE_fusion.csv and",
      "BEFORE_odd.csv. Those snapshots are taken before the rebuild and are",
      "not reproducible afterwards; artifacts/a2_medicaid_before_after.csv",
      "already records the comparison. Nothing to do."))
    quit(status = 0L)
  }
  out <- dplyr::bind_rows(
    pair_metric(file.path(BEFORE_DIR, "BEFORE_fusion.csv"),
                "artifacts/mrost_truth_fusion_agreement.csv",
                "pct_agree_with_fused", "fusion_agreement_pct"),
    pair_metric(file.path(BEFORE_DIR, "BEFORE_odd.csv"),
                "artifacts/mrost_odd_one_out_rate.csv",
                "odd_rate", "odd_one_out_rate")) %>%
    dplyr::mutate(
      delta = round(after - before, 3),
      explanation = dplyr::if_else(
        source == "medicaid_enrollment",
        paste("A2 date-range expansion. Near-zero change: the reduction error",
              "is concentrated in 2013-2017 while this metric is computed on",
              "the current-snapshot slice, where the whole-file modal state",
              "and the year-specific state already agreed to within 5.7%."),
        "unchanged; A2 touched only medicaid_enrollment"))

  write_with_provenance(out, "artifacts/a2_medicaid_before_after.csv",
                        inputs = c("artifacts/mrost_odd_one_out_rate.csv",
                                   "artifacts/mrost_truth_fusion_agreement.csv",
                                   "artifacts/medicaid_enrollment_cohort_state_by_year.csv"),
                        na = "")
  base::message(sprintf("wrote %d rows; medicaid deltas: %s",
                        nrow(out),
                        paste(out$delta[out$source == "medicaid_enrollment"],
                              collapse = ", ")))
}
