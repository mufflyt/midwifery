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

YEARS <- as.integer(strsplit(Sys.getenv("YEARS", "2015,2016,2017,2018,2019,2020,2021"), ",")[[1]])

WAREHOUSE <- samsung_duckdb_path(file.path("open_payments_data",
                                           "open_payments_merged_2013_2024.duckdb"),
                                 "OPEN_PAYMENTS_WAREHOUSE")
stopifnot(file.exists(WAREHOUSE))

crosswalk_candidates <- sort(Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv"),
                             decreasing = TRUE)
if (!length(crosswalk_candidates))
  stop("no artifacts/amcb_npi_crosswalk_*panel*.csv found", call. = FALSE)
MIDWIVES_FILE <- crosswalk_candidates[1]

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
