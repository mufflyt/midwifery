#!/usr/bin/env Rscript
# =============================================================================
# Load a CMS Facility Affiliation snapshot into DuckDB, tagged by its vintage
# =============================================================================
# Source: CMS provider data catalog, "Facility Affiliation Data"
# (data.cms.gov/provider-data), the CCN<->NPI bridge behind every
# hospital-affiliation question in this project.
#
# CMS PUBLISHES ONE SNAPSHOT, NOT A SERIES, which is the whole reason this
# script tags. There is exactly one Facility Affiliation dataset in the
# provider-data catalog (checked 2026-11-09 across all 237 datasets) and no
# dated archives: the file is always-current and silently replaced. 2023-2025
# cannot be recovered from it, nor from the DAC files, whose embedded CCN
# columns CMS dropped starting 2023 -- see
# docs/TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md section 2.
#
# SO IT MUST NOT BE APPENDED TO `facility_affiliation`. That table holds
# 1,577,099 rows with NO vintage column, so its own snapshot date is already
# unrecoverable; appending a second snapshot would blend two undated
# populations with no way back. Each load lands in its own
# facility_affiliation_<YYYY_MM> table carrying `vintage` and `cms_modified`,
# matching the warehouse's existing physician_compare_<year>_Q2 convention.
#
# THE VINTAGE IS THE FILE'S, NOT TODAY'S. CMS's current snapshot is modified
# 2026-10-02; elsewhere this repo expects a doctors_and_clinicians_2026_06
# path. Naming a 2026-10 file _06 would misstate provenance, so the date comes
# from FACILITY_AFFILIATION_VINTAGE (or CMS's own modified date), never the
# clock.
#
# Inputs : FACILITY_AFFILIATION_CSV (env var; default is the 2026-10 download
#            under the Samsung volume)
#          FACILITY_AFFILIATION_VINTAGE (env var, YYYY-MM; parsed from the
#            filename when unset)
# Output : table facility_affiliation_<YYYY_MM> in the DuckDB warehouse
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(stringr)
})

source(file.path("R", "lib", "medicare_duckdb.R"))

DB <- Sys.getenv("FACILITY_AFFILIATION_DB", "")
if (!nzchar(DB)) DB <- resolve_midwifery_duckdb()

SRC <- Sys.getenv("FACILITY_AFFILIATION_CSV", "")
if (!nzchar(SRC)) {
  SRC <- samsung_volume_path(file.path("facility_affiliation",
                                       "doctors_and_clinicians_2026_10",
                                       "Facility_Affiliation_2026-10.csv"),
                             must_exist = FALSE)
}
if (is.na(SRC) || !nzchar(SRC) || !file.exists(SRC)) {
  stop(paste0("Facility Affiliation CSV not found.\n",
              "  Set FACILITY_AFFILIATION_CSV, or download the current snapshot from\n",
              "  https://data.cms.gov/provider-data/dataset/27ea-46a8 and save it as\n",
              "  <volume>/facility_affiliation/doctors_and_clinicians_<YYYY_MM>/",
              "Facility_Affiliation_<YYYY-MM>.csv"), call. = FALSE)
}

VINTAGE <- Sys.getenv("FACILITY_AFFILIATION_VINTAGE", "")
if (!nzchar(VINTAGE)) VINTAGE <- str_match(basename(SRC), "(\\d{4})-(\\d{2})")[, 1]
if (is.na(VINTAGE) || !str_detect(VINTAGE, "^\\d{4}-\\d{2}$")) {
  stop(sprintf(paste0("Could not determine the snapshot vintage from %s.\n",
                      "  Set FACILITY_AFFILIATION_VINTAGE=YYYY-MM. Guessing it, or using\n",
                      "  today's date, would misdate a silently-replaced CMS file."),
               basename(SRC)), call. = FALSE)
}
TBL <- paste0("facility_affiliation_", str_replace(VINTAGE, "-", "_"))

con <- tryCatch(
  duckdb_connect(DB, read_only = FALSE),
  error = function(e)
    stop(sprintf(paste0("Could not open %s for writing: %s\nDuckDB allows one ",
                        "writer at a time and this warehouse is shared. Close the ",
                        "other session's connection, or set FACILITY_AFFILIATION_DB ",
                        "to a different file."), DB, conditionMessage(e)), call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

if (TBL %in% dbListTables(con)) {
  stop(sprintf(paste0("%s already exists in %s.\n  Refusing to overwrite a loaded ",
                      "snapshot: drop it deliberately first if that is what you want."),
               TBL, DB), call. = FALSE)
}

# Column names are mapped to the 9 that `facility_affiliation` already uses, so
# the dated tables and the undated one can be UNIONed without renaming at every
# call site. All character: CCNs and NPIs are identifiers, and a CCN read as a
# number loses its leading zeros.
invisible(dbExecute(con, sprintf(
  "CREATE TABLE %s AS
   SELECT \"NPI\"                                        AS npi,
          \"Ind_PAC_ID\"                                 AS pac_id,
          \"Provider Last Name\"                         AS last_name,
          \"Provider First Name\"                        AS first_name,
          \"Provider Middle Name\"                       AS middle_name,
          \"suff\"                                       AS suffix,
          \"facility_type\"                              AS facility_type,
          \"Facility Affiliations Certification Number\" AS facility_cert_number,
          \"Facility Type Certification Number\"         AS facility_type_cert_number,
          %s                                             AS vintage
     FROM read_csv_auto(%s, all_varchar = TRUE, sample_size = -1)",
  dbQuoteIdentifier(con, TBL), dbQuoteString(con, VINTAGE), dbQuoteString(con, SRC))))

n     <- dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", dbQuoteIdentifier(con, TBL)))$n
n_npi <- dbGetQuery(con, sprintf("SELECT COUNT(DISTINCT npi) AS n FROM %s", dbQuoteIdentifier(con, TBL)))$n
n_ccn <- dbGetQuery(con, sprintf("SELECT COUNT(DISTINCT facility_cert_number) AS n FROM %s", dbQuoteIdentifier(con, TBL)))$n
n_null <- dbGetQuery(con, sprintf(
  "SELECT SUM(CASE WHEN npi IS NULL OR facility_cert_number IS NULL THEN 1 ELSE 0 END) AS n FROM %s",
  dbQuoteIdentifier(con, TBL)))$n

cat(sprintf("loaded %s from %s\n", TBL, SRC))
cat(sprintf("verification (read back from the warehouse): %s rows, %s distinct NPIs, %s distinct CCNs\n",
            format(n, big.mark = ",", scientific = FALSE), format(n_npi, big.mark = ","), format(n_ccn, big.mark = ",")))

# The join key is the whole point of this table; a null in it is not a row with
# a missing field, it is a row that can never be used.
if (!is.na(n_null) && n_null > 0) {
  stop(sprintf("%s has %s row(s) with a NULL npi or facility_cert_number -- the join key itself.",
               TBL, format(n_null, big.mark = ",")), call. = FALSE)
}
cat("join keys (npi, facility_cert_number): no NULLs\n")
