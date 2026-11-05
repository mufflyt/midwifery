#!/usr/bin/env Rscript
# =============================================================================
# Open Payments address history for the cohort, program year 2025
# =============================================================================
# Earlier in this project data.cms.gov / openpaymentsdata.cms.gov returned
# 403 on every endpoint tried, so 2022-2024 came from a pre-downloaded
# warehouse and 2015-2021 from the same. Re-checked 2026-11-03: CMS's own
# site answers fine now (not blocked, was evidently a transient/session
# issue) and PY2025 General Payment Data is published:
#   https://download.cms.gov/openpayments/PGYR2025_P06302026_06032026/OP_DTL_GNRL_PGYR2025_P06302026_06032026.csv
# (9.2GB, confirmed via metastore API + HEAD request). Downloaded to
# /Volumes/MufflySamsung/open_payments_data/2025/unzipped_files/, matching
# the existing per-year raw-file layout, rather than re-added to the merged
# 2013-2024 warehouse (which stays as-is).
#
# Same cohort selection, same column mapping, same output schema as
# extract_open_payments_address_history.R -- confirmed via the 2025 file's
# own header that Covered_Recipient_NPI / Recipient_* / Total_Amount_of_Payment_USDollars
# / Applicable_Manufacturer_or_Applicable_GPO_Making_Payment_Name are
# unchanged from prior years, so no column-name resolution needed here.
#
# Output: artifacts/cohort_midwives_open_payments_general_2025.csv
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})

RAW_FILE <- "/Volumes/MufflySamsung/open_payments_data/2025/unzipped_files/OP_DTL_GNRL_PGYR2025_P06302026_06032026.csv"
stopifnot(file.exists(RAW_FILE))

crosswalk_candidates <- sort(Sys.glob("artifacts/amcb_npi_crosswalk_*panel*.csv"), decreasing = TRUE)
if (!length(crosswalk_candidates)) stop("no artifacts/amcb_npi_crosswalk_*panel*.csv found", call. = FALSE)
MIDWIVES_FILE <- crosswalk_candidates[1]

cw <- read_csv(MIDWIVES_FILE, col_types = cols(.default = "c"), progress = FALSE)
coh <- cw %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  transmute(npi = trimws(npi), certification_number, first_name, last_name,
            nppes_state = coalesce(nppes_state, "")) %>%
  filter(!is.na(npi), nzchar(npi))
cat(sprintf("Loaded %s active cohort midwives from %s\n",
            format(nrow(coh), big.mark = ","), basename(MIDWIVES_FILE)))

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE, temporary = TRUE)

src <- sprintf("read_csv_auto(%s, all_varchar = TRUE, sample_size = -1, ignore_errors = true)",
               dbQuoteString(con, RAW_FILE))

sql <- sprintf(r"(
  SELECT c.certification_number, o.Covered_Recipient_NPI AS npi, c.first_name, c.last_name,
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
  INNER JOIN cohort_npis c ON c.npi = o.Covered_Recipient_NPI)", src)

out <- dbGetQuery(con, sql)
out_path <- "artifacts/cohort_midwives_open_payments_general_2025.csv"
write_csv(out, out_path, na = "")
cat(sprintf("2025: %s matched rows, %s distinct NPIs -> %s\n",
            format(nrow(out), big.mark = ","),
            format(length(unique(out$npi)), big.mark = ","), out_path))
