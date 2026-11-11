#!/usr/bin/env Rscript
# =============================================================================
# Medicaid set membership: equality against one pick vs membership of a set
# =============================================================================
# THE DEFECT. expand_segments_to_years() computes every (year, npi, state) a
# midwife was enrolled in and then keeps one row per NPI-year by modal rule.
# 59,380 of 178,907 state memberships -- 33.2% -- were discarded and emitted
# nowhere. Every comparison against this source therefore tested whether
# another source agreed with ONE PICK, not whether it named a state the
# midwife was actually enrolled in. A midwife enrolled in CO, NM and AZ was
# recorded as CO and scored as disagreeing with a source that said AZ.
#
# ROOT CAUSE. The reduction was written to satisfy a single-valued
# comparator (attribute_agreement() takes one value per entity-year). That
# constraint is real; discarding the set instead of also emitting it is not
# required by it.
#
# WHAT THIS DOES NOT DO. It does not widen the existing single-valued series
# or change which NPI-years exist. The footprint is a second artifact with
# the same (npi, year) keys, so presence-based analyses -- the gap work, the
# three-way evidence classification, the figures in the published artifact --
# are untouched by construction. That invariant is asserted here rather than
# assumed, because "unrelated classifications unchanged" is a claim, not a
# hope.
#
# Inputs : artifacts/medicaid_enrollment_cohort_state_by_year.csv
#          artifacts/medicaid_enrollment_cohort_state_footprint.csv
#          midwife_panel.csv
# Outputs: artifacts/medicaid_set_membership_before_after.csv
#          artifacts/medicaid_set_membership_by_year.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(tibble)})
source(file.path("R", "lib", "artifact_provenance.R"))

MODAL <- "artifacts/medicaid_enrollment_cohort_state_by_year.csv"
FOOT  <- "artifacts/medicaid_enrollment_cohort_state_footprint.csv"
PANEL <- "midwife_panel.csv"

#' Agreement with a reference source under two different rules
#'
#' @param ref [data.frame] npi, year, state -- the comparator (NPPES).
#' @param modal [data.frame] npi, year, state -- one state per NPI-year.
#' @param foot [data.frame] npi, year, state -- every state per NPI-year.
#' @return [list] `equality` and `membership` agreement rates plus the
#'   comparable denominator, which is identical for both by construction:
#'   the same NPI-years are comparable, only the test changes.
agreement_two_ways <- function(ref, modal, foot) {
  eq <- dplyr::inner_join(ref, modal, by = c("npi", "year"),
                          suffix = c("_ref", "_mod"))
  n <- nrow(eq)
  eq_hit <- sum(eq$state_ref == eq$state_mod)
  fkey <- paste(foot$npi, foot$year, foot$state)
  mem_hit <- sum(paste(eq$npi, eq$year, eq$state_ref) %in% fkey)
  list(n_comparable = n,
       equality_pct = round(100 * eq_hit / n, 1),
       membership_pct = round(100 * mem_hit / n, 1),
       newly_agreeing = mem_hit - eq_hit)
}

if (sys.nframe() == 0L) {
  rd <- function(p) readr::read_csv(p, col_types = readr::cols(.default = "c"),
                                    progress = FALSE)
  modal <- rd(MODAL) %>% transmute(npi = trimws(npi), year = as.integer(year),
                                   state) %>% distinct()
  foot  <- rd(FOOT)  %>% transmute(npi = trimws(npi), year = as.integer(year),
                                   state) %>% distinct()
  ref   <- rd(PANEL) %>%
    transmute(npi = trimws(npi), year = as.integer(snapshot_year),
              state = practice_state) %>%
    filter(!is.na(state), nzchar(state)) %>% distinct()

  # INVARIANT: the footprint must add states, never NPI-years or midwives.
  k_mod <- unique(paste(modal$npi, modal$year))
  k_fp  <- unique(paste(foot$npi, foot$year))
  stopifnot(setequal(k_mod, k_fp))
  stopifnot(setequal(unique(modal$npi), unique(foot$npi)))
  base::message(sprintf(
    "invariant holds: same %s NPI-years and same %s midwives in both",
    format(length(k_mod), big.mark = ","),
    format(dplyr::n_distinct(modal$npi), big.mark = ",")))

  # Every footprint row must trace to a modal NPI-year.
  stopifnot(all(paste(foot$npi, foot$year) %in% k_mod))

  a <- agreement_two_ways(ref, modal, foot)
  by_year <- lapply(sort(unique(modal$year)), function(y) {
    r <- agreement_two_ways(filter(ref, year == y), filter(modal, year == y),
                            filter(foot, year == y))
    tibble(year = y, n_comparable = r$n_comparable,
           equality_pct = r$equality_pct, membership_pct = r$membership_pct,
           newly_agreeing = r$newly_agreeing)
  }) %>% bind_rows()

  ba <- tibble(
    quantity = c("state memberships in the footprint",
                 "state memberships kept by the modal rule",
                 "memberships discarded before the fix",
                 "pct of memberships discarded",
                 "NPI-years (identical in both, by invariant)",
                 "midwives (identical in both, by invariant)",
                 "comparable NPI-years vs NPPES",
                 "agreement, equality with the modal pick (%)",
                 "agreement, membership of the enrolled set (%)",
                 "NPI-years newly scored as agreeing"),
    value = c(nrow(foot), nrow(modal), nrow(foot) - nrow(modal),
              round(100 * (nrow(foot) - nrow(modal)) / nrow(foot), 1),
              length(k_mod), dplyr::n_distinct(modal$npi),
              a$n_comparable, a$equality_pct, a$membership_pct,
              a$newly_agreeing))

  write_with_provenance(ba,
    "artifacts/medicaid_set_membership_before_after.csv",
    inputs = c(MODAL, FOOT), na = "")
  write_with_provenance(by_year,
    "artifacts/medicaid_set_membership_by_year.csv",
    inputs = c(MODAL, FOOT), na = "")

  print(as.data.frame(ba), row.names = FALSE)
  cat("\n=== by year ===\n")
  print(as.data.frame(by_year), row.names = FALSE)
}
