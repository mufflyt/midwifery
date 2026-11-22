#!/usr/bin/env Rscript
# =============================================================================
# Agreement with the national provider registry, by provider practice state
# =============================================================================
# The commercial-directory literature finds that consistency is not uniform
# geography: marked state-to-state variation even after the insurer effect is
# removed (Butala 2024, BMC Health Serv Res 24:808). This artifact computes
# the same stratifier for the cohort: for each of the four longitudinal
# sources, the share of provider-years whose source-recorded practice state
# equals the registry's state in the same year, stratified by the registry
# state itself.
#
# A low share in one state is not evidence that the source is wrong there:
# the registry state is the stratifier, not the truth. States with strong
# multistate enrollment patterns read low under equality scoring for
# Medicaid; that is a scoring artifact, surfaced here rather than hidden in
# the pooled figure.
#
# Inputs : artifacts/canonical_source_records.csv
# Outputs: artifacts/state_variation_agreement_by_source.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))

IN  <- "artifacts/canonical_source_records.csv"
OUT <- "artifacts/state_variation_agreement_by_source.csv"
MIN_N <- 30L
stopifnot(file.exists(IN))

# usable_for_trend marks left-censored Medicaid segments and pre-SUPPORT-Act
# Open Payments years the producer says cannot support a trend or an
# agreement score; scoring them would measure records the manuscript
# excludes everywhere else (DEBT D14, item 5).
x <- read_csv(IN, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(usable_for_trend == "TRUE", !is.na(state), state != "")

nppes <- x %>%
  filter(source == "nppes") %>%
  select(npi, year, registry_state = state)

out <- x %>%
  filter(source != "nppes") %>%
  inner_join(nppes, by = c("npi", "year")) %>%
  group_by(source, registry_state) %>%
  summarise(
    n_comparable  = n(),
    pct_agree     = 100 * mean(state == registry_state),
    .groups = "drop") %>%
  filter(n_comparable >= MIN_N) %>%
  arrange(source, pct_agree)

write_with_provenance(out, OUT, inputs = IN)
print(as.data.frame(out %>%
  group_by(source) %>%
  summarise(n_states = n(), min = min(pct_agree), median = median(pct_agree),
            max = max(pct_agree), .groups = "drop")))
