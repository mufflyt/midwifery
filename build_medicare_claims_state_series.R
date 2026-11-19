#!/usr/bin/env Rscript
# =============================================================================
# Medicare claims (Part B + Part D) as ONE practice-state source
# =============================================================================
# extract_medicare_part_b_d_cohort_states.R writes the two Medicare claims
# products as separate per-NPI-year state series. They are NOT two independent
# sources: both are CMS claims-lineage files, and measured on the cohort they
# never disagree -- 13,745 shared NPI-years, 100.0% concordant
# (artifacts/mrost_agreement_pairwise.csv). Counting them as two votes
# double-counts one underlying record as two pieces of evidence, which is the
# exact defect mysteryroster::attribute_claims_collapse_lineage() exists to
# prevent in the multi-source steps.
#
# This script collapses them BEFORE the audit sees them, by the same rule that
# function encodes, applied uniformly to every cohort NPI-year:
#
#   both sources name the same state -> one claim, that state
#   the two sources disagree           -> NO claim for that NPI-year
#                                         (dropped, not an arbitrary pick)
#   exactly one source observed it     -> the claim passes through
#
# The dropped NPI-years are counted and written beside the artifact so the
# collapse's cost is a number, not an assumption. If that count is ever large,
# the two products have stopped sharing a lineage and the collapse is wrong.
#
# WHICH CLAIM THE SOURCE MAKES. A row (npi, year, state) means "a Medicare
# claim filed under her own NPI names this state as her practice location in
# that year". The by-provider files carry one row per NPI so this is the
# provider's rendering/prescribing state, NOT a claim that she saw patients
# there exclusively -- the same caveat match_medicare_partb_partd.R prints:
# absence means no record under her own NPI, never "did not bill".
#
# Inputs : artifacts/cohort_midwives_part_b_state_by_year.csv
#          artifacts/cohort_midwives_part_d_state_by_year.csv
# Outputs: artifacts/cohort_midwives_medicare_claims_state_by_year.csv
#          artifacts/cohort_midwives_medicare_claims_collapse_audit.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
})

source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

PART_B <- "artifacts/cohort_midwives_part_b_state_by_year.csv"
PART_D <- "artifacts/cohort_midwives_part_d_state_by_year.csv"
OUT    <- "artifacts/cohort_midwives_medicare_claims_state_by_year.csv"
AUDIT  <- "artifacts/cohort_midwives_medicare_claims_collapse_audit.csv"
stopifnot(file.exists(PART_B), file.exists(PART_D))

read_series <- function(path, component) {
  read_csv(path, col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = as.integer(year),
              state = clean_state(state), component = component) %>%
    filter(!is.na(npi), nzchar(npi), !is.na(year), !is.na(state))
}

claims <- bind_rows(read_series(PART_B, "part_b"),
                    read_series(PART_D, "part_d"))

# Collapse each NPI-year across the two components. n_states_this_year is
# recomputed for the family: a Part B row and a Part D row naming the SAME
# state are one claim, not two.
collapsed <- claims %>%
  distinct(npi, year, state, component) %>%
  group_by(npi, year) %>%
  summarise(
    states = list(sort(unique(state))),
    n_states_this_year = length(unique(state)),
    in_part_b = any(component == "part_b"),
    in_part_d = any(component == "part_d"),
    .groups = "drop")

kept <- collapsed %>% filter(n_states_this_year == 1L) %>%
  transmute(npi, year, state = vapply(states, `[[`, character(1), 1L),
            in_part_b, in_part_d)
dropped <- collapsed %>% filter(n_states_this_year > 1L)

audit <- bind_rows(
  tibble(metric = "part_b_npi_years",
         value = as.character(sum(claims$component == "part_b"))),
  tibble(metric = "part_d_npi_years",
         value = as.character(sum(claims$component == "part_d"))),
  tibble(metric = "union_npi_years",    value = as.character(nrow(collapsed))),
  tibble(metric = "kept_single_state",  value = as.character(nrow(kept))),
  tibble(metric = "dropped_b_d_conflict", value = as.character(nrow(dropped))),
  tibble(metric = "dropped_conflict_states",
         value = paste(vapply(dropped$states, paste, character(1),
                              collapse = "/"), collapse = ";")))

write_with_provenance(
  kept %>% arrange(npi, year) %>% select(npi, year, state, in_part_b, in_part_d),
  OUT, inputs = c(PART_B, PART_D), na = "")
write_with_provenance(audit, AUDIT, inputs = c(PART_B, PART_D), na = "")

cat(sprintf("medicare_claims: %s kept NPI-years (%s distinct NPIs, %d-%d), %s dropped for B/D conflict\n",
            format(nrow(kept), big.mark = ","),
            format(dplyr::n_distinct(kept$npi), big.mark = ","),
            min(kept$year), max(kept$year),
            format(nrow(dropped), big.mark = ",")))
if (nrow(dropped)) print(as.data.frame(dropped), row.names = FALSE)
