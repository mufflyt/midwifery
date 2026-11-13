#!/usr/bin/env Rscript
# =============================================================================
# Open Payments Covered Recipient Profile Supplement -- license state + taxonomy
# =============================================================================
# data/CMS_Open_Payments_Profile_Supplement.csv (1.69M rows, CMS's full Open
# Payments provider-profile registry; identical to the copy at
# ~/Dropbox/midwifery_gitignored_backup/data/, confirmed by checksum) is
# already read by harvest_open_payments_profile.py and used in
# classify_residual_disagreements.R -- but only for the profile's name and
# address, to resolve organization-address disagreements between two Type-2
# NPI matching methods. Two columns go completely unused everywhere else in
# this project:
#
#   Covered_Recipient_Profile_License_State_Code_1..5
#       Which states CMS's own reporting-year enrollment data says the
#       provider is LICENSED in -- not practice-location, not a DAC/PECOS/
#       NPPES-style single "current state". A provider can hold licenses in
#       several states at once; this is the first source in the whole state
#       audit that can distinguish "genuinely practices in two states" from
#       "the sources disagree about one state". Confirmed on the cohort before
#       building this: 8,411 of 16,775 midwives (50.1%) have a profile row;
#       of those, 2,865 (34.1%) show 2+ license states.
#   Covered_Recipient_Profile_Primary_Specialty / _OPS_Taxonomy_1..6
#       A second, independent specialty-taxonomy field per provider. 6,142 of
#       8,411 matched read "Advanced Practice Midwife" outright; the rest
#       split across Nurse Practitioner / Nurse Anesthetist / RN / other
#       labels -- dual credentialing or crosswalk imprecision, not resolved
#       here, just carried through.
#
# One row per NPI (confirmed 1:1, no duplicate profile rows in this file for
# this cohort -- no collapse logic needed).
#
# Output: artifacts/cohort_midwives_open_payments_profile_supplement.csv
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr); library(stringr)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # duckdb_connect(): CSV-ingestion bootstrap
source("R/lib/common_helpers.R")

# SOURCE PATH IS OVERRIDABLE, AND THE VINTAGE IS RECORDED. The repository copy
# at data/ is gitignored and absent from most clones; the same file ships from
# CMS as OP_CVRD_RCPNT_PRFL_SPLMTL_<publication>_<asof>.csv inside
# PHPRFL_<publication>.zip, and a mounted archive copy is the usual way to get
# it. No absolute path is hard-coded here (ci_repo_integrity forbids it) --
# point OP_PROFILE_SUPPLEMENT at the file instead.
#
# VINTAGES ARE NOT INTERCHANGEABLE. The January 2025 publication carries
# 1,530,413 rows; the analysis first published in the 2026-11-03 technical
# appendix cites 1.69M, so that run used a LATER publication. Counts computed
# from different vintages will differ legitimately and must not be reconciled
# by adjusting either one. The row count and file name are written into the
# provenance sidecar so which vintage produced a given artifact is recoverable.
SUPPLEMENT <- Sys.getenv("OP_PROFILE_SUPPLEMENT",
                         "data/CMS_Open_Payments_Profile_Supplement.csv")
if (!file.exists(SUPPLEMENT))
  stop(sprintf(paste0("Profile supplement not found at %s.\n",
                      "  Set OP_PROFILE_SUPPLEMENT to the CMS file ",
                      "(OP_CVRD_RCPNT_PRFL_SPLMTL_*.csv, inside PHPRFL_*.zip)."),
               SUPPLEMENT), call. = FALSE)
cat(sprintf("Supplement: %s\n", basename(SUPPLEMENT)))

link <- chr("artifacts/amcb_npi_linkage_FROZEN.csv")
coh <- link %>%
  filter(cohort_member == "TRUE") %>%
  transmute(certification_number, npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(coh), big.mark = ",")))

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE, temporary = TRUE)

sql <- r"(
  SELECT s.Covered_Recipient_NPI                         AS npi,
         s.Covered_Recipient_Profile_State                AS profile_state,
         s.Covered_Recipient_Profile_License_State_Code_1 AS license_state_1,
         s.Covered_Recipient_Profile_License_State_Code_2 AS license_state_2,
         s.Covered_Recipient_Profile_License_State_Code_3 AS license_state_3,
         s.Covered_Recipient_Profile_License_State_Code_4 AS license_state_4,
         s.Covered_Recipient_Profile_License_State_Code_5 AS license_state_5,
         s.Covered_Recipient_Profile_Primary_Specialty     AS primary_specialty,
         s.Covered_Recipient_Profile_OPS_Taxonomy_1        AS ops_taxonomy_1,
         s.Covered_Recipient_Profile_OPS_Taxonomy_2        AS ops_taxonomy_2,
         s.Covered_Recipient_Profile_OPS_Taxonomy_3        AS ops_taxonomy_3
    FROM read_csv_auto(?, all_varchar = true, sample_size = -1, ignore_errors = true) s
    INNER JOIN cohort_npis c ON c.npi = s.Covered_Recipient_NPI)"
rows <- dbGetQuery(con, sql, params = list(SUPPLEMENT))
cat(sprintf("Matched profile rows: %s (%s distinct NPIs)\n",
            format(nrow(rows), big.mark = ","), format(length(unique(rows$npi)), big.mark = ",")))

source(file.path("R", "lib", "clean_state.R"))

out <- rows %>%
  rowwise() %>%
  mutate(
    license_states_list = {
      s <- clean_state(c(license_state_1, license_state_2, license_state_3, license_state_4, license_state_5))
      s <- sort(unique(s[!is.na(s)]))
      if (length(s)) paste(s, collapse = "|") else NA_character_
    },
    n_license_states = {
      s <- clean_state(c(license_state_1, license_state_2, license_state_3, license_state_4, license_state_5))
      length(unique(s[!is.na(s)]))
    }
  ) %>%
  ungroup() %>%
  mutate(
    profile_state = clean_state(profile_state),
    multistate_licensed = n_license_states >= 2
  ) %>%
  left_join(coh, by = "npi", relationship = "many-to-one") %>%
  select(npi, certification_number, profile_state, license_states_list, n_license_states,
         multistate_licensed, primary_specialty, ops_taxonomy_1, ops_taxonomy_2, ops_taxonomy_3)

source(file.path("R", "lib", "artifact_provenance.R"))
write_with_provenance(out, "artifacts/cohort_midwives_open_payments_profile_supplement.csv",
                      inputs = c(SUPPLEMENT, "artifacts/amcb_npi_linkage_FROZEN.csv"), na = "")
cat(sprintf("\nwrote %s rows -> artifacts/cohort_midwives_open_payments_profile_supplement.csv\n",
            format(nrow(out), big.mark = ",")))
cat(sprintf("multistate-licensed: %s / %s (%.1f%%)\n",
            format(sum(out$multistate_licensed), big.mark = ","), format(nrow(out), big.mark = ","),
            100 * mean(out$multistate_licensed)))
cat("primary_specialty distribution:\n")
print(sort(table(out$primary_specialty), decreasing = TRUE)[1:8])
