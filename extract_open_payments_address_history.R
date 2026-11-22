#!/usr/bin/env Rscript
# =============================================================================
# Open Payments address history for the cohort, 2015-2021 (filling the gap)
# =============================================================================
# match_open_payments_general_payments.py already covers 2022-2024 by
# streaming CMS's live API. That API is unreachable from this environment
# right now (data.cms.gov / openpaymentsdata.cms.gov 403 everything, Akamai),
# but the raw files for every program year back to 2013 are already sitting
# in /Volumes/MufflySamsung/open_payments_data/open_payments_merged_2013_2024.duckdb
# (op_<year> tables, one straight import of that year's CMS General Payments
# CSV). 2013-2014 have no NPI column at all (NPI reporting started in program
# year 2015) -- Open Payments cannot corroborate those two years without a
# name-based match this script deliberately does not attempt. 2015 alone
# uses "Physician_NPI" instead of "Covered_Recipient_NPI"; every other column
# used here (address/city/state/zip/amount/payer) is stable 2015-2024.
#
# Same cohort selection and output schema as match_open_payments_general_payments.py
# (one row per payment transaction, not pre-collapsed -- compare_dac_openpayments_to_nppes_address.R
# does the modal-address collapse itself), so the two scripts' outputs drop
# into the same artifacts/cohort_midwives_open_payments_general_<year>.csv
# family interchangeably.
#
# Output: artifacts/cohort_midwives_open_payments_general_<year>.csv, one per
# year in YEARS (person-level, same standing as the existing 2022-2024 files;
# see .gitignore).
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # duckdb_connect(): CSV-ingestion bootstrap
source(file.path("R", "lib", "cohort_artifacts.R"))  # cohort_artifact_path(): one arm, named

# THE YEAR MUST BE PROVABLE FROM INSIDE THE FILE. Until 2026-11-15 these
# artifacts carried no year column at all: the year existed only in the
# filename, which R/lib/source_year.R::assert_source_year() refuses as proof
# by design (parse_vintage() rejects a bare four-digit number). A file
# renamed, or written by a producer handed the wrong year, would have been
# believed -- and in the 2026-11-12 build four of five years went missing
# with nothing to notice. The SELECT below now carries CMS's own
# Program_Year column plus Date_of_Payment, so each annual artifact proves
# its own vintage from an authoritative field rather than from its name.
# Program_Year is read from the source, never written from `y`, because a
# year the producer asserts is not an observation.
#
# The default window is the full declared series. It used to stop at 2021,
# which is how a run that simply took the default could produce a short
# series without saying so.
YEARS <- as.integer(strsplit(Sys.getenv(
  "YEARS", "2015,2016,2017,2018,2019,2020,2021,2022,2023,2024,2025"),
  ",")[[1]])

WAREHOUSE <- samsung_duckdb_path(file.path("open_payments_data",
                                           "open_payments_merged_2013_2024.duckdb"),
                                 "OPEN_PAYMENTS_WAREHOUSE")
stopifnot(file.exists(WAREHOUSE))

# WHICH ARM, NOT WHICHEVER SORTS LAST. The glob that stood here matched all
# three crosswalk arms -- translit, component, c5guard -- and a DESCENDING
# sort took translit, while the rest of the pipeline (build_table1_midwives.R,
# the hospital matchers, the licence enrichers) names c5guard outright. The
# arms exist in order to differ, so the Open Payments denominator was being
# picked by alphabetical accident, against a cohort other published tables do
# not use. Verified before pinning: all three arms are identical on every
# column read below -- 11,920 ACTIVE primary_midwifery NPIs each, same npi,
# certification_number, first_name, last_name and nppes_state -- so this
# changes no number today. It stops the agreement from being luck.
MIDWIVES_FILE <- cohort_artifact_path("crosswalk_c5guard")

cw <- read_csv(MIDWIVES_FILE, col_types = cols(.default = "c"), progress = FALSE)
coh <- cw %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  transmute(npi = trimws(npi), certification_number, first_name, last_name,
            nppes_state = coalesce(nppes_state, "")) %>%
  filter(!is.na(npi), nzchar(npi))
cat(sprintf("Loaded %s active cohort midwives from %s\n",
            format(nrow(coh), big.mark = ","), basename(MIDWIVES_FILE)))

con <- duckdb_connect(WAREHOUSE, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE, temporary = TRUE)

for (y in YEARS) {
  tbl <- sprintf("main.op_%d", y)
  cols_here <- dbGetQuery(con, sprintf("DESCRIBE %s", tbl))$column_name
  npi_col <- if ("Covered_Recipient_NPI" %in% cols_here) "Covered_Recipient_NPI"
             else if ("Physician_NPI" %in% cols_here) "Physician_NPI"
             else stop(sprintf("%d: no recognized NPI column", y), call. = FALSE)

  sql <- sprintf(r"(
    SELECT c.certification_number, o.%s AS npi, c.first_name, c.last_name,
           c.nppes_state,
           o.Program_Year                      AS program_year,
           o.Date_of_Payment                   AS date_of_payment,
           o.Teaching_Hospital_Name            AS teaching_hospital_name,
           ''                                  AS principal_practice_business_name,
           o.Recipient_Primary_Business_Street_Address_Line1 AS recipient_address,
           o.Recipient_City                    AS recipient_city,
           o.Recipient_State                   AS recipient_state,
           o.Recipient_Zip_Code                AS recipient_zip,
           o.Total_Amount_of_Payment_USDollars AS payment_amount,
           o.Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_Name AS payer_manufacturer
    FROM %s o
    INNER JOIN cohort_npis c ON c.npi = o.%s)", npi_col, tbl, npi_col)

  out <- dbGetQuery(con, sql)
  out_path <- sprintf("artifacts/cohort_midwives_open_payments_general_%d.csv", y)
  write_csv(out, out_path, na = "")
  cat(sprintf("%d: %s matched rows, %s distinct NPIs -> %s\n",
              y, format(nrow(out), big.mark = ","),
              format(length(unique(out$npi)), big.mark = ","), out_path))
}
