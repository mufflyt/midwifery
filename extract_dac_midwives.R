#!/usr/bin/env Rscript
# =============================================================================
# Extract certified nurse-midwives from CMS Doctors and Clinicians (DAC)
# =============================================================================
#
# The isochrones matching ladder does not match names against all of NPPES --
# it matches within rosters that already carry NPIs (R/strategies/, S1-S32).
# This is the strategy_02 source: CMS Doctors and Clinicians, which records a
# clinician's Medicare-enrolled specialty explicitly.
#
# Two things it gives this project that NPPES cannot:
#
#   1. Independent specialty evidence. DAC states "CERTIFIED NURSE MIDWIFE"
#      as pri_spec/sec_spec, so a midwife enumerated in NPPES under some other
#      taxonomy still reads as a midwife here.
#   2. Reach back in time. DAC lists clinicians enrolled when it was published;
#      an NPI deactivated since then is absent from the live NPI Registry but
#      still present here -- which is exactly the lapsed/retired/deceased
#      population the live API cannot see.
#
# One row per (NPI, practice location) becomes one row per NPI with the
# addresses collapsed.
#
# Output: dac_midwives.csv
# =============================================================================

suppressPackageStartupMessages({library(DBI); library(duckdb)})

dac <- Sys.getenv("DAC_FILE", path.expand(
  "~/Documents/Documents - TMuff/doctors_and_clinicians_current_data/DAC_NationalDownloadableFile.csv"))
stopifnot(file.exists(dac))

con <- dbConnect(duckdb::duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# Header fields are comma-space separated, so DuckDB sees leading blanks in the
# names; normalise_names fixes that rather than quoting " lst_nm" everywhere.
# The published file is latin-1, not UTF-8 -- DuckDB aborts on the first
# non-UTF-8 byte (line 652,758 in the March 2022 release) without this.
src <- sprintf("read_csv_auto(%s, all_varchar = TRUE, sample_size = -1,
                              normalize_names = TRUE, encoding = 'latin-1')",
               dbQuoteString(con, dac))

# NB: DuckDB reads "..." as an identifier, so every string literal below must
# be single-quoted -- hence the raw string.
sql <- sprintf(r"(
  SELECT
    NPI                                    AS npi,
    UPPER(TRIM(lst_nm))                    AS last_name,
    UPPER(TRIM(frst_nm))                   AS first_name,
    UPPER(TRIM(COALESCE(mid_nm, '')))      AS middle_name,
    UPPER(TRIM(COALESCE(cred, '')))        AS credential,
    UPPER(TRIM(COALESCE(gndr, '')))        AS sex,
    UPPER(TRIM(pri_spec))                  AS primary_specialty,
    UPPER(TRIM(COALESCE(sec_spec_all, ''))) AS secondary_specialties,
    UPPER(TRIM(COALESCE(adr_ln_1, '')))    AS practice_address,
    UPPER(TRIM(COALESCE(cty, '')))         AS practice_city,
    UPPER(TRIM(COALESCE(st, '')))          AS practice_state,
    SUBSTR(TRIM(COALESCE(zip, '')), 1, 5)  AS practice_zip
  FROM %s
  WHERE UPPER(COALESCE(pri_spec, '')) LIKE '%%MIDWIFE%%'
     OR UPPER(COALESCE(sec_spec_all, '')) LIKE '%%MIDWIFE%%')", src)

cat("Scanning DAC national file...\n")
rows <- dbGetQuery(con, sql)
cat(sprintf("  %s midwife rows, %s distinct NPIs\n",
            format(nrow(rows), big.mark = ","),
            format(length(unique(rows$npi)), big.mark = ",")))

# One row per NPI: keep the first non-empty address, count distinct sites.
dbWriteTable(con, "dac_rows", rows, overwrite = TRUE)
out <- dbGetQuery(con, r"(
  SELECT npi, last_name, first_name, middle_name, credential, sex,
         ANY_VALUE(primary_specialty)     AS primary_specialty,
         ANY_VALUE(secondary_specialties) AS secondary_specialties,
         MIN(practice_address)            AS practice_address,
         MIN(practice_city)               AS practice_city,
         MIN(practice_state)              AS practice_state,
         MIN(practice_zip)                AS practice_zip,
         COUNT(DISTINCT practice_address || practice_city || practice_state) AS n_sites
  FROM dac_rows
  WHERE practice_address <> ''
  GROUP BY npi, last_name, first_name, middle_name, credential, sex)")

write.csv(out, "dac_midwives.csv", row.names = FALSE, na = "")
cat(sprintf("wrote %s midwives to dac_midwives.csv\n", format(nrow(out), big.mark = ",")))
print(head(sort(table(out$primary_specialty), decreasing = TRUE), 5))
