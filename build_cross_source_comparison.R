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
# MEDICAID IS NOW INCLUDED, AND THE GAP THAT KEPT IT OUT IS CLOSED. This
# header used to read: "Medicaid is NOT included -- this audit's Medicaid
# source is a pre-built Concordant/Discordant/... classification
# (R/lib/medicaid_state_concordance.R), not raw per-NPI-year state values, so
# it cannot feed a pairwise state comparison or a consensus score without
# rebuilding it from T-MSIS enrollment intervals from scratch."
#
# HHS's DOGE team published those intervals on 2026-07-24 as Medicaid Provider
# Enrollment Segments (opendata.hhs.gov): 65,970,112 segments, 4,416,627 NPIs,
# 54 states, each row an NPI with a STATE_CD and dated start/end. No data-use
# agreement. That is the raw per-NPI-year state the gap was about. Measured on
# this cohort it reaches 9,901 NPIs in 2018 rising to 12,995 in 2024 (77.5%),
# which makes it the second-widest per-year state source in the audit after
# NPPES itself -- wider than PECOS, DAC or Open Payments.
#
# IT IS ALSO THE ONLY SOURCE THAT REFUSES TO NAME ONE STATE, and that is not a
# defect to be deduped away. Cohort midwives average 1.64 Medicaid states each
# in 2024. Asked "is she enrolled in the state CMS NDH lists?" Medicaid says
# yes 90.5% of the time, flat, whether she holds one state or five; asked "is
# her LARGEST Medicaid state that state?" the same records answer 33.4% at
# five states. Running her through dedupe_one_per_npi() -- slice(1), i.e.
# whichever row sorted first -- would pick one of several true answers at
# random and book the rest as disagreement.
#
# So Medicaid enters twice, under two names that cannot be confused:
#
#   medicaid_enrollment   the MODAL state (most segments; ties broken
#                         alphabetically so a rerun is reproducible). One
#                         state per NPI, so it joins the pairwise matrix and
#                         the consensus score on the same terms as every
#                         other source.
#   containment diagnostic  artifacts/cross_source_medicaid_containment.csv:
#                         for each other source, how often THAT source's state
#                         falls anywhere inside her Medicaid footprint. This
#                         is the number that does not collapse her, and the
#                         distance between the two is the finding, not noise.
#
# Medicaid is on an external volume, so unlike every other input here it is
# resolved through samsung_volume_path() and its absence SKIPS it loudly
# rather than killing a run that can still compare the other nine sources.
#
# 1. PAIRWISE MATRIX: every source's CURRENT state vs. every other source's
#    (not just vs. NPPES) -- artifacts/cross_source_pairwise_matrix.csv
# 1b. MEDICAID CONTAINMENT: for each other source, how often its state falls
#    anywhere in the midwife's Medicaid footprint, beside how often it equals
#    her modal Medicaid state -- artifacts/cross_source_medicaid_containment.csv
#    (written only when the Medicaid volume is mounted)
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
source(file.path("R", "lib", "medicare_duckdb.R"))  # samsung_volume_path(), duckdb_connect()
source(file.path("R", "lib", "wilson_interval.R"))  # wilson_ci()
source(file.path("R", "lib", "source_vintage.R"))     # source_vintage_table()

MEDICAID_SEGMENTS_REL <- file.path(
  "doge_opendata", "medicaid_provider_enrollment_segments_2026_07_24",
  "medicaid-provider-enrollment-segments.parquet")

#' Per-NPI Medicaid state footprint from the DOGE T-MSIS enrollment segments
#'
#' @param npis [character] the NPIs to keep. The published file covers
#'   4,416,627 providers and ~7M NPI-state pairs; pulling all of that into R
#'   to then inner-join it away made this the slowest step in the script by a
#'   wide margin. The filter and both aggregations now run in DuckDB and only
#'   the cohort's rows ever cross into R.
#' @return list with `modal` (one row per NPI: the state with the most
#'   segments, ties broken alphabetically so a rerun is identical) and
#'   `footprint` (every distinct NPI/state pair). NULL when the volume is
#'   not mounted.
load_medicaid_states <- function(npis) {
  path <- samsung_volume_path(MEDICAID_SEGMENTS_REL, must_exist = FALSE)
  if (is.na(path)) {
    cat(sprintf("Medicaid enrollment segments NOT FOUND under any %s* mount.\n",
                SAMSUNG_VOLUME_CANONICAL),
        "  Skipping Medicaid; the other nine sources are unaffected.\n",
        "  Expected:", MEDICAID_SEGMENTS_REL, "\n")
    return(NULL)
  }
  npis <- unique(trimws(npis[!is.na(npis) & nzchar(trimws(npis))]))
  if (!length(npis)) return(NULL)

  con <- duckdb_connect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "wanted_npis", data.frame(npi = npis), overwrite = TRUE)

  # STATE_CD is already a 2-letter postal code. clean_state() still decides
  # what a state is -- one normalizer for every source in this file -- but it
  # is applied to the handful of DISTINCT codes, not to millions of rows.
  pairs <- DBI::dbGetQuery(con, sprintf(
    "SELECT trim(s.NPI) AS npi, s.STATE_CD AS state, count(*) AS n_segments
       FROM read_parquet(%s) s
       JOIN wanted_npis w ON w.npi = trim(s.NPI)
      WHERE s.STATE_CD IS NOT NULL
      GROUP BY 1, 2", DBI::dbQuoteString(con, path)))
  if (!nrow(pairs)) return(NULL)

  lut <- tibble::tibble(state = unique(pairs$state)) %>%
    dplyr::mutate(clean = clean_state(state))
  pairs <- pairs %>%
    dplyr::inner_join(lut, by = "state") %>%
    dplyr::filter(!is.na(clean)) %>%
    dplyr::select(npi, state = clean, n_segments) %>%
    dplyr::group_by(npi, state) %>%
    dplyr::summarise(n_segments = sum(n_segments), .groups = "drop")

  modal <- pairs %>%
    dplyr::arrange(npi, dplyr::desc(n_segments), state) %>%
    dplyr::group_by(npi) %>% dplyr::slice(1) %>% dplyr::ungroup() %>%
    dplyr::select(npi, state)
  cat(sprintf("Medicaid enrollment segments: %s of %s requested NPIs, %s NPI-state pairs (%.2f states/NPI)\n",
              format(nrow(modal), big.mark = ","), format(length(npis), big.mark = ","),
              format(nrow(pairs), big.mark = ","), nrow(pairs) / max(nrow(modal), 1)))
  list(modal = modal, footprint = pairs %>% dplyr::select(npi, state))
}

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

# Every other source here is already cohort-scoped; Medicaid is national, so
# it is given the cohort explicitly rather than filtered after the fact.
medicaid <- load_medicaid_states(link$npi)

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
# Appended rather than placed inline so the nine pre-existing sources keep
# their order, and so a run without the volume produces the same matrix it
# always did rather than a differently-shaped one.
if (!is.null(medicaid)) current_states$medicaid_enrollment <- medicaid$modal
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
# EVERY PAIR CARRIES ITS VINTAGE GAP, because `filter(year == max(year))` above
# takes each source at ITS OWN newest release, and those land on different
# schedules. Freshest-per-source is not closest-to-each-other -- it is the
# opposite, since independently maximising each date maximises the spread. This
# matrix used to publish source_a, source_b and pct_agree with NO date column,
# so a pairing 15 months apart (facility_affiliation_ccn 2026-10-01 vs
# open_payments PY2025, centred 2025-07-02) appeared in the same units as one a
# month apart. Measured 2026-11-09: 10 of 21 datable pairs exceeded six months,
# median 4.3. The gap does not invalidate a comparison, but it has to travel
# WITH it -- a midwife can legitimately have moved in between, and a reader
# needs to see how much room there was for that.
#
# Sources whose vintage is not recorded anywhere (healthgrades, cms_ndh_fhir,
# state_boards_of_nursing) get NA, not a guess. See R/lib/source_vintage.R.
vint <- tryCatch(source_vintage_table(), error = function(e) {
  warning(sprintf("source_vintage_table() failed (%s); pairwise matrix will carry no vintages.",
                  conditionMessage(e)), call. = FALSE)
  NULL
})
pairwise_df <- bind_rows(pairwise) %>% arrange(source_a, source_b)
if (!is.null(vint)) {
  v <- vint %>% select(source, vintage_used)
  pairwise_df <- pairwise_df %>%
    left_join(v %>% rename(source_a = source, vintage_a = vintage_used), by = "source_a") %>%
    left_join(v %>% rename(source_b = source, vintage_b = vintage_used), by = "source_b") %>%
    mutate(vintage_gap_months = round(abs(vintage_gap_months(vintage_a, vintage_b)), 1))
  miss <- setdiff(unique(c(pairwise_df$source_a, pairwise_df$source_b)), v$source)
  if (length(miss))
    warning(sprintf(paste0("these compared sources are absent from source_vintage_table(), so ",
                           "their pairs carry no gap: %s.\n  Add them to the registry in ",
                           "R/lib/source_vintage.R rather than leaving the gap blank."),
                    paste(miss, collapse = ", ")), call. = FALSE)
  n_over <- sum(pairwise_df$vintage_gap_months > 6, na.rm = TRUE)
  cat(sprintf("Vintage gaps attached: %d/%d pairs dated, %d over 6 months, widest %.1f\n",
              sum(!is.na(pairwise_df$vintage_gap_months)), nrow(pairwise_df), n_over,
              suppressWarnings(max(pairwise_df$vintage_gap_months, na.rm = TRUE))))
}
write_csv(pairwise_df, "artifacts/cross_source_pairwise_matrix.csv", na = "")
cat(sprintf("Pairwise matrix: %d source pairs -> artifacts/cross_source_pairwise_matrix.csv\n", nrow(pairwise_df)))

# =============================================================================
# 1b. MEDICAID CONTAINMENT -- the comparison that does not collapse her
# =============================================================================
# Every number in the matrix above asks "do these two sources name the same
# state?". For a midwife enrolled in three state Medicaid programmes that
# question has no single right answer, and pct_agree against
# medicaid_enrollment is therefore a floor, not a measurement of error.
#
# This asks the other question: is the state the OTHER source names anywhere
# in her Medicaid footprint? Same NPIs, same day, no state discarded. Report
# both or neither -- the modal number alone reads as Medicaid disagreeing,
# which is precisely the misreading this file exists to prevent.
if (!is.null(medicaid)) {
  containment <- bind_rows(lapply(setdiff(names(current_states), "medicaid_enrollment"), function(s) {
    other <- current_states[[s]] %>% select(npi, state)
    comparable <- other %>% semi_join(distinct(medicaid$footprint, npi), by = "npi")
    hits <- comparable %>% inner_join(medicaid$footprint, by = c("npi", "state")) %>% distinct(npi)
    modal_hits <- comparable %>% inner_join(medicaid$modal, by = c("npi", "state")) %>% distinct(npi)
    tibble(source = s,
           n_comparable = nrow(comparable),
           n_in_medicaid_footprint = nrow(hits),
           pct_in_medicaid_footprint = if (nrow(comparable)) round(100 * nrow(hits) / nrow(comparable), 1) else NA_real_,
           n_equals_modal_state = nrow(modal_hits),
           pct_equals_modal_state = if (nrow(comparable)) round(100 * nrow(modal_hits) / nrow(comparable), 1) else NA_real_)
  })) %>% arrange(desc(n_comparable))
  # Written WITH a provenance sidecar because this one is tracked (contract A3
  # requires a sidecar on every tracked artifact). The other outputs of this
  # script are per-NPI and gitignored, so they keep plain write_csv.
  source(file.path("R", "lib", "artifact_provenance.R"))
  write_with_provenance(containment, "artifacts/cross_source_medicaid_containment.csv",
                        inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv",
                                   "artifacts/cms_ndh_midwives.csv"), na = "")
  cat("Medicaid containment (is the other source's state anywhere in her Medicaid footprint?):\n")
  print(as.data.frame(containment))
}

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
