#!/usr/bin/env Rscript
#' @title Person-level exclusion stage for every AMCB certificant
#'
#' @description
#' The row-level companion to make_cohort_exclusion_flow_figure.R's
#' aggregate counts: one row per certification record, with the exact
#' stage at which that person was excluded (or "included_final_cohort" if
#' none). Answers "which named person was matched/not matched at each
#' step" -- the figure only ever shows counts.
#'
#' Exclusion stage is assigned in the SAME order and on the SAME
#' definitions as the figure: deceased/inactive, no NPI match (match_status
#' != "primary"), no geocodable address, no ACOG district. A person is
#' assigned to the FIRST stage that excludes them -- someone both inactive
#' and unmatched is filed under "deceased_or_inactive" only, matching how
#' the figure's ladder works (later stages are conditioned on surviving
#' earlier ones).
#'
#' Output: docs/figures/cohort_exclusion_flow_person_level.csv (one row per
#' certification record) plus one filtered CSV per exclusion stage, all
#' under docs/figures/exclusion_by_stage/.
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

LINKAGE   <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
GEOGRAPHY <- file.path("artifacts", "midwives_geography_FROZEN.csv")

ACOG_UNMAPPED <- c("AA", "AE", "AP", "GU", "PR", "VI", "AS", "MP", "FM", "PW", "MH")

linkage <- read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE, guess_max = Inf)
geo     <- read_csv(GEOGRAPHY, show_col_types = FALSE, progress = FALSE, guess_max = Inf)

geo_std <- geo %>%
  transmute(certification_number, geocoded = !is.na(county_best))

joined <- linkage %>%
  left_join(geo_std, by = "certification_number") %>%
  mutate(geocoded = coalesce(geocoded, FALSE),
         acog_mapped = geocoded & !(nppes_state %in% ACOG_UNMAPPED))

out <- joined %>%
  transmute(
    certification_number, last_name, first_name, middle_name, status,
    match_status, name_evidence_class, nppes_state, geocoded, acog_mapped,
    # For sensitivity_fuzzy / sensitivity_nursing_taxonomy the matcher DID
    # find and keep a candidate NPI -- it's just held out of the "primary"
    # definition, not demoted to NA the way a lost class-5 candidate is. So
    # these five columns show exactly what the accepted match would be if
    # that sensitivity tier were promoted to primary.
    would_be_npi = npi,
    would_be_matched_last = nppes_matched_last,
    would_be_matched_first = nppes_matched_first,
    would_be_city = nppes_city,
    would_be_state = nppes_state,
    npi_tax_class,
    # For ambiguous_tied_names / ambiguous_contested_npi, npi is genuinely NA
    # in this artifact -- the matcher's candidate pool (which NPIs/names were
    # actually tied or contested) lives in linkage_candidate_audit.csv /
    # linkage_pool_diagnostics.csv, produced by match_amcb_to_npi.R but not
    # retained as a committed artifact on this machine. match_reason and
    # ambiguity_flag are the most specific record that DOES survive into the
    # frozen linkage: they state how many candidates existed, how many tied,
    # and at what evidence class -- but not those candidates' own names/NPIs.
    candidate_count, match_reason, ambiguity_flag,
    exclusion_stage = case_when(
      status != "ACTIVE"              ~ "deceased_or_inactive",
      match_status != "primary"       ~ "no_npi_match",
      !geocoded                       ~ "no_geocodable_address",
      !acog_mapped                    ~ "no_acog_district",
      TRUE                            ~ "included_final_cohort"
    )
  )

stopifnot(nrow(out) == nrow(linkage))

out_dir <- file.path("docs", "figures")
stage_dir <- file.path(out_dir, "exclusion_by_stage")
dir.create(stage_dir, showWarnings = FALSE, recursive = TRUE)

master_path <- file.path(out_dir, "cohort_exclusion_flow_person_level.csv")
write_with_provenance(out, master_path, inputs = c(LINKAGE, GEOGRAPHY))

stage_counts <- count(out, exclusion_stage, sort = TRUE)
cat("Stage counts:\n")
print(as.data.frame(stage_counts))

stage_files <- c()
for (st in unique(out$exclusion_stage)) {
  p <- file.path(stage_dir, sprintf("%s.csv", st))
  write_csv(out[out$exclusion_stage == st, ], p)
  stage_files <- c(stage_files, p)
  cat(sprintf("wrote %s (%d rows)\n", p, sum(out$exclusion_stage == st)))
}

cat(sprintf("\nwrote %s (%d rows)\n", master_path, nrow(out)))
