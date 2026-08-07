#!/usr/bin/env Rscript
# =============================================================================
# Extract midwifery providers from the NPPES full dissemination file
# =============================================================================
#
# Scans all 15 taxonomy fields (following match_michigan_to_nppes_ALL_TAXONOMIES.R)
# for the two midwifery taxonomy codes and caches the subset as parquet so the
# 9.8 GB source file is read only once.
#
#   367A00000X  Advanced Practice Midwife (CNM)
#   176B00000X  Midwife
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

nppes_csv <- "~/Documents/NPPES_Data_Dissemination_March_2024/npidata_pfile_20050523-20240310.csv"
nppes_csv <- path.expand(nppes_csv)
out       <- "nppes_midwives.parquet"

stopifnot(file.exists(nppes_csv))

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

tax_filter <- paste(sprintf(
  '"Healthcare Provider Taxonomy Code_%d" IN (\'367A00000X\', \'176B00000X\')', 1:15),
  collapse = " OR ")

sql <- sprintf('
  COPY (
    SELECT
      NPI AS npi,
      UPPER(TRIM("Provider First Name"))                                    AS first_name,
      UPPER(TRIM("Provider Last Name (Legal Name)"))                        AS last_name,
      UPPER(TRIM("Provider Middle Name"))                                   AS middle_name,
      UPPER(TRIM("Provider Credential Text"))                               AS credential,
      UPPER(TRIM("Provider First Line Business Practice Location Address"))  AS practice_address,
      UPPER(TRIM("Provider Business Practice Location Address City Name"))  AS practice_city,
      UPPER(TRIM("Provider Business Practice Location Address State Name")) AS practice_state,
      TRIM("Provider Business Practice Location Address Postal Code")       AS practice_zip,
      "Healthcare Provider Taxonomy Code_1"                                 AS taxonomy
    FROM read_csv_auto(%s, all_varchar = TRUE, sample_size = -1)
    WHERE "Entity Type Code" = \'1\' AND (%s)
  ) TO %s (FORMAT PARQUET)',
  dbQuoteString(con, nppes_csv), tax_filter, dbQuoteString(con, out))

cat("Scanning NPPES full file (this reads ~9.8 GB)...\n")
dbExecute(con, sql)

n <- dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM read_parquet(%s)",
                             dbQuoteString(con, out)))$n
cat(sprintf("Wrote %s midwifery providers to %s\n", format(n, big.mark = ","), out))
