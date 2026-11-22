#!/usr/bin/env Rscript
# =============================================================================
# Cross-check AMCB certification status against NPPES NPI deactivations
# =============================================================================
#
# Follows B-NPI_deactivation.R: read the NPPES Deactivated NPI Report, keep NPI
# and deactivation year, and flag matched providers.
#
# Note on interpretation: CMS removes deactivated NPIs from the dissemination
# file, so a matched NPI is by construction usually still active. The stronger
# signal here is the NPPES match rate broken out by AMCB status -- deceased and
# lapsed certificants should be findable in NPPES at a materially lower rate.
#
# Inputs : midwives_with_nppes.csv, NPPES Deactivated NPI Report
# Output : midwives_status_check.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(readxl); library(stringr)
})
# assert_unique_keys() ONLY. This used to source R/join_safety.R, which is
# 1,892 lines (2,195 with the R/safe_divide.R it sources) and whose other
# functions this script never calls -- the 2026-11-20 complexity audit's first
# finding. The assertion now lives in its own file.
source(file.path("R", "assert_unique_keys.R"))

report <- Sys.getenv("NPI_DEACTIVATION_REPORT",
                     path.expand("~/Documents/NPPES Deactivated NPI Report 20240408.xlsx"))
stopifnot(file.exists(report))

midwives <- read_csv("midwives_with_nppes.csv", show_col_types = FALSE) %>%
  # NPIs are identifiers, not numbers: read_csv infers double, the report gives
  # character, and left_join() refuses to combine the two.
  mutate(npi = as.character(npi))

deactivated <- read_excel(report, skip = 1) %>%
  rename(npi = NPI, deactivation_date = `NPPES Deactivation Date`) %>%
  filter(!is.na(npi)) %>%
  mutate(npi = as.character(npi),
         deactivation_date = as.character(deactivation_date),
         deactivation_year = as.integer(
           stringr::str_extract(deactivation_date, "[12][0-9]{3}"))) %>%
  # An NPI deactivated, later reactivated, and deactivated again is a real
  # scenario, not a data-entry error, and would appear twice in this report
  # with DIFFERENT dates. distinct(.keep_all = TRUE) would have picked
  # whichever row sorted first -- the same class of defect the ledger's
  # cycle 2/5 .keep_all sweep already fixed elsewhere. assert_unique_keys()
  # collapses genuine (identical) duplicates silently and stops on a real
  # conflict instead of guessing.
  assert_unique_keys("npi", label = "NPPES Deactivated NPI Report", dedupe = TRUE)

cat(sprintf("Deactivated NPIs in report: %s\n",
            format(nrow(deactivated), big.mark = ",")))

out <- midwives %>%
  left_join(select(deactivated, npi, npi_deactivation_date = deactivation_date,
                   npi_deactivation_year = deactivation_year), by = "npi") %>%
  mutate(npi_deactivated = !is.na(npi_deactivation_date))

write_csv(out, "midwives_status_check.csv", na = "")

cat("\nNPPES match rate by AMCB status:\n")
print(out %>%
        group_by(status) %>%
        summarise(n = n(),
                  matched = sum(!is.na(npi)),
                  pct_matched = round(100 * mean(!is.na(npi)), 1),
                  deactivated = sum(npi_deactivated), .groups = "drop") %>%
        arrange(desc(n)))
