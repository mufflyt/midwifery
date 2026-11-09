#!/usr/bin/env Rscript
# =============================================================================
# Load one Open Payments general-payments program year into the merged warehouse
# =============================================================================
# Source: CMS Open Payments bulk general-payment file for a single program
# year, e.g.
#   https://download.cms.gov/openpayments/PGYR2025_P06302026_06032026/
#     OP_DTL_GNRL_PGYR2025_P06302026_06032026.csv  (9.2 GB, PY2025)
# Target: open_payments_merged_2013_2024.duckdb, which holds op_2013..op_2024
# as one table per program year. This script adds op_<year> in that shape.
#
# THE WAREHOUSE FILENAME UNDERSTATES ITS CONTENTS ONCE THIS RUNS. It is called
# _2013_2024 and, after loading PY2025, no longer stops at 2024. Renaming a
# 21.8 GB file that other scripts resolve by name is a bigger change than this
# one, so the discrepancy is recorded here rather than papered over.
#
# THE SCHEMA IS PINNED TO THE PREVIOUS YEAR, NOT RE-INFERRED. read_csv_auto on
# a 9.2 GB file samples to guess types, and a year whose sample happens to
# differ would land a table that looks like its siblings and will not UNION
# with them. This script copies op_<year-1>'s exact column names, order and
# types and refuses to run if the new file disagrees -- a schema change is
# something to look at, not something to auto-adapt to.
#
# strict_mode = false, NOT ignore_errors = true. CMS's PY2025 file is not
# valid CSV: line 3123 carries Contextual_Information = "2025 Summary""", an
# odd number of quotes that a typed read rejects outright. ignore_errors would
# also accept the file -- by SKIPPING the row and reporting success, which on
# a file this size nobody would notice. strict_mode = false relaxes only
# RFC-4180 quoting and still fails loudly on everything else. Verified on
# PY2025: 16,131,856 rows either way, that record present and correct under
# both (NPI 1447493820, $192.12).
#
# Inputs : OPEN_PAYMENTS_YEAR (env var, e.g. 2025 -- required)
#          OPEN_PAYMENTS_CSV  (env var; default is the per-year raw layout
#            <volume>/open_payments_data/<year>/unzipped_files/*.csv)
#          OPEN_PAYMENTS_DB   (env var; default is the merged warehouse)
# Output : table op_<year> in the Open Payments warehouse
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb)
})

source(file.path("R", "lib", "medicare_duckdb.R"))

YEAR <- Sys.getenv("OPEN_PAYMENTS_YEAR", "")
if (!grepl("^[0-9]{4}$", YEAR))
  stop("Set OPEN_PAYMENTS_YEAR to the 4-digit program year, e.g. OPEN_PAYMENTS_YEAR=2025.",
       call. = FALSE)
YEAR <- as.integer(YEAR)
TBL  <- sprintf("op_%d", YEAR)
PREV <- sprintf("op_%d", YEAR - 1L)

DB <- Sys.getenv("OPEN_PAYMENTS_DB", "")
if (!nzchar(DB)) {
  DB <- samsung_volume_path(file.path("open_payments_data",
                                      "open_payments_merged_2013_2024.duckdb"),
                            must_exist = FALSE)
}
if (is.na(DB) || !nzchar(DB) || !file.exists(DB))
  stop(paste0("Open Payments warehouse not found. Set OPEN_PAYMENTS_DB to it.\n",
              "  Refusing to continue: dbConnect() would CREATE an empty database and\n",
              "  every later query would return zero rows."), call. = FALSE)

SRC <- Sys.getenv("OPEN_PAYMENTS_CSV", "")
if (!nzchar(SRC)) {
  hits <- Sys.glob(file.path(dirname(DB), as.character(YEAR), "unzipped_files",
                             sprintf("OP_DTL_GNRL_PGYR%d_*.csv", YEAR)))
  if (length(hits) == 1L) SRC <- hits
  else if (length(hits) > 1L)
    stop(sprintf("%d candidate PY%d files; set OPEN_PAYMENTS_CSV explicitly:\n  %s",
                 length(hits), YEAR, paste(hits, collapse = "\n  ")), call. = FALSE)
}
if (!nzchar(SRC) || !file.exists(SRC))
  stop(sprintf(paste0("Open Payments PY%d CSV not found. Set OPEN_PAYMENTS_CSV.\n",
                      "  CMS publishes program year N around June of N+1; check\n",
                      "  https://openpaymentsdata.cms.gov before assuming a year exists."),
               YEAR), call. = FALSE)

con <- tryCatch(
  duckdb_connect(DB, read_only = FALSE),
  error = function(e)
    stop(sprintf(paste0("Could not open %s for writing: %s\nDuckDB allows one writer ",
                        "at a time and this warehouse is shared. Close the other ",
                        "session's connection, or set OPEN_PAYMENTS_DB."),
                 DB, conditionMessage(e)), call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

tables <- dbListTables(con)
if (TBL %in% tables)
  stop(sprintf("%s already exists in %s. Drop it deliberately if you mean to reload.",
               TBL, DB), call. = FALSE)
if (!PREV %in% tables)
  stop(sprintf(paste0("%s is not in %s, so there is no schema to pin to.\n",
                      "  This script deliberately does not infer a schema for a 9 GB file."),
               PREV, DB), call. = FALSE)

prev_cols <- dbGetQuery(con, sprintf(
  "SELECT column_name, data_type FROM duckdb_columns()
    WHERE table_name = %s ORDER BY column_index", dbQuoteString(con, PREV)))

# The header is read on its own first: a mismatch should be reported before
# nine gigabytes are parsed, not after.
hdr <- names(dbGetQuery(con, sprintf(
  "SELECT * FROM read_csv_auto(%s, all_varchar = TRUE, sample_size = 1) LIMIT 0",
  dbQuoteString(con, SRC))))
if (!identical(hdr, prev_cols$column_name)) {
  only_new <- setdiff(hdr, prev_cols$column_name)
  only_old <- setdiff(prev_cols$column_name, hdr)
  stop(sprintf(paste0("PY%d's columns do not match %s.\n  only in the new file: %s\n",
                      "  only in %s: %s\n  (order differs if both lists are empty)\n",
                      "  CMS changed the layout; look at it rather than loading a table\n",
                      "  that will not UNION with its siblings."),
               YEAR, PREV, if (length(only_new)) paste(only_new, collapse = ", ") else "<none>",
               PREV, if (length(only_old)) paste(only_old, collapse = ", ") else "<none>"),
       call. = FALSE)
}
cat(sprintf("schema check: PY%d matches %s exactly (%d columns, same order)\n",
            YEAR, PREV, nrow(prev_cols)))

cols_sql <- paste(sprintf("%s: %s",
                          dbQuoteString(con, prev_cols$column_name),
                          dbQuoteString(con, prev_cols$data_type)), collapse = ", ")

cat(sprintf("loading %s from %s (%.1f GB) ...\n", TBL, SRC, file.size(SRC) / 1e9))
invisible(dbExecute(con, sprintf(
  "CREATE TABLE %s AS SELECT * FROM read_csv(%s, header = true, columns = {%s}, strict_mode = false)",
  dbQuoteIdentifier(con, TBL), dbQuoteString(con, SRC), cols_sql)))

n      <- dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", dbQuoteIdentifier(con, TBL)))$n
n_prev <- dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", dbQuoteIdentifier(con, PREV)))$n
cat(sprintf("verification (read back from the warehouse): %s rows (%s has %s)\n",
            format(n, big.mark = ",", scientific = FALSE), PREV, format(n_prev, big.mark = ",", scientific = FALSE)))

# One program year should not be a small multiple of its neighbour. This will
# not catch a subtle loss, but it does catch a truncated download, which is the
# realistic failure for a 9 GB file over a home connection.
if (n < n_prev / 2 || n > n_prev * 2)
  warning(sprintf(paste0("%s has %s rows against %s's %s -- more than a factor of two ",
                         "apart. Check the download completed before trusting this table."),
                  TBL, format(n, big.mark = ",", scientific = FALSE), PREV, format(n_prev, big.mark = ",", scientific = FALSE)),
          call. = FALSE)
