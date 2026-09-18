#!/usr/bin/env Rscript
# =============================================================================
# Join state scope-of-practice classification onto the state-level geography
# artifacts, and compare isochrone representation / geocoding completeness by
# practice-authority category
# =============================================================================
# WHY. Every geographic-access study in the literature this project has
# reviewed measures access as headcount density or county presence/absence,
# and stops there -- none tests whether the ACTUAL result (how well a state's
# midwives are represented in a drive-time isochrone library, or how
# completely their practice addresses geocode) differs by scope-of-practice
# regime. Ranchoff & Declercq (2020) found autonomous-practice states have
# 2.2x the per-capita CNM/CM density of collaborative/supervisory states, but
# their own access measure is "does this county have >=1 midwife" -- binary
# presence, not distance or coverage quality. This script is the first join
# of a real practice-authority classification onto this project's own
# geography artifacts, not a new access metric of its own: it augments
# EXISTING committed artifacts, not simulates policy population-weighted
# access (which needs external isochrone/census files this machine doesn't
# currently have; see access_full_cohort.R and issue #176 for that gap).
#
# Uses practice_authority_2016 (the complete 50-state+DC classification, no
# excluded states) rather than practice_authority_continuous, so every row of
# the geography artifacts gets a category -- see
# build_state_scope_of_practice.R's own header for why the two columns exist
# and are not collapsed into one. Nothing here is restricted to the 45
# jurisdictions of Table 1's continuous classification; a reader who sees
# n = 24 vs 25 is NOT looking at the six mid-window changers being dropped.
#
# WHICH STATES THE ACCESS MEASURE CANNOT SEE, AND WHY IT IS RECORDED. The
# significance test ran on 24 autonomous states against 25 collaborative ones
# while the classification carries 26 and 25. The two missing are Alaska and
# Hawaii, both Autonomous, and they are absent from
# full_cohort_access_by_band_state.csv rather than from the join: the upstream
# ACS tract extract is 48 states plus DC, and the census patches that fill the
# remainder (patch_missing_state_census_data.R) did not cover AK or HI until
# 2026-09-18. Two states lost from ONE arm of a two-arm comparison is a
# deletion correlated with the exposure, and those two are the arm's
# weakest-measured members (0 of 36 and 0 of 14 midwives represented in
# isochrone_representation_by_scope_of_practice.csv), so excluding them biases
# the autonomous mean upward -- against the reported direction at 60 minutes.
# The significance artifact therefore carries n_excluded, the excluded states
# and their arm, so 24-vs-26 is visible in the artifact instead of requiring a
# reader to diff two files (#227).
#
# THE EXPOSURE IS 2012-2016 LAW. classification_window rides along from
# state_scope_of_practice.csv onto every artifact written here (#226).
#
# Inputs : artifacts/state_scope_of_practice.csv
#          artifacts/isochrone_representation_by_state.csv
#          artifacts/geocoding_completeness_state.csv
# Outputs: artifacts/isochrone_representation_by_scope_of_practice.csv
#          artifacts/geocoding_completeness_by_scope_of_practice.csv
#          artifacts/full_cohort_access_by_scope_of_practice.csv
#          artifacts/access_by_scope_of_practice_significance.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})
source(file.path("R", "lib", "artifact_provenance.R"))

SOP  <- read_csv("artifacts/state_scope_of_practice.csv", show_col_types = FALSE)

# Both geography artifacts key on a state field carrying occasional non-US-
# jurisdiction noise (a German state name was found in
# isochrone_representation_by_state.csv, almost certainly a geocoding
# artifact of an overseas military address) or non-state territories (DC is a
# real jurisdiction and is kept; anything not in the 50-states+DC
# classification is dropped from the join with a reported count, not
# silently -- a state-level comparison cannot include rows with no state).
join_report <- function(geo, state_col, label) {
  us <- geo[[state_col]] %in% SOP$state
  dropped <- geo[[state_col]][!us]
  if (length(dropped))
    cat(sprintf("%s: dropping %d non-US-jurisdiction row(s): %s\n",
                label, length(dropped), paste(unique(dropped), collapse = ", ")))
  inner_join(geo[us, ], SOP, by = setNames("state", state_col))
}

# --- isochrone representation ------------------------------------------------
iso <- read_csv("artifacts/isochrone_representation_by_state.csv", show_col_types = FALSE)
iso_j <- join_report(iso, "nppes_state", "isochrone_representation_by_state.csv")

iso_summary <- iso_j %>%
  group_by(practice_authority_2016) %>%
  summarise(n_states = n_distinct(nppes_state),
            n_midwives = sum(n_midwives),
            n_represented = sum(n_represented),
            pct_represented = round(100 * sum(n_represented) / sum(n_midwives), 1),
            median_km = round(median(median_km, na.rm = TRUE), 2),
            .groups = "drop")

cat("\n=== isochrone representation by 2016 scope-of-practice status ===\n")
print(as.data.frame(iso_summary))

write_with_provenance(iso_j, "artifacts/isochrone_representation_by_scope_of_practice.csv",
                      inputs = c("artifacts/state_scope_of_practice.csv",
                                "artifacts/isochrone_representation_by_state.csv"))
cat("\nwrote artifacts/isochrone_representation_by_scope_of_practice.csv\n")

# --- geocoding completeness --------------------------------------------------
geo <- read_csv("artifacts/geocoding_completeness_state.csv", show_col_types = FALSE)
geo_j <- join_report(geo, "practice_state", "geocoding_completeness_state.csv")

geo_summary <- geo_j %>%
  group_by(practice_authority_2016) %>%
  summarise(n_states = n_distinct(practice_state),
            n = sum(n), n_geocoded = sum(n_geocoded),
            pct_geocoded = round(100 * sum(n_geocoded) / sum(n), 1),
            .groups = "drop")

cat("\n=== geocoding completeness by 2016 scope-of-practice status ===\n")
print(as.data.frame(geo_summary))

write_with_provenance(geo_j, "artifacts/geocoding_completeness_by_scope_of_practice.csv",
                      inputs = c("artifacts/state_scope_of_practice.csv",
                                "artifacts/geocoding_completeness_state.csv"))
cat("\nwrote artifacts/geocoding_completeness_by_scope_of_practice.csv\n")

# --- population-weighted drive-time access (the actual comparison) ----------
# access_full_cohort.R was blocked when this script was first written (see
# issue #176); now unblocked (S3-cached ACS extract + a small patch for two
# states -- see patch_missing_state_census_data.R) and its by-state output is
# joined here too. This is the REAL comparison the literature review flagged
# as the novel contribution opportunity -- Ranchoff & Declercq found
# autonomous states have 2.2x the per-capita midwife density of
# collaborative/supervisory ones, but never measured travel time.
acc_path <- "artifacts/full_cohort_access_by_band_state.csv"
if (!file.exists(acc_path)) {
  cat(sprintf("\nSKIPPED: %s absent -- run access_full_cohort.R first.\n", acc_path))
} else {
  acc <- read_csv(acc_path, show_col_types = FALSE)
  acc_j <- join_report(acc, "state", "full_cohort_access_by_band_state.csv")

  acc_summary <- acc_j %>%
    group_by(practice_authority_2016, band_minutes) %>%
    summarise(n_states = n_distinct(state),
              women_with_access = sum(women_with_access),
              women_total = sum(women_total),
              pct_women_with_access = round(100 * sum(women_with_access) / sum(women_total), 1),
              .groups = "drop") %>%
    arrange(band_minutes, practice_authority_2016)

  cat("\n=== POPULATION-WEIGHTED DRIVE-TIME ACCESS by 2016 scope-of-practice status ===\n")
  print(as.data.frame(acc_summary))

  write_with_provenance(acc_j, "artifacts/full_cohort_access_by_scope_of_practice.csv",
                        inputs = c("artifacts/state_scope_of_practice.csv", acc_path))
  cat("\nwrote artifacts/full_cohort_access_by_scope_of_practice.csv\n")

  # --- which classified jurisdictions the access measure never saw ----------
  # Reported, not asserted away: a state with no access row is a state this
  # project could not measure, and that fact belongs in the artifact beside
  # the p-value. Loud on stderr too, because a silent arm shrinking is the
  # failure mode this exists to catch.
  missing_states <- sort(setdiff(SOP$state, unique(acc_j$state)))
  missing_tbl <- SOP[SOP$state %in% missing_states, c("state", "practice_authority_2016")]
  excluded_states <- paste(missing_states, collapse = ";")
  excluded_states_authority <- paste(sprintf("%s=%s", missing_tbl$state,
                                             missing_tbl$practice_authority_2016),
                                     collapse = ";")
  n_excluded_autonomous <- sum(missing_tbl$practice_authority_2016 == "Autonomous")
  n_excluded_collaborative <- sum(missing_tbl$practice_authority_2016 == "Collaborative_supervisory")
  if (length(missing_states)) {
    cat(sprintf(paste0(
      "\n!! %d of %d classified jurisdictions have no access row and are absent from\n",
      "   the comparison: %s\n",
      "   by arm: %d autonomous, %d collaborative -- an exclusion correlated with the\n",
      "   exposure whenever these are not balanced across arms.\n"),
      length(missing_states), nrow(SOP), excluded_states_authority,
      n_excluded_autonomous, n_excluded_collaborative))
  }

  # --- significance test, STATE as the unit of analysis ---------------------
  # NOT a proportions test on the raw women_with_access/women_total counts.
  # Those counts sum to hundreds of millions, and a two-proportion test
  # (e.g. this repo's own mw_diff()) treats every individual woman as an
  # independent trial -- with n in the hundreds of millions, that inflates
  # significance enormously and would call almost any nonzero difference
  # "significant" regardless of whether it reflects a real regulatory effect
  # or noise between two arbitrary state groupings. Ranchoff & Declercq's own
  # comparison avoids exactly this by testing across STATES (chi-square on
  # county presence/absence, n=20 vs n=24), not across individuals. This
  # follows the same logic: each state's own pct_women_with_access is one
  # observation, and the test is Welch's two-sample t-test across the two
  # state groups (unequal variance, since group sizes and spread differ).
  sig <- lapply(unique(acc_summary$band_minutes), function(b) {
    aut <- acc_j$pct_women_with_access[acc_j$practice_authority_2016 == "Autonomous" &
                                         acc_j$band_minutes == b]
    col <- acc_j$pct_women_with_access[acc_j$practice_authority_2016 == "Collaborative_supervisory" &
                                         acc_j$band_minutes == b]
    t <- t.test(aut, col)
    tibble(band_minutes = b, n_autonomous = length(aut), n_collaborative = length(col),
          mean_autonomous_pct = round(mean(aut), 1), mean_collaborative_pct = round(mean(col), 1),
          diff_pp = round(mean(aut) - mean(col), 2),
          ci_lo = round(t$conf.int[1], 2), ci_hi = round(t$conf.int[2], 2),
          t_statistic = round(unname(t$statistic), 2), df = round(unname(t$parameter), 1),
          p_value = round(t$p.value, 4),
          # What the two n columns above do NOT say on their own.
          n_classified_autonomous = sum(SOP$practice_authority_2016 == "Autonomous"),
          n_classified_collaborative = sum(SOP$practice_authority_2016 == "Collaborative_supervisory"),
          n_excluded = length(missing_states),
          n_excluded_autonomous = n_excluded_autonomous,
          n_excluded_collaborative = n_excluded_collaborative,
          excluded_states = excluded_states,
          excluded_states_authority = excluded_states_authority,
          # The exposure's own date, so it travels with the p-value (#226).
          classification_window = SOP$classification_window[1],
          classification_snapshot_year = SOP$classification_snapshot_year[1],
          classification_source = SOP$classification_source[1])
  }) %>% bind_rows()

  cat("\n=== SIGNIFICANCE (state as unit of analysis, Welch two-sample t-test) ===\n")
  print(as.data.frame(sig))

  write_with_provenance(sig, "artifacts/access_by_scope_of_practice_significance.csv",
                        inputs = "artifacts/full_cohort_access_by_scope_of_practice.csv")
  cat("\nwrote artifacts/access_by_scope_of_practice_significance.csv\n")
}

cat("\nNOTE: isochrone representation and geocoding completeness (above) are\n")
cat("data-quality/coverage measures, not access -- a state with lower\n")
cat("representation is one this project measured less completely, not\n")
cat("necessarily one with worse actual access. The population-weighted\n")
cat("access comparison (this section) is the one that actually answers the\n")
cat("literature-review question; the other two remain useful as a check on\n")
cat("whether measurement completeness itself varies by regulatory regime.\n")
