#!/usr/bin/env Rscript
# =============================================================================
# Full-cohort, full-panel (2013-2026) truth-fusion predictions via mysteryroster
# =============================================================================
# Builds one practice_state claim per cohort NPI-year per source: NPPES,
# DAC+PECOS combined (see R/lib/truth_fusion_claims.R for why DAC/PECOS are
# pre-merged rather than run as 2 separate, non-independent sources), Open
# Payments, T-MSIS Medicaid enrollment state (via extract_tmsis_medicaid_
# enrollment_state_history.R, added 2026-11-05 as the one genuinely new,
# independently-dated source a parallel mysteryroster-side audit
# identified -- run that extraction script first), and facility/hospital
# affiliation via NPI-CCN linkage (artifacts/dac_facility_affiliations.csv,
# added 2026-11-05 -- a CCN is a real physical facility with a real state,
# so a single current (2026) snapshot is still one real year's evidence,
# not nothing; it is dated 2026-only and never extrapolated backward,
# unlike this build's first draft which excluded it entirely on the
# mistaken premise that "single snapshot" meant "no usable information").
# Runs every mysteryroster::attribute_truth_fusion()
# method whose backend is actually available THIS invocation, writing one
# gitignored person-level prediction CSV per method plus a tracked model-
# diagnostics summary row per method.
#
# CANNOT run all 6 methods in one process: majority and the Crowd-Kit
# methods (dawid_skene, one_coin_dawid_skene) need Python >=3.13 with
# crowd-kit installed; the truthdiscovery methods (sums, average_log,
# investment, pooled_investment, truthfinder) need Python <3.12 (their
# last release predates distutils' removal) -- reticulate binds one Python
# per R process, so these are two genuinely incompatible environments.
# Run this script TWICE, once per venv (both created this session, neither
# touching system/Homebrew Python):
#
#   RETICULATE_PYTHON=~/.venvs/mysteryroster-crowdkit/bin/python \
#     Rscript build_truth_fusion_predictions.R
#   RETICULATE_PYTHON=~/.venvs/mysteryroster-truthdiscovery/bin/python \
#     Rscript build_truth_fusion_predictions.R
#
# Each run detects what's available via attribute_truth_backends() and
# only computes those methods -- majority is cheap enough to just
# recompute both times rather than add cross-run bookkeeping to skip it.
# Nothing is silently skipped without saying so.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv, midwife_panel.csv,
#          artifacts/physician_compare_historical_midwives.csv, dac_midwives.csv,
#          artifacts/pecos_revalidation_cohort_state_by_year.csv,
#          artifacts/cohort_midwives_open_payments_general_*.csv,
#          artifacts/tmsis_medicaid_enrollment_state_by_year.csv,
#          artifacts/dac_facility_affiliations.csv
# Outputs: artifacts/truth_fusion_predictions_<method>.csv (person-level, gitignored)
#          artifacts/truth_fusion_model_diagnostics.csv (appended across
#            runs, keyed by method; gitignored until a complete run emits it
#            with its provenance sidecar -- see .gitignore for why)
#          artifacts/truth_fusion_claims.csv (person-level, gitignored,
#            method-independent; added 2026-11-06 for
#            classify_migration_moves_full_panel.R)
#          artifacts/truth_fusion_candidate_scores_<method>.csv (person-
#            level, gitignored, per-candidate-value vote breakdown; added
#            2026-11-06, same consumer)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(mysteryroster)})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "truth_fusion_claims.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

t0 <- Sys.time()

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()

nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(snapshot_year), state = clean_state(practice_state)) %>%
  filter(!is.na(npi), nzchar(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
hist_dac <- read_csv("artifacts/physician_compare_historical_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(substr(vintage, 1, 4)), state = clean_state(practice_state))
cur_dac <- read_csv("dac_midwives.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(practice_state))
dac_all <- bind_rows(hist_dac, cur_dac) %>% filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
pecos <- read_csv("artifacts/pecos_revalidation_cohort_state_by_year.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(pecos_state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
op_all <- bind_rows(lapply(op_files, function(f) {
  yr <- as.integer(str_extract(f, "[0-9]{4}"))
  read_csv(f, col_types = cols(.default = "c"), progress = FALSE) %>%
    mutate(payment_amount = suppressWarnings(as.numeric(payment_amount))) %>%
    filter(!is.na(payment_amount), payment_amount > 0) %>%
    transmute(npi = trimws(npi), year = yr, state = clean_state(recipient_state))
})) %>% filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
# Facility/hospital affiliation (NPI-CCN linkage) DOES carry real location
# information -- a CCN is a specific physical facility with a real state --
# the earlier exclusion from this build was wrong to treat "single
# snapshot" as "no information" rather than "one year's worth of real
# information." Dated to 2026 (this extraction's own vintage), matching
# every other single-snapshot source already in this repo's convention
# (Healthgrades, Doximity, state boards, CMS NDH all get year = 2026L in
# build_cross_source_comparison.R/build_state_source_pairwise_audit.R) --
# a real claim for that one year, never extrapolated to years it wasn't
# observed in.
facility_affiliation <- read_csv("artifacts/dac_facility_affiliations.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = 2026L, state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)
TMSIS_PATH <- "artifacts/tmsis_medicaid_enrollment_state_by_year.csv"
if (!file.exists(TMSIS_PATH))
  stop(sprintf("%s not found -- run extract_tmsis_medicaid_enrollment_state_history.R first.", TMSIS_PATH), call. = FALSE)
tmsis_medicaid <- read_csv(TMSIS_PATH, col_types = cols(.default = "c"), progress = FALSE) %>%
  transmute(npi = trimws(npi), year = as.integer(year), state = clean_state(state)) %>%
  filter(!is.na(npi), !is.na(state), npi %in% link$npi) %>% distinct(npi, year, state)

dac_pecos_combined <- merge_dac_pecos_sources(dac_all, pecos)
cat(sprintf("Full-cohort sources: NPPES %s npi-years, DAC+PECOS combined %s, Open Payments %s, T-MSIS Medicaid enrollment %s, facility affiliation (2026 only) %s\n",
            format(nrow(nppes), big.mark = ","), format(nrow(dac_pecos_combined), big.mark = ","),
            format(nrow(op_all), big.mark = ","), format(nrow(tmsis_medicaid), big.mark = ","), format(nrow(facility_affiliation), big.mark = ",")))

claims <- build_truth_fusion_claims(
  list(nppes = nppes, dac_pecos_combined = dac_pecos_combined, open_payments = op_all,
       tmsis_medicaid = tmsis_medicaid, facility_affiliation = facility_affiliation),
  npi_filter = link$npi
)
cat(sprintf("Claims built: %d rows, %d distinct npi-years\n", nrow(claims), nrow(distinct(claims, entity_id, reference_year))))
# Persisted 2026-11-06 for classify_migration_moves_full_panel.R -- method-
# independent (build_truth_fusion_claims() output doesn't vary by method),
# so written once here rather than inside the per-method loop below.
write_with_provenance(claims, "artifacts/truth_fusion_claims.csv",
                       inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv", op_files))

validated <- attribute_claims_validate(claims)
cat("\n=== attribute_claims_validate() report ===\n")
print(as.data.frame(attr(validated, "report")), row.names = FALSE)

backends <- attribute_truth_backends()
cat("\n=== Backend availability this run ===\n")
print(as.data.frame(backends[, c("backend", "available", "methods_supported")]), row.names = FALSE)

methods_to_run <- c("majority")
if (isTRUE(backends$available[backends$backend == "crowd_kit"]))
  methods_to_run <- c(methods_to_run, "dawid_skene", "one_coin_dawid_skene")
if (isTRUE(backends$available[backends$backend == "truthdiscovery"]))
  methods_to_run <- c(methods_to_run, "sums", "average_log", "investment", "pooled_investment", "truthfinder")
cat(sprintf("\nMethods to run this invocation: %s\n", paste(methods_to_run, collapse = ", ")))

diag_rows <- list()
for (m in methods_to_run) {
  cat(sprintf("\n--- %s ---\n", m))
  t1 <- Sys.time()
  res <- tryCatch(suppressWarnings(attribute_truth_fusion(claims, method = m)),
                   error = function(e) { cat(sprintf("%s FAILED: %s\n", m, conditionMessage(e))); NULL })
  if (is.null(res)) next
  elapsed <- as.numeric(difftime(Sys.time(), t1, units = "secs"))
  pred_out <- res$predictions %>% transmute(npi = entity_id, year = as.integer(reference_year),
                                             predicted_value, model_score, score_type, n_sources, n_candidate_values, abstained, abstention_reason)
  out_path <- sprintf("artifacts/truth_fusion_predictions_%s.csv", m)
  write_with_provenance(pred_out, out_path, inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv", op_files))
  cat(sprintf("%s: n=%d, abstained=%d (%.1f%%), elapsed=%.1fs -> %s\n",
              m, nrow(pred_out), sum(pred_out$abstained), 100 * mean(pred_out$abstained), elapsed, out_path))
  # Persisted 2026-11-06 for classify_migration_moves_full_panel.R -- the
  # per-candidate-value vote breakdown attribute_truth_fusion() already
  # computes every run, previously discarded once pred_out was extracted.
  cscores_path <- sprintf("artifacts/truth_fusion_candidate_scores_%s.csv", m)
  write_with_provenance(res$candidate_scores, cscores_path,
                         inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv", "midwife_panel.csv", op_files))
  md <- res$model_diagnostics
  diag_rows[[m]] <- tibble::tibble(
    method = m, n_entity_years = nrow(pred_out), n_abstained = sum(pred_out$abstained),
    pct_abstained = round(100 * mean(pred_out$abstained), 2),
    converged = if ("converged" %in% names(md)) as.character(md$converged) else NA_character_,
    n_disconnected_components = if ("n_disconnected_components" %in% names(md)) md$n_disconnected_components else NA_integer_,
    elapsed_sec = round(elapsed, 1), run_at = as.character(Sys.time())
  )
}

if (length(diag_rows) > 0) {
  new_diag <- bind_rows(diag_rows)
  diag_path <- "artifacts/truth_fusion_model_diagnostics.csv"
  existing <- if (file.exists(diag_path)) read_csv(diag_path, col_types = cols(.default = "c"), progress = FALSE) else NULL
  if (!is.null(existing)) existing <- existing %>% filter(!(method %in% new_diag$method))
  combined <- bind_rows(existing, new_diag %>% mutate(across(everything(), as.character)))
  # Through the provenance writer like every other artifact here: this one is
  # TRACKED, so without a sidecar the committed diagnostics name no inputs and
  # ci_artifact_contracts.R A3 refuses it. Same inputs as the per-method
  # predictions it summarises.
  write_with_provenance(combined, diag_path,
                        inputs = c("artifacts/amcb_npi_linkage_FROZEN.csv",
                                   "midwife_panel.csv", op_files))
  cat(sprintf("\nModel diagnostics (tracked) -> %s (%d methods total on record)\n", diag_path, nrow(combined)))
}

cat(sprintf("\nTotal elapsed: %.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
cat("Done.\n")
