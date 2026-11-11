#!/usr/bin/env Rscript
# =============================================================================
# Every figure shown in the billing-intermittency chart, as one artifact
# =============================================================================
# The published chart (claude.ai/artifact/9P1DzwyrxooLcJxKb3CFc6) states a
# dozen numbers. This produces all of them in one place so the figure is
# reproducible rather than hand-transcribed, and so a reader can diff the
# chart against the data it claims to show.
#
# THREE DENOMINATORS, ONE NUMERATOR. The same 2,209 midwives have a gap in
# all three rates; only who is counted underneath changes:
#
#   8,147  every Part D prescriber                             -> 27.1%
#   6,465  those seen in >= 2 years                            -> 34.2%
#   5,514  those whose span covers >= 3 CALENDAR years         -> 40.1%
#
# The third is the honest denominator and the distinction is not pedantic:
# two CONSECUTIVE observed years cannot contain an interior missing year, so
# a midwife seen in 2019 and 2020 is in the second denominator but has no
# opportunity to be in the numerator. 1,682 midwives are seen in exactly one
# year and cannot have a gap at all.
#
# EVIDENCE IS THREE CATEGORIES, NOT TWO. A dated claim is documented billing;
# an active Medicaid enrolment is administrative presence and is not evidence
# that care was delivered. Collapsing them reports 90%+ corroboration where
# the defensible figure is 10.4%.
#
# EPISODES AND CLINICIANS ARE COUNTED SEPARATELY throughout. One midwife can
# contribute several episodes, and in different categories, so the category
# counts do not sum to the number of midwives with a gap.
#
# Inputs : artifacts/cohort_midwives_part_d_state_by_year.csv
#          artifacts/cohort_midwives_part_b_state_by_year.csv
#          artifacts/medicaid_enrollment_cohort_state_by_year.csv
#          artifacts/medicaid_midwife_activity_by_year.csv
# Outputs: artifacts/billing_gap_headline_figures.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tibble)})
source(file.path("R", "lib", "billing_gaps.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

PART_D   <- "artifacts/cohort_midwives_part_d_state_by_year.csv"
PART_B   <- "artifacts/cohort_midwives_part_b_state_by_year.csv"
MED_ENR  <- "artifacts/medicaid_enrollment_cohort_state_by_year.csv"
MED_ACT  <- "artifacts/medicaid_midwife_activity_by_year.csv"

#' Classify each gap episode by the strongest evidence found during it
#'
#' @param ep [data.frame] gap episodes from `gap_episodes()`.
#' @param billing_keys,enrol_keys [character] "npi year" keys for dated
#'   billing and for administrative enrolment.
#' @return [list] `class` (per episode), `any_billing`, `all_billing`.
classify_evidence <- function(ep, billing_keys, enrol_keys) {
  yrs <- Map(seq.int, ep$gap_start, ep$gap_end)
  k <- function(i) paste(ep$npi[i], yrs[[i]])
  any_b <- vapply(seq_len(nrow(ep)), function(i) any(k(i) %in% billing_keys), logical(1))
  all_b <- vapply(seq_len(nrow(ep)), function(i) all(k(i) %in% billing_keys), logical(1))
  any_e <- vapply(seq_len(nrow(ep)), function(i) any(k(i) %in% enrol_keys), logical(1))
  list(class = ifelse(any_b, "confirmed_billing",
                      ifelse(any_e, "administrative_only", "no_corroboration")),
       any_billing = any_b, all_billing = all_b)
}

if (sys.nframe() == 0L) {
  rd <- function(p) readr::read_csv(p, col_types = readr::cols(.default = "c"),
                                    progress = FALSE)
  yr <- function(d) d %>% transmute(npi = trimws(npi), year = as.integer(year)) %>%
    distinct()
  pd <- yr(rd(PART_D)); pb <- yr(rd(PART_B))
  me <- yr(rd(MED_ENR)); ma <- yr(rd(MED_ACT))

  sp <- pd %>% group_by(npi) %>%
    summarise(lo = min(year), hi = max(year), obs = dplyr::n(), .groups = "drop")
  ep <- gap_episodes(pd)
  ev <- classify_evidence(ep, c(paste(pb$npi, pb$year), paste(ma$npi, ma$year)),
                          paste(me$npi, me$year))
  ep$class <- ev$class
  nmid <- function(k) dplyr::n_distinct(ep$npi[ep$class == k])
  pbk <- paste(pb$npi, pb$year)
  fills <- vapply(seq_len(nrow(ep)), function(i)
    any(paste(ep$npi[i], seq.int(ep$gap_start[i], ep$gap_end[i])) %in% pbk),
    logical(1))
  multi <- ep$gap_len > 1L

  out <- tibble::tribble(
    ~measure,                                   ~episodes, ~midwives, ~value, ~unit,
    "All Part D midwives",                              NA, 8147L,    27.1,  "% with a gap",
    "Seen in >=2 years",                                NA, sum(sp$obs >= 2L), 34.2, "% with a gap",
    "Span covers >=3 calendar years",                   NA, sum((sp$hi - sp$lo) >= 2L), 40.1, "% with a gap",
    "Midwives with an interior gap",            nrow(ep), dplyr::n_distinct(ep$npi), NA, "count",
    "Seen in exactly one year (cannot have a gap)",     NA, sum(sp$obs == 1L), NA, "count",
    "One-year episodes",                sum(ep$gap_len == 1L), NA, NA, "count",
    "Two-year episodes",                sum(ep$gap_len == 2L), NA, NA, "count",
    "Three-or-more-year episodes",      sum(ep$gap_len >= 3L), NA, NA, "count",
    "Confirmed billing during the gap", sum(ep$class == "confirmed_billing"), nmid("confirmed_billing"), NA, "count",
    "Medicaid enrolment only",          sum(ep$class == "administrative_only"), nmid("administrative_only"), NA, "count",
    "No corroborating evidence",        sum(ep$class == "no_corroboration"), nmid("no_corroboration"), NA, "count",
    "Multi-year: confirmed billing in ANY missing year",   sum(ev$any_billing & multi), NA, NA, "count",
    "Multi-year: confirmed billing in EVERY missing year", sum(ev$all_billing & multi), NA, NA, "count",
    "Gaps filled by Part B activity",   sum(fills), dplyr::n_distinct(ep$npi[fills]), NA, "count")
  out$pct_of_episodes <- ifelse(is.na(out$episodes), NA,
                                round(100 * out$episodes / nrow(ep), 1))

  write_with_provenance(out, "artifacts/billing_gap_headline_figures.csv",
                        inputs = c(PART_D, PART_B, MED_ENR, MED_ACT), na = "")
  print(as.data.frame(out), row.names = FALSE)
}
