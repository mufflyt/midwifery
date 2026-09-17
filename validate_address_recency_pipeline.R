#!/usr/bin/env Rscript
# =============================================================================
# Address recency: what the cohort file can and cannot say
# =============================================================================
# This script used to "validate the 400 identified midwife address updates"
# against state board licensure, CPT delivery claims and a cross-source PPV.
# None of the three existed:
#
#   - "400" and "98.5%" were string literals typed into the summary table.
#     No computation anywhere in the repository produces either.
#   - The delivery-claims check read has_cpt_delivery_claim, which was "DAC
#     primary specialty is CNM" relabelled as delivery attendance. Public
#     Part B has no delivery-code rows for anyone
#     (measure_medicare_delivery_code_observability.R).
#   - The board-licensure check was never implemented.
#
# It also carried a named "case study" of one midwife whose NPPES address had
# been overwritten by hand, in the nppes_* columns, with a different address
# by a one-off script (deleted in f5c2256); the case study then "validated"
# the edit it was reading. Removed. Whether a DAC or Open Payments address is
# more current than NPPES for any midwife is a real question, but answering it
# needs a dated comparison across sources that this script never had.
#
# What remains is what the input supports: how many cohort midwives carry a
# current NPPES practice state, and how many carry a Medicare hospital
# affiliation. Neither is a recency measure.
#
# Input : artifacts/cohort_midwife_facility_attributions_final_v4.csv (gitignored)
# Output: artifacts/address_recency_validation_report.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})
source(file.path("R", "lib", "clinical_setting.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

cat("=== Address recency: coverage counts ===\n")

v4_path <- "artifacts/cohort_midwife_facility_attributions_final_v4.csv"
v4 <- read_csv(v4_path, show_col_types = FALSE) %>% mutate(npi = as.character(npi))

# The v4 file has one row per midwife per attributed facility, so every count
# is of distinct NPIs. Counting rows is how a duplicate-inflated row count was
# once published as the size of this cohort.
n_npi <- n_distinct(v4$npi)

# NPPES current-state coverage. NOT a count of cross-state MOVES: no prior or
# legacy state field exists anywhere in this data model to compare nppes_state
# against, so a relocation count cannot be computed here.
state_known <- v4 %>% filter(!is.na(nppes_state))
cat(sprintf("1. NPPES State Coverage: %d midwives have a known current NPPES practice state (not a cross-state MOVE count -- no prior-state field exists to compare against).\n",
            n_distinct(state_known$npi)))

hosp <- v4 %>% filter(is_facility_setting_category(final_facility_setting, 1))

val_summary <- tibble::tribble(
  ~Validation_Dimension, ~Metric, ~Value,
  "Total Cohort Audited", "Midwives (distinct NPI)", as.character(n_npi),
  "NPPES Practice State Known", "Midwives (distinct NPI)", as.character(n_distinct(state_known$npi)),
  "Medicare Hospital Affiliation", "Midwives (distinct NPI)", as.character(n_distinct(hosp$npi))
)

write_with_provenance(val_summary, "artifacts/address_recency_validation_report.csv",
                      inputs = v4_path)
cat("\nWritten: artifacts/address_recency_validation_report.csv\n")
print(val_summary)
