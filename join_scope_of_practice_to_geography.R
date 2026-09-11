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
# and are not collapsed into one.
#
# Inputs : artifacts/state_scope_of_practice.csv
#          artifacts/isochrone_representation_by_state.csv
#          artifacts/geocoding_completeness_state.csv
# Outputs: artifacts/isochrone_representation_by_scope_of_practice.csv
#          artifacts/geocoding_completeness_by_scope_of_practice.csv
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

cat("\nNOTE: this compares REPRESENTATION IN THE ISOCHRONE LIBRARY and\n")
cat("GEOCODING COMPLETENESS by scope-of-practice status -- both are data-\n")
cat("quality/coverage measures, not the population-weighted drive-time ACCESS\n")
cat("measure access_full_cohort.R computes (blocked on this machine; see\n")
cat("issue #176). A state with lower isochrone representation is a state\n")
cat("this project has measured less completely, not necessarily one with\n")
cat("worse actual access -- do not conflate the two without running the\n")
cat("population-weighted comparison once the blocking files are available.\n")
