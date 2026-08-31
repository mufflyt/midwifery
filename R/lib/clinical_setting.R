#!/usr/bin/env Rscript
# =============================================================================
# Clinical practice-setting category detection
# =============================================================================
# Two fields encode the same 1-6 practice-setting taxonomy at different
# stages of the pipeline:
#   final_facility_setting    "1. Hospital Privileges (CMS Medicare Direct)"
#   refined_clinical_setting  "1a. Active Attending Hospital Staff (...)"
#                             "1b. Inactive/Consulting Hospital Privileges (...)"
# The refined field inserts a lowercase sub-category letter between the digit
# and the period for categories 1-5 (category 6 has no sub-letter in either
# field). A bare `str_detect(x, "1\\.")` matches the first format and NEVER
# the second, because "1a." contains no "1." substring -- the digit is
# followed by a letter, not a period. That exact pattern was copied into at
# least 7 files (build_tier1_tier2_bon_summary_report.R,
# analyze_tier1_complete_results.R, analyze_tier2_complete_results.R,
# analyze_20_state_bon_scrape.R, validate_scraped_20_state_bon_results.R,
# validate_address_recency_pipeline.R, build_complete_leaflet_map.R) and,
# wherever it was applied to refined_clinical_setting rather than
# final_facility_setting, silently counted and colour-coded zero matches.
# =============================================================================
suppressPackageStartupMessages(library(stringr))

#' Extract the leading category number (1-6) from a clinical-setting label
#'
#' Matches both the pre-refinement bare-digit format and the post-refinement
#' lettered-subcategory format.
#' @param x [character]: a final_facility_setting or refined_clinical_setting value.
#' @return [integer] category 1-6, or NA where the label does not start with one.
facility_setting_category <- function(x) {
  suppressWarnings(as.integer(str_match(as.character(x), "^([1-6])[a-z]?\\.")[, 2]))
}

#' Does a clinical-setting label belong to category `n`?
#' @param x [character]: label vector.
#' @param n [integer(1)]: category number, 1-6.
#' @return [logical] TRUE/FALSE, or NA where the label does not start with a
#'   recognized category -- callers that previously wrapped the bare
#'   str_detect() in na.rm = TRUE should keep doing so.
is_facility_setting_category <- function(x, n) {
  facility_setting_category(x) == n
}
