#!/usr/bin/env Rscript
# =============================================================================
# State-level data-quality variation figures (Supplemental Figures S6, S7)
# =============================================================================
# Two displays adopted from the directory-consistency literature, which
# reports marked state-to-state variation in record quality (Butala 2024,
# BMC Health Serv Res 24:808):
#
#   1. medicaid_npi_population_by_state -- the share of public Medicaid
#      enrollment segments carrying a provider NPI, by state. Identifiability
#      in this source is itself a state-varying data property: Oregon and New
#      Mexico submit no NPI-bearing segment at all.
#   2. state_variation_agreement_by_source -- practice-state agreement with
#      the national provider registry, stratified by the registry's state,
#      for each longitudinal source. The two states whose Medicaid file
#      carries no NPIs are drawn as open triangles: the 0% there measures
#      absence of an identifiable record, not address disagreement.
#
# Inputs : artifacts/medicaid_npi_population_by_state.csv
#          artifacts/state_variation_agreement_by_source.csv
# Outputs: docs/figures/medicaid_npi_population_by_state.{png,pdf,svg}
#          docs/figures/state_variation_agreement_by_source.{png,pdf,svg}
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(readr)
})
source(file.path("R", "lib", "audit_figure_style.R"))

MIN_N <- 30L
SOURCE_LABEL <- c(
  medicaid_enrollment = "Medicaid enrollment",
  medicare_claims     = "Medicare Part B/D claims",
  open_payments       = "Open Payments",
  pecos_revalidation  = "Medicare enrollment revalidation")

# ---- Figure S6: NPI-population rate -----------------------------------------
pop <- read_csv("artifacts/medicaid_npi_population_by_state.csv",
                col_types = cols(), progress = FALSE) %>%
  mutate(state = reorder(state, pct_segments_with_npi))

p6 <- ggplot(pop, aes(x = pct_segments_with_npi, y = state)) +
  geom_segment(aes(x = 0, xend = pct_segments_with_npi, yend = state),
               linewidth = 0.25, colour = "grey70") +
  geom_point(size = 1.6, colour = AUDIT_SERIES[1]) +
  scale_x_continuous(limits = c(0, 100),
                     labels = function(v) paste0(v, "%")) +
  labs(
    title = "Identifiability in the public Medicaid enrollment file varies by state",
    subtitle = paste0("Share of enrollment segments carrying a provider NPI, by ",
                      "enrolling state. Oregon and New Mexico submit no NPI-bearing\n",
                      "segment at all; a provider enrolled only there is unobservable ",
                      "in this source."),
    x = "Enrollment segments carrying an NPI", y = NULL,
    caption = "Whole released file (July 2026 snapshot), not only cohort-linked records.")
save_audit_fig(p6, "medicaid_npi_population_by_state", height = 9.0)

# ---- Figure S7: agreement with the registry, by registry state --------------
ag <- read_csv("artifacts/state_variation_agreement_by_source.csv",
               col_types = cols(), progress = FALSE) %>%
  mutate(source = factor(source, levels = names(SOURCE_LABEL),
                         labels = unname(SOURCE_LABEL)),
         unmeasurable = source == "Medicaid enrollment" &
           registry_state %in% c("NM", "OR"))

state_order <- ag %>%
  group_by(registry_state) %>%
  summarise(m = median(pct_agree), .groups = "drop") %>%
  arrange(m) %>% pull(registry_state)
ag <- ag %>% mutate(registry_state = factor(registry_state, levels = state_order))

p7 <- ggplot(ag, aes(x = pct_agree, y = registry_state, colour = source)) +
  geom_point(data = filter(ag, !unmeasurable),
             position = position_dodge(width = 0.55), size = 1.5) +
  geom_point(data = filter(ag, unmeasurable),
             position = position_dodge(width = 0.55), size = 1.8,
             shape = 2, stroke = 1) +
  scale_colour_manual(values = AUDIT_SERIES[1:4], name = NULL) +
  scale_x_continuous(limits = c(0, 100),
                     labels = function(v) paste0(v, "%")) +
  labs(
    title = "Practice-state agreement with the provider registry varies by state",
    subtitle = paste0("Share of comparable provider-years whose source-recorded state ",
                      "equals the registry's state, stratified by the registry\n",
                      "state (states with >= 30 comparable provider-years per source). ",
                      "Open triangles mark Oregon and New Mexico, where the Medicaid\n",
                      "file carries no NPI-bearing segment and 'agreement' measures ",
                      "only cross-border records."),
    x = "Provider-years agreeing with the registry state", y = "Registry practice state",
    caption = "State-level agreement does not establish accuracy: the registry state is the stratifier, not the truth.")
save_audit_fig(p7, "state_variation_agreement_by_source", height = 9.5)
