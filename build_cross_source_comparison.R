#!/usr/bin/env Rscript
# =============================================================================
# Cross-source comparison beyond "vs. NPPES only" -- 4 analyses
# =============================================================================
# build_state_source_audit.R's design is a star: every source compared only
# against NPPES. That leaves real questions unanswered -- when DAC and PECOS
# disagree with NPPES, do they at least agree with EACH OTHER? Does
# disagreement persist for the same NPI year after year, or resolve? This
# script answers those using the same per-source state extracts (same
# filtering, same clean_state()), reloaded here rather than sourced, to keep
# this a self-contained script like every other extract_*.R in this repo.
#
# Medicaid is NOT included -- this audit's Medicaid source is a pre-built
# Concordant/Discordant/... classification (R/lib/medicaid_state_concordance.R),
# not raw per-NPI-year state values, so it cannot feed a pairwise state
# comparison or a consensus score without rebuilding it from T-MSIS
# enrollment intervals from scratch. Out of scope for this pass; the gap is
# real and stated here rather than silently dropped.
#
# 1. PAIRWISE MATRIX: every source's CURRENT state vs. every other source's
#    (not just vs. NPPES) -- artifacts/cross_source_pairwise_matrix.csv
# 2. CONSENSUS SCORE: for each cohort NPI with >=2 sources reporting a
#    current state, what fraction of those sources agree with the majority
#    -- artifacts/cross_source_consensus_scores.csv (NPI-level) and
#    artifacts/cross_source_consensus_distribution.csv (binned summary)
# 3. LONGITUDINAL CONSENSUS-TIER FLOW: for the 4 sources with a real
#    multi-year overlap (NPPES, DAC, Open Payments, PECOS -- 2021-2025),
#    classify each NPI-year as unanimous / majority / split across those 4
#    sources, then count year-over-year transitions between tiers --
#    artifacts/cross_source_consensus_tier_flow.csv
# 4. WILSON CONFIDENCE INTERVALS on every existing per-year per-source
#    agreement-vs-NPPES percentage (adds to, does not replace,
#    state_source_audit_agreement.csv) --
#    artifacts/state_source_audit_agreement_with_ci.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr)})

source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "wilson_interval.R"))  # wilson_ci()
dedupe_one_per_npi <- function(df) {
  df %>% filter(!is.na(npi), !is.na(state)) %>% group_by(npi) %>% slice(1) %>% ungroup()
}

# --- reload every source's state extract, same logic as build_state_source_audit.R ---
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi))

hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi))

op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "\\d{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi))

pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state))

fa <- read_csv("artifacts/dac_facility_affiliations.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), state = clean_state(state)) %>% dedupe_one_per_npi()

hg <- read_csv("healthgrades_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(hg_npi), state = clean_state(hg_state)) %>% dedupe_one_per_npi()

dox_raw <- read_csv("artifacts/doximity_public_matched.csv", col_types = cols(.default = "c"), progress = FALSE)
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(certification_number, npi = trimws(npi))
dox <- dox_raw %>% left_join(link, by = "certification_number", relationship = "many-to-one") %>%
  transmute(npi = trimws(npi), state = clean_state(state)) %>% dedupe_one_per_npi()

bon_files <- Sys.glob("artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv")
bon <- bind_rows(lapply(bon_files, function(f) read_csv(f, col_types = cols(.default = "c"), progress = FALSE))) %>%
  filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
  transmute(npi = trimws(npi), state = clean_state(live_bon_state)) %>% dedupe_one_per_npi()

ndh <- read_csv("artifacts/cms_ndh_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(toupper(ndh_found) %in% c("TRUE", "1")) %>%
  mutate(state = clean_state(str_match(ndh_addresses, "\\b([A-Z]{2})\\s+\\d{5}")[, 2])) %>%
  transmute(npi = trimws(npi), state) %>% dedupe_one_per_npi()

cat("Sources reloaded.\n")

# =============================================================================
# 1. PAIRWISE MATRIX -- each source's CURRENT (most recent available) state
# =============================================================================
current_states <- list(
  nppes                    = nppes %>% filter(year == max(year)) %>% dedupe_one_per_npi(),
  dac_physician_compare    = dac_all %>% filter(year == max(year)) %>% dedupe_one_per_npi(),
  open_payments            = op_all %>% filter(year == max(year)) %>% dedupe_one_per_npi(),
  pecos_revalidation       = pecos %>% filter(year == max(year)) %>% dedupe_one_per_npi(),
  facility_affiliation_ccn = fa,
  healthgrades              = hg,
  doximity                  = dox,
  state_boards_of_nursing  = bon,
  cms_ndh_fhir              = ndh
)
cat("Current-snapshot NPI counts: ", paste(sprintf("%s=%d", names(current_states), vapply(current_states, nrow, 1L)), collapse = ", "), "\n")

src_names <- names(current_states)
pairwise <- list()
for (i in seq_along(src_names)) {
  for (j in seq_along(src_names)) {
    if (j <= i) next
    a <- src_names[i]; b <- src_names[j]
    m <- inner_join(current_states[[a]] %>% rename(state_a = state),
                     current_states[[b]] %>% rename(state_b = state), by = "npi")
    pairwise[[paste(a, b)]] <- tibble(
      source_a = a, source_b = b, n_comparable = nrow(m),
      n_agree = sum(m$state_a == m$state_b),
      pct_agree = if (nrow(m)) round(100 * sum(m$state_a == m$state_b) / nrow(m), 1) else NA_real_)
  }
}
pairwise_df <- bind_rows(pairwise) %>% arrange(source_a, source_b)
write_csv(pairwise_df, "artifacts/cross_source_pairwise_matrix.csv")
cat(sprintf("Pairwise matrix: %d source pairs -> artifacts/cross_source_pairwise_matrix.csv\n", nrow(pairwise_df)))

# =============================================================================
# 2. CONSENSUS SCORE per NPI, current snapshot, sources with >=2 reporting
# =============================================================================
long_current <- bind_rows(lapply(src_names, function(s) current_states[[s]] %>% mutate(source = s) %>% select(npi, source, state)))
# Reports how OFTEN sources agree, never which state is "right" -- SCI6: Open
# Payments, Healthgrades and Doximity agreed on 0 of 5 overlapping cases, so a
# picked "majority_state" would assert a winner the sources themselves don't
# support. n_agree_with_largest_group is only ever used for the concordance
# rate, and the largest-group state value itself is never materialized.
agreement <- long_current %>%
  group_by(npi) %>%
  filter(n() >= 2) %>%
  mutate(n_reporting = n()) %>%
  group_by(npi, state) %>%
  mutate(n_for_this_state = n()) %>%
  group_by(npi) %>%
  summarise(n_reporting = first(n_reporting),
            n_sources_listed = paste(sort(unique(source)), collapse = "|"),
            n_distinct_states = n_distinct(state),
            n_agree_with_largest_group = max(n_for_this_state),
            .groups = "drop") %>%
  mutate(concordance_pct = round(100 * n_agree_with_largest_group / n_reporting, 1))
write_csv(agreement, "artifacts/cross_source_consensus_scores.csv")

dist <- agreement %>%
  mutate(tier = case_when(
    concordance_pct == 100 ~ "Unanimous (all sources agree)",
    concordance_pct >= 67  ~ "Agree (most sources agree)",
    TRUE                   ~ "Split (no agreeing majority)"
  )) %>%
  count(n_reporting, tier, name = "n_npis") %>%
  arrange(n_reporting, tier)
write_csv(dist, "artifacts/cross_source_consensus_distribution.csv")
overall <- agreement %>% mutate(tier = case_when(
    concordance_pct == 100 ~ "Unanimous", concordance_pct >= 67 ~ "Agree", TRUE ~ "Split")) %>%
  count(tier) %>% mutate(pct = round(100 * n / sum(n), 1))
cat("Agreement rate (all NPIs with >=2 current sources, n=", nrow(agreement), "):\n", sep = "")
print(as.data.frame(overall))
write_csv(overall, "artifacts/cross_source_consensus_overall.csv")

# =============================================================================
# 3. LONGITUDINAL CONSENSUS-TIER FLOW -- NPPES+DAC+OpenPayments+PECOS, 2021-2025
# =============================================================================
YEARS_4WAY <- 2021:2025
four_long <- bind_rows(
  nppes %>% filter(year %in% YEARS_4WAY) %>% mutate(source = "nppes"),
  dac_all %>% filter(year %in% YEARS_4WAY) %>% mutate(source = "dac"),
  op_all %>% filter(year %in% YEARS_4WAY) %>% mutate(source = "open_payments"),
  pecos %>% filter(year %in% YEARS_4WAY) %>% mutate(source = "pecos")
) %>% filter(!is.na(state)) %>%
  arrange(npi, year, source, state) %>%
  distinct(npi, year, source, .keep_all = TRUE)

tiers <- four_long %>%
  group_by(npi, year) %>%
  filter(n() == 4) %>%  # all 4 sources present that NPI-year
  mutate(n_for_state = ave(seq_along(state), state, FUN = length)) %>%
  summarise(n_agree_majority = max(table(state)), .groups = "drop") %>%
  mutate(tier = case_when(n_agree_majority == 4 ~ "Unanimous", n_agree_majority == 3 ~ "Majority", TRUE ~ "Split"))

cat(sprintf("4-source-complete NPI-years, 2021-2025: %s\n", format(nrow(tiers), big.mark = ",")))

# only NPIs present (4-source-complete) in ALL 5 years, so the flow tracks the same cohort
npi_complete_all_years <- tiers %>% count(npi) %>% filter(n == length(YEARS_4WAY)) %>% pull(npi)
tiers_cohort <- tiers %>% filter(npi %in% npi_complete_all_years)
cat(sprintf("NPIs with all 4 sources present in all 5 years (2021-2025): %s\n", format(length(npi_complete_all_years), big.mark = ",")))

flow <- list()
for (k in seq_len(length(YEARS_4WAY) - 1)) {
  y1 <- YEARS_4WAY[k]; y2 <- YEARS_4WAY[k + 1]
  t1 <- tiers_cohort %>% filter(year == y1) %>% select(npi, tier1 = tier)
  t2 <- tiers_cohort %>% filter(year == y2) %>% select(npi, tier2 = tier)
  j <- inner_join(t1, t2, by = "npi")
  flow[[k]] <- j %>% count(tier1, tier2, name = "n") %>% mutate(year_from = y1, year_to = y2)
}
flow_df <- bind_rows(flow) %>% select(year_from, year_to, tier1, tier2, n) %>% arrange(year_from, tier1, tier2)
write_csv(flow_df, "artifacts/cross_source_consensus_tier_flow.csv")
cat("Tier flow (year, tier) snapshot:\n")
print(as.data.frame(tiers_cohort %>% count(year, tier)))

# =============================================================================
# 4. WILSON CONFIDENCE INTERVALS on existing agreement-vs-NPPES percentages
# =============================================================================
agr <- read_csv("artifacts/state_source_audit_agreement.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(n_comparable = as.integer(n_comparable), n_agree = as.integer(n_agree), pct_agree = as.numeric(pct_agree))
ci <- wilson_ci(agr$n_agree, agr$n_comparable)
agr_ci <- bind_cols(agr, ci)
write_csv(agr_ci, "artifacts/state_source_audit_agreement_with_ci.csv")
cat("\nAgreement with 95% Wilson CI (widest and narrowest):\n")
print(as.data.frame(agr_ci %>% mutate(width = ci_high - ci_low) %>% arrange(desc(width)) %>% select(source, year, n_comparable, pct_agree, ci_low, ci_high) %>% head(5)))
print(as.data.frame(agr_ci %>% mutate(width = ci_high - ci_low) %>% arrange(width) %>% select(source, year, n_comparable, pct_agree, ci_low, ci_high) %>% head(5)))

cat("\nDone.\n")
