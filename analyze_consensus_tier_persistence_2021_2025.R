#!/usr/bin/env Rscript
# =============================================================================
# Does cross-source disagreement persist, or resolve? -- 2021-2025
# =============================================================================
# REPLACEMENT, NOT A REPRODUCTION. The 2026-11-04 vignette reported that among
# 184 midwives with NPPES, DAC, Open Payments and PECOS all present in every
# year 2021-2025, roughly 165-169 stayed unanimous across every transition.
# That run CANNOT be reproduced: it read per-year Open Payments cohort files
# (artifacts/cohort_midwives_open_payments_general_<year>.csv) which are
# gitignored (.gitignore:660), were never committed, and no longer exist on
# this machine except for 2024. Re-running build_cross_source_comparison.R
# with one Open Payments year available yields a four-source-complete cohort
# of ZERO, which is a missing input, not a finding.
#
# This script answers the same question from the reconstructed Open Payments
# series built in November 2026 (artifacts/open_payments_midwife_presence_by_year.csv,
# 2013-2025), which carries a state per NPI-year and is tracked. Its estimates
# are NOT comparable to the published ones and must never be presented as a
# reproduction of them: the Open Payments input is a different extract, and
# its per-year cohort will differ in both size and membership.
#
# WHAT IS HELD IDENTICAL to the original design, so the comparison is as close
# as the inputs allow: the same four sources, the same 2021-2025 window, the
# same requirement that all four report a state in a given NPI-year, the same
# requirement that an NPI be four-source-complete in EVERY year before it
# enters the flow, and the same unanimous/majority/split rule on four votes.
#
# Inputs : midwife_panel.csv (NPPES)
#          artifacts/physician_compare_historical_midwives.csv (DAC)
#          artifacts/open_payments_midwife_presence_by_year.csv (Open Payments)
#          artifacts/pecos_revalidation_cohort_state_by_year.csv (PECOS)
# Outputs: artifacts/consensus_tier_persistence_2021_2025.csv        (transitions)
#          artifacts/consensus_tier_persistence_2021_2025_cohort.csv (tier by year)
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr); library(tidyr) })
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "clean_state.R"))

YEARS <- 2021:2025
NPPES <- "midwife_panel.csv"
DAC   <- "artifacts/physician_compare_historical_midwives.csv"
OP    <- "artifacts/open_payments_midwife_presence_by_year.csv"
PECOS <- "artifacts/pecos_revalidation_cohort_state_by_year.csv"
OUT_FLOW   <- "artifacts/consensus_tier_persistence_2021_2025.csv"
OUT_COHORT <- "artifacts/consensus_tier_persistence_2021_2025_cohort.csv"

for (f in c(NPPES, DAC, OP, PECOS))
  if (!file.exists(f)) stop(sprintf("missing input: %s", f), call. = FALSE)

cc <- cols(.default = "c")
nppes <- read_csv(NPPES, col_types = cc, progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year),
            state = clean_state(practice_state), source = "nppes")
dac <- read_csv(DAC, col_types = cc, progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)),
            state = clean_state(practice_state), source = "dac")
# The reconstructed series. usable_for_trend is NOT filtered here: that flag
# marks years before CNMs became Open Payments reportable (program year 2021),
# and this window starts at 2021, so every row in scope is already reportable.
op <- read_csv(OP, col_types = cc, progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(program_year),
            state = clean_state(state), source = "open_payments")
pecos <- read_csv(PECOS, col_types = cc, progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year),
            state = clean_state(pecos_state), source = "pecos")

long <- bind_rows(nppes, dac, op, pecos) %>%
  filter(year %in% YEARS, !is.na(npi), nzchar(npi), !is.na(state)) %>%
  arrange(npi, year, source, state) %>%
  distinct(npi, year, source, .keep_all = TRUE)

for (s in c("nppes", "dac", "open_payments", "pecos")) {
  yy <- sort(unique(long$year[long$source == s]))
  cat(sprintf("%-14s years in window: %s\n", s, paste(yy, collapse = ", ")))
  if (!length(yy)) stop(sprintf("source %s contributes no year in %d-%d", s, min(YEARS), max(YEARS)), call. = FALSE)
}

tiers <- long %>%
  group_by(npi, year) %>%
  filter(n() == 4) %>%
  summarise(n_agree_majority = max(table(state)), .groups = "drop") %>%
  mutate(tier = case_when(n_agree_majority == 4 ~ "Unanimous",
                          n_agree_majority == 3 ~ "Majority",
                          TRUE                  ~ "Split"))

complete <- tiers %>% count(npi) %>% filter(n == length(YEARS)) %>% pull(npi)
coh <- tiers %>% filter(npi %in% complete)
cat(sprintf("\nfour-source-complete NPI-years: %s\n", format(nrow(tiers), big.mark = ",")))
cat(sprintf("NPIs complete in all %d years:   %s   <- the cohort\n",
            length(YEARS), format(length(complete), big.mark = ",")))

# A cohort of zero means an input is missing, not that nobody qualifies. Fail
# loudly rather than writing an empty artifact that reads like a result -- the
# exact failure mode that let the original run's emptiness go unnoticed.
if (!length(complete))
  stop("four-source-complete cohort is empty across all five years; an input is missing", call. = FALSE)

by_year <- coh %>% count(year, tier, name = "n") %>%
  group_by(year) %>% mutate(pct = 100 * n / sum(n)) %>% ungroup()
cat("\n-- tier by year --\n"); print(as.data.frame(by_year), row.names = FALSE, digits = 4)

flow <- bind_rows(lapply(seq_len(length(YEARS) - 1), function(k) {
  y1 <- YEARS[k]; y2 <- YEARS[k + 1]
  inner_join(coh %>% filter(year == y1) %>% select(npi, tier1 = tier),
             coh %>% filter(year == y2) %>% select(npi, tier2 = tier),
             by = "npi") %>%
    count(tier1, tier2, name = "n") %>% mutate(year_from = y1, year_to = y2)
})) %>% select(year_from, year_to, tier1, tier2, n) %>% arrange(year_from, tier1, tier2)

stable <- flow %>% group_by(year_from, year_to) %>%
  summarise(n_pairs = sum(n),
            n_unanimous_to_unanimous = sum(n[tier1 == "Unanimous" & tier2 == "Unanimous"]),
            n_same_tier = sum(n[tier1 == tier2]), .groups = "drop") %>%
  mutate(pct_unanimous_persist = 100 * n_unanimous_to_unanimous / n_pairs,
         pct_same_tier         = 100 * n_same_tier / n_pairs)
cat("\n-- transitions --\n"); print(as.data.frame(stable), row.names = FALSE, digits = 4)

stopifnot(nrow(flow) > 0, all(stable$n_pairs == length(complete)))
write_with_provenance(flow, OUT_FLOW, inputs = c(NPPES, DAC, OP, PECOS), na = "")
write_with_provenance(by_year, OUT_COHORT, inputs = c(NPPES, DAC, OP, PECOS), na = "")
cat(sprintf("\nwrote %s and %s\n", OUT_FLOW, OUT_COHORT))
