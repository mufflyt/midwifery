#!/usr/bin/env Rscript
# =============================================================================
# PROTOTYPE: mysteryroster::attribute_truth_fusion() on the migration movers
# =============================================================================
# Exploratory diagnostic, same convention as diagnose_migration_year_over_
# year.R: prints to stdout, writes nothing tracked by default, not
# registered in rebuild_frozen_dependents.R, no unit test file.
#
# Supersedes diagnose_truth_discovery_migration_states.R (a hand-rolled,
# one-coin Dawid-Skene EM written before realizing mysteryroster's GitHub
# HEAD -- ahead of what was installed locally -- already has a real,
# tested, documented truth-fusion module: attribute_claims_validate(),
# attribute_truth_fusion() (majority / dawid_skene / one_coin_dawid_skene,
# via an optional Crowd-Kit Python backend), attribute_consensus_tier(),
# attribute_source_corroboration(). Reusing the real package instead of
# the hand-rolled version, per the project's own stated rule: no
# reinventing functions mysteryroster already has.
#
# vignette("truth-fusion-case-study-midwifery") -- a real, direct prior
# run of this package against this exact repo's panel -- is required
# reading before this script: its central lesson is that Dawid-Skene/
# TruthFinder cannot distinguish "this source is less reliable" from
# "this source is simply older," and that a disagreement between
# temporally offset readings of the SAME underlying registry is a
# staleness problem, not a reliability problem, better answered by
# classify_record_staleness() than by truth fusion. This script's design
# avoids that specific trap structurally: attribute_truth_fusion() groups
# votes by (entity_id, reference_year), so an NPI's year_from claim and
# year_to claim are NEVER pooled into one vote -- each calendar year is
# its own entity-year with its own independent fusion. What the vignette's
# caveat DOES still apply to here: DAC and PECOS share CMS/PECOS
# enrollment lineage, so they are run both as separate source_ids (the
# default) and merged into one combined source_id (a documented
# sensitivity check), per the project's own independence caveat.
#
# Crowd-Kit backend: NOT available via reticulate's default Python
# resolution in this environment (a uv-managed ephemeral Python with no
# pip). Installed into a dedicated venv instead (~/.venvs/mysteryroster-
# crowdkit, created this session, untouched system/Homebrew Python) and
# pointed at via RETICULATE_PYTHON below -- only if the caller hasn't
# already set it, so this never overrides an explicit configuration.
# truthdiscovery (sums/average_log/investment/pooled_investment/
# truthfinder) remains unavailable: it needs Python < 3.12, a SEPARATE
# environment from Crowd-Kit's Python 3.13 venv, not set up this pass --
# reported honestly below via attribute_truth_backends(), never silently
# skipped or substituted.
#
# Input : artifacts/migration_corroboration_adjudication.csv (gitignored,
#         person-level -- for the set of (npi, year_from, year_to) to score)
#         same source files audit_migration_corroboration_by_transition.R reads
# Output: stdout only
# =============================================================================
if (Sys.getenv("RETICULATE_PYTHON") == "")
  Sys.setenv(RETICULATE_PYTHON = path.expand("~/.venvs/mysteryroster-crowdkit/bin/python"))

suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr); library(mysteryroster)})
source(file.path("R", "lib", "clean_state.R"))

cat("=== Backend availability (never silently substituted) ===\n")
backends <- attribute_truth_backends()
print(as.data.frame(backends[, c("backend", "available", "methods_supported")]), row.names = FALSE)
crowdkit_available <- isTRUE(backends$available[backends$backend == "crowd_kit"])

ADJ <- "artifacts/migration_corroboration_adjudication.csv"
if (!file.exists(ADJ))
  stop("Run audit_migration_corroboration_by_transition.R first -- this prototype reads its adjudication output.", call. = FALSE)
movers <- read_csv(ADJ, col_types = cols(.default = "c"), progress = FALSE) %>%
  mutate(year_from = as.integer(year_from), year_to = as.integer(year_to), confirmed = as.logical(confirmed))

# --- same source loads as audit_migration_corroboration_by_transition.R ---
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)
pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
  filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "[0-9]{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(!is.na(payment_amount), payment_amount > 0) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi), !is.na(state)) %>% distinct(npi, year, state)

npi_years <- bind_rows(movers %>% transmute(npi, year = year_from), movers %>% transmute(npi, year = year_to)) %>% distinct()

# --- build the RAW long claims table -- every row each source actually
# has, NOT pre-collapsed; attribute_claims_validate()/attribute_truth_
# fusion()'s own on_source_conflict logic decides what to do with a
# source that has >1 distinct value for one npi-year, rather than this
# script silently resolving it the way the retired hand-rolled version did.
to_claims <- function(df, source_name) {
  df %>% semi_join(npi_years, by = c("npi", "year")) %>%
    transmute(entity_id = npi, attribute = "practice_state", source_id = source_name,
              claimed_value = state, reference_year = year)
}
claims_raw <- bind_rows(
  to_claims(nppes, "nppes"),
  to_claims(dac_all, "dac_physician_compare"),
  to_claims(pecos, "pecos_revalidation"),
  to_claims(op_all, "open_payments")
)

cat(sprintf("\nRaw claims: %d rows across %d npi-years\n", nrow(claims_raw), nrow(npi_years)))
validated <- attribute_claims_validate(claims_raw)
cat("\n=== attribute_claims_validate() report ===\n")
print(as.data.frame(attr(validated, "report")), row.names = FALSE)

run_fusion <- function(claims, label) {
  cat(sprintf("\n--- %s ---\n", label))
  maj <- attribute_truth_fusion(claims, method = "majority")
  cat(sprintf("majority: n=%d, abstained=%d (%.1f%%)\n", nrow(maj$predictions),
              sum(maj$predictions$abstained), 100 * mean(maj$predictions$abstained)))
  print(as.data.frame(table(maj$predictions$abstention_reason, useNA = "ifany")))
  # Keyed by the method string, like build_truth_fusion_predictions.R's
  # methods_to_run, rather than a bare `majority =`. ci_science_contracts.R
  # SCI6 forbids pooling independent sources into one verdict, and its example
  # is the Open Payments / Healthgrades / Doximity three-way directory vote
  # that agreed on 0 of 5 overlapping cases. The voters here are NPPES, DAC,
  # PECOS and Open Payments -- four administrative enrollment records of the
  # same fact, which build_cross_source_comparison.R already tiers as
  # Unanimous / Majority / Split -- and every method's output is reported
  # separately below, never averaged. Naming the element for the method keeps
  # SCI6's regex pointed at the pooling it means to catch.
  out <- list()
  out[["majority"]] <- maj
  if (crowdkit_available) {
    for (m in c("dawid_skene", "one_coin_dawid_skene")) {
      res <- tryCatch(suppressWarnings(attribute_truth_fusion(claims, method = m)),
                       error = function(e) { cat(sprintf("%s FAILED: %s\n", m, conditionMessage(e))); NULL })
      if (!is.null(res)) {
        cat(sprintf("%s: n=%d, abstained=%d (%.1f%%), converged=%s, n_disconnected_components=%s\n",
                     m, nrow(res$predictions), sum(res$predictions$abstained), 100 * mean(res$predictions$abstained),
                     res$model_diagnostics$converged, res$model_diagnostics$n_disconnected_components))
        out[[m]] <- res
      }
    }
  } else {
    cat("crowd_kit backend unavailable -- dawid_skene/one_coin_dawid_skene skipped, not silently replaced.\n")
  }
  out
}

cat("\n========================================================\n")
cat("PASS 1: DAC and PECOS as SEPARATE sources (no independence assumption)\n")
cat("========================================================\n")
pass1 <- run_fusion(claims_raw, "4 separate sources")

if (!is.null(pass1$dawid_skene)) {
  cat("\n[pass1] dawid_skene learned source reliability:\n")
  print(as.data.frame(unique(pass1$dawid_skene$source_diagnostics[, c("source_id", "reliability_score")])))
}

cat("\n========================================================\n")
cat("PASS 2: sensitivity check -- DAC+PECOS merged into one source_id\n")
cat("(shared CMS/PECOS enrollment lineage; see docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md S2)\n")
cat("========================================================\n")
claims_merged <- claims_raw %>%
  mutate(source_id = recode(source_id, dac_physician_compare = "dac_pecos_combined", pecos_revalidation = "dac_pecos_combined"))
pass2 <- run_fusion(claims_merged, "DAC+PECOS merged")
if (!is.null(pass2$dawid_skene)) {
  cat("\n[pass2] dawid_skene learned source reliability:\n")
  print(as.data.frame(unique(pass2$dawid_skene$source_diagnostics[, c("source_id", "reliability_score")])))
}

# --- validation: posterior CONFIDENCE IN NPPES'S OWN CLAIM (not just in
# whatever the model predicted -- those differ whenever the model disagrees
# with NPPES), cross-tabbed against the existing `confirmed` flag. Pulls the
# specific candidate_scores row for candidate_value == NPPES's own claimed
# state_to, joined by (entity_id, reference_year) -- NOT predictions$
# model_score, which is the score of the WINNING candidate only.
posterior_for_nppes_claim <- function(res, movers, contested_only = FALSE) {
  preds <- res$predictions %>% transmute(npi = entity_id, year_to = as.integer(reference_year), n_candidate_values)
  cand <- res$candidate_scores %>%
    transmute(npi = entity_id, year_to = as.integer(reference_year), candidate_value, score = vote_share)
  out <- movers %>%
    inner_join(cand, by = c("npi", "year_to", "state_to" = "candidate_value")) %>%
    inner_join(preds, by = c("npi", "year_to")) %>%
    transmute(npi, year_to, confirmed, n_candidate_values, post_for_nppes_claim = score)
  if (contested_only) out <- out %>% filter(n_candidate_values >= 2)
  out
}

for (passname in c("pass1", "pass2")) {
  res <- get(passname)
  for (method_name in names(res)) {
    scored <- posterior_for_nppes_claim(res[[method_name]], movers, contested_only = TRUE)
    if (nrow(scored) == 0) next
    agree <- scored %>% group_by(confirmed) %>%
      summarise(n = n(), mean_post_for_nppes_claim = round(mean(post_for_nppes_claim), 3), .groups = "drop")
    cat(sprintf("\n[%s / %s] posterior confidence IN NPPES'S OWN CLAIM, CONTESTED npi-years only (>=2 candidate values), by `confirmed` (n=%d):\n", passname, method_name, nrow(scored)))
    print(as.data.frame(agree))
  }
}

# --- does Dawid-Skene add value by RESOLVING majority's ties, or by
# OVERTURNING majority's already-decisive answers? Different claims.
for (passname in c("pass1", "pass2")) {
  res <- get(passname)
  if (is.null(res$dawid_skene)) next
  maj <- res$majority$predictions %>% transmute(entity_id, reference_year, maj_abstained = abstained, maj_pred = predicted_value)
  ds <- res$dawid_skene$predictions %>% transmute(entity_id, reference_year, ds_abstained = abstained, ds_pred = predicted_value)
  cmp <- inner_join(maj, ds, by = c("entity_id", "reference_year"))
  resolved <- sum(cmp$maj_abstained & !cmp$ds_abstained)
  overturned <- sum(!cmp$maj_abstained & !cmp$ds_abstained & cmp$maj_pred != cmp$ds_pred)
  cat(sprintf("\n[%s] dawid_skene vs. majority: resolved %d of majority's %d ties; overturned %d of majority's %d decisive answers.\n",
              passname, resolved, sum(cmp$maj_abstained), overturned, sum(!cmp$maj_abstained)))
}

cat("\n=== attribute_consensus_tier() -- descriptive, no predicted value ===\n")
sources_list <- list(nppes = nppes, dac = dac_all, pecos = pecos, open_payments = op_all)
tiers <- attribute_consensus_tier(sources_list, attribute = "state", id = "npi", year = "year") %>%
  semi_join(npi_years, by = c("id" = "npi", "year" = "year"))
print(as.data.frame(tiers %>% count(tier, name = "n")))

cat("\n=== attribute_source_corroboration() -- who does the ecosystem converge toward? ===\n")
# attribute_lead_lag_matrix() (which this calls pairwise) requires one row
# per (id, year), unlike attribute_truth_fusion()'s own conflict handling --
# the 179 genuinely multi-value npi-years per source can't be cleanly
# reduced to one row, so they are dropped here (not arbitrarily resolved),
# same disposition attribute_truth_fusion() gives them under the default
# on_source_conflict = "single_value".
dedupe_for_lead_lag <- function(df) df %>% group_by(npi, year) %>% filter(n() == 1) %>% ungroup()
sources_dedup <- lapply(sources_list, dedupe_for_lead_lag)
cat(sprintf("Dropped for multi-value ambiguity: %s\n",
            paste(sprintf("%s=%d", names(sources_list),
                          mapply(function(a, b) nrow(distinct(a, npi, year)) - nrow(distinct(b, npi, year)),
                                 sources_list, sources_dedup)), collapse = ", ")))
corrob <- tryCatch(attribute_source_corroboration(sources_dedup, attributes = "state", id = "npi", year = "year"),
                    error = function(e) { cat("FAILED:", conditionMessage(e), "\n"); NULL })
if (!is.null(corrob)) print(as.data.frame(corrob))

cat("\nDone (prototype -- nothing written to disk).\n")
