#!/usr/bin/env Rscript
# =============================================================================
# F4: decompose observed lead/lag into its three mechanisms
# =============================================================================
# artifacts/mrost_lead_lag.csv reports, per source, what happened to every
# transition in which the source and NPPES became discordant. It does not say
# WHY. This file maps each measured quantity onto the mechanism that can
# produce it, so "the source lags the registry" stops being one undifferentiated
# number. Three mechanisms, per the longitudinal-reconstruction spec F4:
#
#   reporting delay    one side adopts the other's standing value LATER.
#                      Split by which side was late:
#                      b_adopts_a  -> the SOURCE caught up to the registry
#                      a_reverts_to_b -> the REGISTRY caught up to a value the
#                      source already held (source-led; the registry's move
#                      was retrospective or delayed)
#   ascertainment gap  the discordance never resolves in the window
#                      (persistent_discordant): the source never observed the
#                      move, or it is measuring something else by design
#                      (Medicaid's enrolment-in-a-state is not practice-in-a-
#                      state, so part of its persistent share is definitional
#                      rather than a gap -- see the definitional flag below)
#   retrospective date cross_section_in_prior_b: of cross-sectional
#                      discordances, the share where the source ALREADY held
#                      the value the registry moved TO -- the source recorded
#                      the destination before the registry dated the move
#
# Residual = none of the above in the t+1 window: discordances still
# unresolved at t+1 are bounded below by persistent_discordant_at_t1_pct,
# whose complement is resolution observed within one snapshot step; the
# multi-year columns carry the longer-run resolution for the cohort followed
# from base_year.
#
# A DEFINITIONAL COMPONENT IS FLAGGED, NOT SUBTRACTED. Medicaid's persistent
# share cannot be split further from these columns alone: concurrent
# multi-state enrolment manufactures "discordance" that is correct data
# answering a different question (docs/spec-completion-matrix.md; the
# multistate concordant category in the audit). The flag marks where a
# persistent share is known to contain a definitional component, so the
# number is not read as pure ascertainment failure.
#
# Inputs : artifacts/mrost_lead_lag.csv
# Outputs: artifacts/lead_lag_decomposition.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
})
source(file.path("R", "lib", "artifact_provenance.R"))

IN  <- "artifacts/mrost_lead_lag.csv"
OUT <- "artifacts/lead_lag_decomposition.csv"
stopifnot(file.exists(IN))

ll <- read_csv(IN, col_types = cols(.default = "c"), progress = FALSE)
num <- function(x) suppressWarnings(as.numeric(x))

DEFINITIONAL_COMPONENT <- c(
  medicaid_enrollment = "enrolment-in-state != practice-in-state; concurrent multi-state enrolment inflates the persistent share",
  pecos_revalidation  = "a reassignment on file is not current practice; persistent share includes stale-but-on-file relationships"
)

out <- ll %>%
  transmute(
    source = source_b,
    n_paired_transitions   = as.integer(num(n_paired_transitions)),
    n_discordant_at_t      = as.integer(num(n_discordant_at_t)),
    pct_source_reporting_delay_t1    = num(b_adopts_a_at_t1_pct),
    pct_source_reporting_delay_multi = num(b_adopts_a_multi_pct),
    pct_registry_reporting_delay_t1    = num(a_reverts_to_b_at_t1_pct),
    pct_registry_reporting_delay_multi = num(a_reverts_b_multi_pct),
    pct_persistent_ascertainment_or_definition = num(persistent_discordant_at_t1_pct),
    pct_cross_section_source_held_destination_first = num(cross_section_in_prior_b_pct),
    both_move_together_n = as.integer(num(both_move_together_at_t1)),
    base_year = as.integer(num(base_year)),
    definitional_component = DEFINITIONAL_COMPONENT[source])

out <- out %>%
  mutate(
    dominant_mechanism = case_when(
      pct_persistent_ascertainment_or_definition >= 50 ~
        "ascertainment gap / definitional difference (mostly unresolved)",
      pct_registry_reporting_delay_t1 >= pct_source_reporting_delay_t1 ~
        "registry-side delay (the source led; NPPES caught up later)",
      TRUE ~ "source-side reporting delay (the source caught up later)"),
    resolution_direction = case_when(
      pct_registry_reporting_delay_t1 > 2 * pct_source_reporting_delay_t1 ~ "registry-late",
      pct_source_reporting_delay_t1 > 2 * pct_registry_reporting_delay_t1 ~ "source-late",
      TRUE ~ "bidirectional"))

write_with_provenance(out, OUT, inputs = IN, na = "")
print(as.data.frame(out %>%
  select(source, n_discordant_at_t,
         pct_source_reporting_delay_t1, pct_registry_reporting_delay_t1,
         pct_persistent_ascertainment_or_definition,
         dominant_mechanism, resolution_direction)), row.names = FALSE)
