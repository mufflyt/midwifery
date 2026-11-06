#!/usr/bin/env Rscript
# =============================================================================
# Historical CMS "Physician Compare" / DAC midwives, 2013-2025
# =============================================================================
# Five real vintages come from local NBER-mirror downloads (2013-06, 2013-09,
# 2014-09, 2015-10, 2016-04 -- 2017-2020's advertised NBER month directories
# exist but serve no real CSV, see discover_physician_compare_historical_months.R).
#
# Nine more (2017, 2018-Q2 .. 2025-Q2) were already sitting in
# /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb as
# doc_archive_12_2017_Physician_Compare_National_Downloadable_File_csv_3 and
# physician_compare_<year>_Q2 -- no new download needed. Column names drift
# release to release (lst_nm -> "Provider Last Name" in 2024-2025, st ->
# "State", etc., and 2025's column names carry stray trailing tabs from
# whatever ingested them), so these are resolved by pattern, not by exact
# name, via col_find()/col_find_opt() below. Hospital-affiliation CCN columns
# (hosp_afl_1..5 / "Hospital affiliation CCN 1".."5") exist for 2017-2022 and
# were dropped from CMS's own file starting 2023 -- col_find_opt() leaves
# those NA for 2023-2025 rather than failing.
#
# The warehouse's own 2014 tables (doc_archive_06_2014_National_Downloadable_File_csv_1/2)
# are corrupted -- column names are themselves data values, meaning whatever
# ingested them misparsed the source CSV. Skipped; 2014 is already covered by
# the clean NBER 2014-09 file above.
#
# Three more vintages added 2026-11-06 -- previously unused tables sitting in
# the SAME warehouse right next to the ones already extracted above, found
# while investigating whether finer-than-annual DAC resolution exists for the
# two NPPES migration spikes (docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md):
# 2017-04 (bracketing 2017-12 from the OTHER side of that spike's start),
# 2018-12 and 2019-12 (both previously only had a mid-year 2018-06/2019-06
# vintage, so the 2017-18 and 2018-19 transitions were being measured across
# 6-month windows, not full years -- these let that be checked properly).
# 2018-12 and 2019-12 each came in as TWO physical tables with identical
# schemas and overlapping NPIs (likely the same logical CMS release split
# across two ingested chunks, not two independent files) -- UNION ALL'd below
# rather than picking one arbitrarily, since either a true duplicate or a
# true split is handled correctly by unioning and relying on this script's
# normal per-NPI output (a later distinct() by the caller, same as every
# other vintage here already needs for its own within-vintage multi-row
# NPIs from multiple org/group affiliations).
#
# Two more added 2026-11-06, investigating the 2020-21 signal that
# docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S4 surfaced once NPPES
# is removed from the vote: 2020-12 and 2021-12 (CMS renamed "Physician
# Compare" to "Doctors and Clinicians" around then, hence the different
# table-name prefix). Each came in as two FULL duplicate tables (identical
# row and distinct-NPI counts) rather than a true split -- one picked
# arbitrarily, no UNION ALL needed.
#
# Same two-layer filter as extract_dac_midwives.R: specialty text match, then
# exclude_by_credential() drops anyone credentialed MD/DO who slipped through
# on a secondary-specialty mention.
#
# Output: artifacts/physician_compare_historical_midwives.csv, one row per
# (NPI, vintage), person-level (same standing as dac_midwives.csv).
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})
source(file.path("R", "lib", "credential_filter.R"))

VINTAGES <- list(
  list(vintage = "2013-06", path = "data/raw/cms_physician_compare/2013/National_Downloadable_File_2013-06.csv"),
  list(vintage = "2013-09", path = "data/raw/cms_physician_compare/2013/National_Downloadable_File_2013-09.csv"),
  list(vintage = "2014-09", path = "data/raw/cms_physician_compare/2014/National_Downloadable_File_2014-09.csv"),
  list(vintage = "2015-10", path = "data/raw/cms_physician_compare/2015/National_Downloadable_File_2015-10.csv"),
  list(vintage = "2016-04", path = "data/raw/cms_physician_compare/2016/National_Downloadable_File_2016-04.csv")
)

WAREHOUSE <- "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb"
WAREHOUSE_VINTAGES <- list(
  list(vintage = "2017-04", table = "doc_archive_04_2017_Refresh_Data_Archive_04_2017_csv_1"),
  list(vintage = "2017-12", table = "doc_archive_12_2017_Physician_Compare_National_Downloadable_File_csv_3"),
  list(vintage = "2018-06", table = "physician_compare_2018_Q2"),
  list(vintage = "2018-12", tables = c("doc_archive_12_2018_National_Downloadable_File_2018_12_csv_2",
                                        "doc_archive_12_2018_National_Downloadable_File_2018_12_csv_4")),
  list(vintage = "2019-06", table = "physician_compare_2019_Q2"),
  list(vintage = "2019-12", tables = c("doc_archive_12_2019_Physician_Compare_National_Downloadable_File_201912_csv_3",
                                        "doc_archive_12_2019_Physician_Compare_National_Downloadable_File_201912_csv_5")),
  list(vintage = "2020-06", table = "physician_compare_2020_Q2"),
  list(vintage = "2020-12", table = "doctors_and_clinicians_archive_12_2020_mj5m_pzi6_csv_8"),
  list(vintage = "2021-06", table = "physician_compare_2021_Q2"),
  list(vintage = "2021-12", table = "doctors_and_clinicians_12_2021_DAC_NationalDownloadableFile_csv_5"),
  list(vintage = "2022-06", table = "physician_compare_2022_Q2"),
  list(vintage = "2023-06", table = "physician_compare_2023_Q2"),
  list(vintage = "2024-06", table = "physician_compare_2024_Q2"),
  list(vintage = "2025-06", table = "physician_compare_2025_Q2")
)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# pattern-based column resolution for the warehouse tables, whose exact
# column names drift release to release (see header note above)
col_find <- function(have, patterns, required = TRUE) {
  trimmed <- trimws(have)
  for (p in patterns) {
    hit <- have[grepl(p, trimmed, ignore.case = TRUE)]
    if (length(hit)) return(hit[1])
  }
  if (required) stop(sprintf("no column matching %s in: %s", paste(patterns, collapse = " | "), paste(have, collapse = ", ")), call. = FALSE)
  NA_character_
}

all_out <- list()
for (v in VINTAGES) {
  stopifnot(file.exists(v$path))
  src <- sprintf(paste("read_csv_auto(%s, all_varchar = TRUE, sample_size = -1,",
                       "normalize_names = TRUE, ignore_errors = true)"),
                 dbQuoteString(con, v$path))
  have <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", src)))
  pick <- function(...) { opts <- c(...); hit <- opts[opts %in% have]
    if (!length(hit)) stop(sprintf("%s: none of %s", v$vintage, paste(opts, collapse=", ")), call. = FALSE)
    hit[1] }
  col_spec <- pick("primary_specialty")
  col_sec  <- pick("all_secondary_specialties")
  col_cred <- pick("credential")

  sql <- sprintf(r"(
    SELECT npi,
           UPPER(TRIM(last_name))                      AS last_name,
           UPPER(TRIM(first_name))                     AS first_name,
           UPPER(TRIM(COALESCE(%s, '')))                AS credential,
           UPPER(TRIM(%s))                              AS primary_specialty,
           UPPER(TRIM(COALESCE(%s, '')))                AS secondary_specialties,
           UPPER(TRIM(COALESCE(line_1_street_address, ''))) AS practice_address,
           UPPER(TRIM(COALESCE(city, '')))              AS practice_city,
           UPPER(TRIM(COALESCE(state, '')))             AS practice_state,
           SUBSTR(TRIM(COALESCE(zip_code, '')), 1, 5)   AS practice_zip,
           claims_based_hospital_affiliation_ccn_1      AS ccn_1,
           claims_based_hospital_affiliation_ccn_2      AS ccn_2,
           claims_based_hospital_affiliation_ccn_3      AS ccn_3,
           claims_based_hospital_affiliation_ccn_4      AS ccn_4,
           claims_based_hospital_affiliation_ccn_5      AS ccn_5
    FROM %s
    WHERE UPPER(COALESCE(%s, '')) LIKE '%%MIDWIFE%%'
       OR UPPER(COALESCE(%s, ''))  LIKE '%%MIDWIFE%%')",
    col_cred, col_spec, col_sec, src, col_spec, col_sec)

  rows <- dbGetQuery(con, sql)
  n_before <- nrow(rows)
  rows <- rows[exclude_by_credential(rows$credential), ]
  rows$vintage <- v$vintage
  cat(sprintf("%s: %s midwife rows (%s dropped as MD/DO), %s distinct NPIs\n",
              v$vintage, format(nrow(rows), big.mark = ","),
              n_before - nrow(rows), format(length(unique(rows$npi)), big.mark = ",")))
  all_out[[v$vintage]] <- rows
}

stopifnot(file.exists(WAREHOUSE))
dbExecute(con, sprintf("ATTACH %s AS wh (READ_ONLY)", dbQuoteString(con, WAREHOUSE)))

for (v in WAREHOUSE_VINTAGES) {
  if (!is.null(v$tables)) {
    qtable <- sprintf("(%s)", paste(sprintf("SELECT * FROM wh.%s", vapply(v$tables, function(t) dbQuoteIdentifier(con, t), character(1))),
                                     collapse = " UNION ALL "))
  } else {
    qtable <- sprintf("wh.%s", dbQuoteIdentifier(con, v$table))
  }
  have <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", qtable)))

  col_npi   <- col_find(have, "^npi$")
  col_last  <- col_find(have, c("^lst_nm$", "^last name$", "^provider last name$"))
  col_first <- col_find(have, c("^frst_nm$", "^first name$", "^provider first name$"))
  col_cred  <- col_find(have, c("^cred(ential)?$"))
  col_spec  <- col_find(have, c("^pri_spec$", "^primary specialty$"))
  col_sec   <- col_find(have, c("^sec_spec_all$", "^all secondary specialties$"))
  col_addr  <- col_find(have, c("^adr_ln_1$", "^line 1 street address$"))
  col_city  <- col_find(have, c("^cty$", "^city$", "^city/town$"))
  col_state <- col_find(have, c("^st$", "^state$"))
  col_zip   <- col_find(have, c("^zip$", "^zip code$"))
  col_ccn <- vapply(1:5, function(i) col_find(have, c(sprintf("^hosp_afl_%d$", i), sprintf("^hospital affiliation ccn %d$", i)), required = FALSE), character(1))

  ccn_select <- ifelse(is.na(col_ccn), sprintf("CAST(NULL AS VARCHAR) AS ccn_%d", 1:5),
                        sprintf("%s AS ccn_%d", vapply(col_ccn, function(c) if (is.na(c)) "" else dbQuoteIdentifier(con, c), character(1)), 1:5))

  sql <- sprintf(r"(
    SELECT %s AS npi,
           UPPER(TRIM(%s))                              AS last_name,
           UPPER(TRIM(%s))                              AS first_name,
           UPPER(TRIM(COALESCE(%s, '')))                AS credential,
           UPPER(TRIM(%s))                              AS primary_specialty,
           UPPER(TRIM(COALESCE(%s, '')))                AS secondary_specialties,
           UPPER(TRIM(COALESCE(%s, '')))                AS practice_address,
           UPPER(TRIM(COALESCE(%s, '')))                AS practice_city,
           UPPER(TRIM(COALESCE(%s, '')))                AS practice_state,
           SUBSTR(TRIM(COALESCE(CAST(%s AS VARCHAR), '')), 1, 5) AS practice_zip,
           %s
    FROM %s
    WHERE UPPER(COALESCE(%s, '')) LIKE '%%MIDWIFE%%'
       OR UPPER(COALESCE(%s, ''))  LIKE '%%MIDWIFE%%')",
    dbQuoteIdentifier(con, col_npi), dbQuoteIdentifier(con, col_last), dbQuoteIdentifier(con, col_first),
    dbQuoteIdentifier(con, col_cred), dbQuoteIdentifier(con, col_spec), dbQuoteIdentifier(con, col_sec),
    dbQuoteIdentifier(con, col_addr), dbQuoteIdentifier(con, col_city), dbQuoteIdentifier(con, col_state),
    dbQuoteIdentifier(con, col_zip), paste(ccn_select, collapse = ",\n           "), qtable,
    dbQuoteIdentifier(con, col_spec), dbQuoteIdentifier(con, col_sec))

  rows <- dbGetQuery(con, sql)
  rows$npi <- as.character(rows$npi)
  n_before <- nrow(rows)
  rows <- rows[exclude_by_credential(rows$credential), ]
  rows$vintage <- v$vintage
  cat(sprintf("%s: %s midwife rows (%s dropped as MD/DO), %s distinct NPIs%s\n",
              v$vintage, format(nrow(rows), big.mark = ","),
              n_before - nrow(rows), format(length(unique(rows$npi)), big.mark = ","),
              if (all(is.na(col_ccn))) " [no CCN columns this vintage]" else ""))
  all_out[[v$vintage]] <- rows
}

out <- bind_rows(all_out)
write_csv(out, "artifacts/physician_compare_historical_midwives.csv", na = "")
cat(sprintf("\nwrote %s rows across %d vintages to artifacts/physician_compare_historical_midwives.csv\n",
            format(nrow(out), big.mark = ","), length(VINTAGES) + length(WAREHOUSE_VINTAGES)))
