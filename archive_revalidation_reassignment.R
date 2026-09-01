#!/usr/bin/env Rscript
#' @title Download and warehouse CMS Revalidation Group Practice Reassignment
#'
#' @description
#' Downloads every monthly release, KEEPS the raw CSV, and loads it into a
#' persistent DuckDB warehouse as one table with a `vintage` column.
#'
#' Two products come out of this:
#'
#'   raw CSVs      REVAL_RAW_DIR/revalidation_reassignment_YYYY-MM.csv
#'   warehouse     REVAL_DB, table `revalidation_reassignment`
#'
#' Keeping the raw file matters. A derived extract cannot be re-cut for a
#' different cohort, a different specialty, or a column nobody wanted at the
#' time, and CMS does not guarantee an old month stays downloadable. The raw
#' file is the primary source; the warehouse is a convenience over it.
#'
#' @section Why a warehouse and not 39 CSVs:
#' The panel question is "which group, for which NPI, in which month" across
#' ~39 monthly files of ~537 MB. As loose CSVs every query re-parses 21 GB.
#' Loaded once into DuckDB, the same query is a scan of a columnar table.
#'
#' @section Idempotent by design:
#' A vintage already on disk is not re-downloaded, and a vintage already in the
#' warehouse is not re-ingested. Re-running is cheap and safe, which is what
#' makes it usable as a monthly cron.
#'
#' @section What a snapshot series can and cannot date:
#' A relationship present in March and absent in April disappeared BETWEEN
#' those snapshots. It did not end on 1 April. First and last appearance are
#' BOUNDS, not dates. See DECISIONS_CONTRACT.md.
#'
#' @section Disk:
#' ~537 MB per release, ~21 GB for the full series, so both the raw directory
#' and the database default to the external volume. The internal disk has 12 GB
#' free and would fill.
#'
#' Usage:
#'   Rscript archive_revalidation_reassignment.R           # everything missing
#'   REVAL_LIMIT=3 Rscript archive_revalidation_reassignment.R
#'   REVAL_RAW_DIR=... REVAL_DB=... Rscript archive_revalidation_reassignment.R
#'
#' @family organization-linkage
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(jsonlite); library(DBI)
  library(duckdb); library(cli)
})

`%||%` <- function(a, b) if (is.null(a)) b else a

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)

source(file.path("R", "lib", "medicare_duckdb.R"))
RAW_DIR <- Sys.getenv("REVAL_RAW_DIR", "")
if (!nzchar(RAW_DIR)) RAW_DIR <- samsung_volume_path("cms_revalidation_raw")
# The archive is CREATED here on a first run, so it must NOT be required to
# exist. What must exist is the volume, which RAW_DIR has just located; the
# archive is written beside it rather than at a second guessed spelling.
DB_PATH <- Sys.getenv("REVAL_DB", "")
if (!nzchar(DB_PATH))
  DB_PATH <- file.path(dirname(RAW_DIR), "cms_revalidation.duckdb")
TBL     <- "revalidation_reassignment"
LIMIT   <- suppressWarnings(as.integer(Sys.getenv("REVAL_LIMIT", NA)))

if (!dir.exists(dirname(DB_PATH))) {
  stop(sprintf(paste("the volume for REVAL_DB is not mounted: %s\n",
                     "  Set REVAL_RAW_DIR and REVAL_DB, or mount the drive.\n",
                     "  Refusing to write ~21 GB to the internal disk, which",
                     "has 12 GB free."), dirname(DB_PATH)), call. = FALSE)
}
dir.create(RAW_DIR, showWarnings = FALSE, recursive = TRUE)

# =============================================================================
# 1. DISCOVER the monthly releases from the CMS catalogue
# =============================================================================
cli::cli_h2("CMS catalogue")
cat_json <- jsonlite::fromJSON("https://data.cms.gov/data.json", simplifyVector = FALSE)
target <- Filter(function(x)
  identical(x$title, "Revalidation Clinic Group Practice Reassignment"),
  cat_json$dataset)
if (!length(target)) {
  stop("dataset not found in the CMS catalogue. Refusing to proceed rather ",
       "than warehouse nothing and report success.", call. = FALSE)
}

urls <- unlist(lapply(target[[1]]$distribution, function(d) {
  u <- d$downloadURL %||% ""
  if (grepl("\\.csv$", u)) u else NULL
}))
vintage_of <- function(u) sub(".*/files/([0-9]{4}-[0-9]{2})/.*", "\\1", u)

rel <- tibble::tibble(url = urls, vintage = vintage_of(urls)) %>%
  # Some months list two distributions of the same release. Keeping both would
  # double every count for that month in any panel built from the warehouse.
  distinct(vintage, .keep_all = TRUE) %>%
  arrange(desc(vintage))
cli::cli_alert_success("{nrow(rel)} monthly releases, {min(rel$vintage)} to {max(rel$vintage)}")

# =============================================================================
# 2. DOWNLOAD, keeping the raw file
# =============================================================================
raw_path <- function(v) file.path(RAW_DIR, sprintf("revalidation_reassignment_%s.csv", v))

download_vintage <- function(v, url) {
  dest <- raw_path(v)
  if (file.exists(dest) && file.info(dest)$size > 1e6) {
    cli::cli_alert_info("{v}: raw already present ({round(file.info(dest)$size/1e6)} MB)")
    return(dest)
  }
  # Download to a partial name and rename on success, so an interrupted fetch
  # cannot leave a truncated file that later looks complete.
  part <- paste0(dest, ".part")
  ok <- tryCatch({
    utils::download.file(url, part, mode = "wb", quiet = TRUE); TRUE
  }, error = function(e) { cli::cli_alert_danger("{v}: {conditionMessage(e)}"); FALSE })
  if (!ok) { unlink(part); return(NULL) }
  if (file.info(part)$size < 1e6) {
    cli::cli_alert_danger("{v}: downloaded file is implausibly small; discarded")
    unlink(part); return(NULL)
  }
  file.rename(part, dest)
  cli::cli_alert_success("{v}: downloaded {round(file.info(dest)$size/1e6)} MB")
  dest
}

# =============================================================================
# 3. LOAD into the DuckDB warehouse
# =============================================================================
con <- dbConnect(duckdb::duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

already <- if (TBL %in% dbListTables(con)) {
  dbGetQuery(con, sprintf("SELECT DISTINCT vintage FROM %s", TBL))$vintage
} else character(0)
cli::cli_alert_info("warehouse holds {length(already)} vintage(s)")

ingest_vintage <- function(v, path) {
  # all_varchar keeps NPIs, PAC ids and enrollment ids as TEXT. Any of them
  # read as a number loses leading zeros and stops joining.
  src <- sprintf("read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)",
                 path)
  sel <- sprintf('
    SELECT TRIM(CAST("Individual NPI" AS VARCHAR))                    AS individual_npi,
           TRIM(CAST("Individual Enrollment ID" AS VARCHAR))          AS individual_enrlmt_id,
           TRIM(CAST("Individual First Name" AS VARCHAR))             AS individual_first_name,
           TRIM(CAST("Individual Last Name" AS VARCHAR))              AS individual_last_name,
           TRIM(CAST("Individual State Code" AS VARCHAR))             AS individual_state,
           TRIM(CAST("Individual Specialty Description" AS VARCHAR))  AS individual_specialty,
           TRIM(CAST("Individual Due Date" AS VARCHAR))               AS individual_revalidation_due,
           TRIM(CAST("Individual Total Employer Associations" AS VARCHAR))
                                                                      AS employer_association_count,
           TRIM(CAST("Group PAC ID" AS VARCHAR))                      AS group_pac_id,
           TRIM(CAST("Group Enrollment ID" AS VARCHAR))               AS group_enrlmt_id,
           TRIM(CAST("Group Legal Business Name" AS VARCHAR))         AS group_name,
           TRIM(CAST("Group State Code" AS VARCHAR))                  AS group_state,
           TRIM(CAST("Group Due Date" AS VARCHAR))                    AS group_revalidation_due,
           TRIM(CAST("Group Reassignments and Physician Assistants" AS VARCHAR))
                                                                      AS group_reassignment_count,
           TRIM(CAST("Record Type" AS VARCHAR))                       AS record_type,
           \'%s\' AS vintage
    FROM %s', v, src)

  if (!TBL %in% dbListTables(con)) {
    dbExecute(con, sprintf("CREATE TABLE %s AS %s", TBL, sel))
  } else {
    dbExecute(con, sprintf("INSERT INTO %s %s", TBL, sel))
  }
  dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s WHERE vintage = '%s'", TBL, v))$n
}

todo <- rel %>% filter(!vintage %in% already)
if (!is.na(LIMIT)) todo <- head(todo, LIMIT)
cli::cli_alert_info("to fetch and load: {nrow(todo)}")

for (i in seq_len(nrow(todo))) {
  v <- todo$vintage[i]
  cli::cli_alert_info("[{i}/{nrow(todo)}] {v}")
  p <- download_vintage(v, todo$url[i])
  if (is.null(p)) next

  n <- tryCatch(ingest_vintage(v, p),
                error = function(e) { cli::cli_alert_danger("{v}: {conditionMessage(e)}"); NA })
  if (is.na(n)) next
  # A national monthly reassignment file with no rows is a failed load, not a
  # month in which nobody reassigned.
  if (n == 0L) {
    cli::cli_alert_warning("{v}: loaded ZERO rows -- treating as a failed load")
    dbExecute(con, sprintf("DELETE FROM %s WHERE vintage = '%s'", TBL, v))
    next
  }
  cli::cli_alert_success("{v}: {format(n, big.mark = ',')} rows in the warehouse")
}

# =============================================================================
# 4. REPORT
# =============================================================================
if (TBL %in% dbListTables(con)) {
  s <- dbGetQuery(con, sprintf("
    SELECT vintage, COUNT(*) AS rows, COUNT(DISTINCT individual_npi) AS individuals,
           COUNT(DISTINCT group_pac_id) AS groups
    FROM %s GROUP BY vintage ORDER BY vintage", TBL))
  cli::cli_h2("Warehouse")
  print(as.data.frame(s), row.names = FALSE)
  cli::cli_alert_success("{DB_PATH} :: {TBL}")
  cli::cli_alert_info("raw CSVs kept in {RAW_DIR}")
}
