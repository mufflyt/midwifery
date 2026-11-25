#!/usr/bin/env Rscript
# =============================================================================
# Independent statistical audit of the federal database agreement study
# (Devin Task 2). Recomputes headline quantities DIRECTLY from source
# artifacts -- never through manuscript/R/build_stats_catalog.R -- and
# compares them against the published artifacts with explicit tolerances.
#
# Outputs:
#   review/federal_agreement_denominators.csv  one row per recomputation
#   review/federal_agreement_audit_numbers.md machine-readable summary
#
# Run from the repository root:  Rscript review/build_federal_agreement_audit.R
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tidyr)
})

ART <- "artifacts"
OUT <- "review"

canon <- read_csv(file.path(ART, "canonical_source_records.csv"),
                  show_col_types = FALSE, progress = FALSE) %>%
  filter(!is.na(state), nzchar(state))

results <- list()
add <- function(id, quantity, unit, independent, published, artifact,
                tolerance, note = "") {
  results[[length(results) + 1]] <<- data.frame(
    check_id = id, quantity = quantity, unit = unit,
    independent_value = independent, published_value = published,
    artifact = artifact, abs_tolerance = tolerance,
    delta = independent - published,
    status = if (is.na(tolerance)) "INFO" else
      if (is.na(independent) || is.na(published)) "MISSING" else
      ifelse(abs(independent - published) <= tolerance, "MATCH", "MISMATCH"),
    note = note, stringsAsFactors = FALSE)
}

# --- A1. Medicaid multistate, any-time-in-year (classification artifact) ---
cls <- read_csv(file.path(ART, "state_source_audit_medicaid_classification_by_year.csv"),
                show_col_types = FALSE, progress = FALSE)
ms_n <- sum(cls$n[grepl("^Multistate", cls$classification)])
obs_n <- sum(cls$n[cls$classification != "Not observed"])
ms_rate <- 100 * ms_n / obs_n
pub <- read_csv(file.path(ART, "medicaid_enrollment_concordance_any_time_by_year.csv"),
                show_col_types = FALSE, progress = FALSE)
ms2 <- sum(pub$n[grepl("^Multistate", pub$classification)])
obs2 <- sum(pub$n[pub$classification != "Not observed"])
add("A1a", "multistate share of observed Medicaid provider-years (any-time)",
    "percent", ms_rate, 100 * ms2 / obs2,
    "state_source_audit_medicaid_classification_by_year.csv vs medicaid_enrollment_concordance_any_time_by_year.csv",
    0.01, "two artifacts describing the same universe must agree exactly")

# Footprint estimand (all Medicaid-evidenced NPI-years) -- different universe,
# reported for the denominator audit, not as a mismatch.
fp <- read_csv(file.path(ART, "medicaid_enrollment_cohort_state_footprint.csv"),
               show_col_types = FALSE, progress = FALSE)
fp_ms <- fp %>% distinct(npi, year, state) %>%
  group_by(npi, year) %>% summarise(n_states = n_distinct(state), .groups = "drop") %>%
  summarise(ms = mean(n_states > 1))
add("A1b", "multistate share, footprint universe (all Medicaid-evidenced NPI-years)",
    "percent", 100 * fp_ms$ms, NA_real_, "medicaid_enrollment_cohort_state_footprint.csv",
    NA_real_, "different estimand from A1a; not a mismatch -- see audit doc")

# --- A2. NPPES-vs-PECOS practice-state agreement, independently ------------
# Recompute for the most recent common year straight from canonical records.
# (DAC and the commercial directories are not canonical sources; PECOS is.)
pw <- read_csv(file.path(ART, "state_source_audit_pairwise_agreement.csv"),
              show_col_types = FALSE, progress = FALSE)
comp_year <- max(pw$year[pw$source_a == "nppes" & pw$source_b == "pecos_revalidation"],
                 na.rm = TRUE)
sub <- canon %>% filter(source %in% c("nppes", "pecos_revalidation"),
                        year == comp_year)
wide <- sub %>% select(npi, source, state) %>% distinct() %>%
  tidyr::pivot_wider(names_from = source, values_from = state,
                     values_fn = function(x) paste(sort(unique(x)), collapse = ";"))
# Only single-valued cells on both sides are comparable under the equality rule.
wv <- wide %>% filter(!is.na(nppes), !is.na(pecos_revalidation),
                      !grepl(";", nppes), !grepl(";", pecos_revalidation))
ind_agree <- 100 * mean(wv$nppes == wv$pecos_revalidation)
pub_row <- pw[pw$source_a == "nppes" & pw$source_b == "pecos_revalidation" &
              pw$year == comp_year, ]
add("A2", "NPPES-PECOS practice-state agreement, latest common year",
    "percent", ind_agree, 100 * pub_row$pct_agree[1],
    "state_source_audit_pairwise_agreement.csv (recomputed from canonical_source_records.csv)",
    0.6,
    sprintf("independent n=%d vs artifact n=%d; tolerance covers multi-state handling",
            nrow(wv), pub_row$n_compared[1]))

# --- A3. Persistence: NPPES-PECOS discordance 2021 -> 2026 ------------------
# Independent reconstruction of the censoring-audit headline.
np <- canon %>% filter(source == "nppes") %>% select(npi, year, state) %>% distinct()
pc <- canon %>% filter(source == "pecos_revalidation") %>%
  select(npi, year, state) %>% distinct()
b21 <- inner_join(filter(np, year == 2021), filter(pc, year == 2021),
                  by = "npi", suffix = c("_np", "_pc")) %>%
  filter(state_np != state_pc)
n26 <- inner_join(filter(np, year == 2026), filter(pc, year == 2026),
                  by = "npi", suffix = c("_np", "_pc"))
obs26 <- semi_join(b21, n26, by = "npi")
still <- inner_join(obs26, n26, by = "npi", suffix = c("", "_y26")) %>%
  filter(state_np_y26 != state_pc_y26)
ca <- read_csv(file.path(ART, "oig_remake/oig_longitudinal_2021_2026_censoring_audit.csv"),
               show_col_types = FALSE, progress = FALSE)
ca_obs <- sum(ca$n_clinicians[grepl("censored|Censored", ca$longitudinal_disposition) == FALSE])
# The artifact's uncensored denominator is 728; compare discordance-in-2026 share.
add("A3a", "providers discordant NPPES-PECOS 2021, both observed 2026",
    "clinicians", nrow(obs26), 728, "oig_longitudinal_2021_2026_censoring_audit.csv",
    30, "tolerance: canonical records regenerated since audit artifact; drift expected")
add("A3b", "still discordant in 2026 among observed",
    "clinicians", nrow(still),
    sum(ca$n_clinicians[grepl("Continuously Observed", ca$longitudinal_disposition)]),
    "oig_longitudinal_2021_2026_censoring_audit.csv",
    40, "same drift caveat as A3a")

# --- A4. Denominator unit check: provider-years vs unique clinicians --------
py <- canon %>% summarise(n_rows = n(), n_npi = n_distinct(npi),
                          n_npi_year = n_distinct(paste(npi, year)))
add("A4", "canonical rows vs unique NPI-years (record-level inflation)",
    "ratio", py$n_rows / py$n_npi_year, NA_real_, "canonical_source_records.csv",
    NA_real_, sprintf("%.2f records per NPI-year: provider-year and record denominators are NOT interchangeable", py$n_rows / py$n_npi_year))

# --- A5. usable_for_trend exclusion is honoured by consumers ---------------
# Independent check: no consumer artifact may count unusable rows.
cs <- read_csv(file.path(ART, "source_count_agreement_by_n_sources.csv"),
               show_col_types = FALSE, progress = FALSE)
unusable <- canon %>% filter(usable_for_trend == FALSE)
add("A5", "unusable-for-trend rows present in canonical records",
    "rows", nrow(unusable), 37923, "canonical_source_records.csv",
    0, "D14 item 5 baseline: consumers must exclude these")

out <- bind_rows(results)
dir.create(OUT, showWarnings = FALSE)
write_csv(out, file.path(OUT, "federal_agreement_denominators.csv"))

md <- c("# Federal agreement study -- independent audit numbers",
        "",
        sprintf("Generated %s by `review/build_federal_agreement_audit.R`.",
                format(Sys.time(), "%Y-%m-%d %H:%M")),
        "All values recomputed directly from `artifacts/`; the stats catalog",
        "was not used.", "",
        "| check | quantity | unit | independent | published | status |",
        "|---|---|---|---|---|---|")
for (i in seq_len(nrow(out))) {
  r <- out[i, ]
  md <- c(md, sprintf("| %s | %s | %s | %s | %s | %s |",
                      r$check_id, r$quantity, r$unit,
                      ifelse(is.na(r$independent_value), "--",
                             formatC(r$independent_value, format = "f", digits = 2)),
                      ifelse(is.na(r$published_value), "--",
                             formatC(r$published_value, format = "f", digits = 2)),
                      r$status))
}
writeLines(md, file.path(OUT, "federal_agreement_audit_numbers.md"))

cat("wrote", nrow(out), "checks ->", file.path(OUT, "federal_agreement_denominators.csv"), "\n")
print(as.data.frame(out[, c("check_id", "independent_value", "published_value", "status")]),
      row.names = FALSE)
