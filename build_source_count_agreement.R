#!/usr/bin/env Rscript
# =============================================================================
# Agreement on practice state as a function of how many sources report one
# =============================================================================
# The commercial-directory literature reports cross-source consistency as a
# dose-response: the more directories a physician appears in, the lower the
# share whose address is consistent across all of them (Butala 2023,
# JAMA 329:841-842). This artifact computes the same quantity for the cohort:
# among provider-years in which >= 2 of the five longitudinal sources carry a
# comparable practice state, the share on which every reporting source agrees
# (unanimous agreement) and the share of source-pairs that agree (pairwise
# agreement), stratified by the number of reporting sources.
#
# Semantics match the manuscript's pairwise tables: each source contributes
# its own recorded practice state for that provider-year, compared by
# equality. Medicaid's multi-state complication does not enter because the
# canonical record carries one state per provider-year per source; the
# membership-vs-equality question is handled separately (Table SDC and
# audit_medicaid_set_membership.R).
#
# Inputs : artifacts/canonical_source_records.csv
# Outputs: artifacts/source_count_agreement_by_n_sources.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

IN  <- "artifacts/canonical_source_records.csv"
OUT <- "artifacts/source_count_agreement_by_n_sources.csv"
stopifnot(file.exists(IN))

# usable_for_trend excludes left-censored Medicaid segments and
# pre-SUPPORT-Act Open Payments years; scoring them would measure records
# the manuscript excludes everywhere else (DEBT D14, item 5).
x <- read_csv(IN, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(usable_for_trend == "TRUE", !is.na(state), state != "")

# For each provider-year with >= 2 reporting sources, count the source
# pairs and how many of them record the same state.
pairs <- x %>%
  inner_join(x, by = c("amcb_id", "year"), suffix = c("_a", "_b"),
             relationship = "many-to-many") %>%
  filter(source_a < source_b) %>%
  mutate(pair_agrees = state_a == state_b) %>%
  group_by(amcb_id, year) %>%
  summarise(n_pairs = n(), n_pairs_agreeing = sum(pair_agrees), .groups = "drop")

per_year <- x %>%
  group_by(amcb_id, year) %>%
  summarise(n_sources_reporting = n_distinct(source),
            unanimous = n_distinct(state) == 1L, .groups = "drop") %>%
  inner_join(pairs, by = c("amcb_id", "year"))

out <- per_year %>%
  filter(n_sources_reporting >= 2) %>%
  group_by(n_sources_reporting) %>%
  summarise(
    n_provider_years = n(),
    pct_unanimous_agreement = 100 * mean(unanimous),
    pct_pairwise_agreement  = 100 * sum(n_pairs_agreeing) / sum(n_pairs),
    .groups = "drop") %>%
  arrange(n_sources_reporting)

write_with_provenance(out, OUT, inputs = IN)
print(as.data.frame(out))
