#!/usr/bin/env Rscript
# =============================================================================
# Sub-annual NPPES practice-state panel, from raw monthly dissemination
# archives already on the external drive
# =============================================================================
# midwife_panel.csv carries one NPPES row per (npi, calendar year) -- a
# single snapshot month per year. The external drive already holds ~20
# raw monthly NPPES_Data_Dissemination_*.zip archives (2007-2026), never
# extracted at that resolution. Built to let the 2017-18/2023-24 NPPES
# migration spikes (and the 2020-21 signal docs/TECHNICAL_APPENDIX_
# TRUTH_FUSION_MIGRATION.md S4 surfaced) be checked for WHEN within a
# year they actually happened -- something an annual panel cannot answer.
#
# TWO-STAGE BY NECESSITY. Streaming each multi-GB zip through `unzip -p |
# grep -F` and letting THIS script orchestrate it directly (via system()/
# system2()) hung indefinitely, reproducibly, every time -- but the
# identical shell commands run in the plain foreground (not backgrounded,
# not invoked from inside an R process) finished in seconds every time.
# Root cause never identified (ruled out: command construction, TMPDIR
# location, pattern-file existence/content, a standalone .sh script
# instead of an inline string) -- consistent with something about this
# sandbox's handling of backgrounded or R-spawned subprocess I/O against
# this specific external volume, not a bug in the extraction logic
# itself. Stage 1 (grep-filtering each archive to this cohort's ~16,775
# NPIs) was therefore run directly in the foreground, outside R entirely,
# writing nppes_header_<vintage>.csv / nppes_body_<vintage>.csv per
# vintage to the scratchpad. This script is Stage 2: pure R file I/O,
# no subprocess calls, reads those already-filtered files plus 4
# vintages (2020-07, 2021-04, 2022-04, 2026-02) that turned out to
# already be fully ingested in nber_my_duckdb.duckdb (found while
# debugging the hang) and queries those directly via SQL instead.
#
# 2 of the 31 zip archives attempted (2009-04, 2013-12) are themselves
# corrupted ("End-of-central-directory signature not found") -- a real
# unzip error, reported instantly, not a hang; skipped.
#
# Entity Type Code == "2" (organizations) rows are dropped -- this cohort
# is individual clinicians (Type 1) throughout the rest of this repo.
# Column names are stable across every era checked (2008/2017/2026 share
# byte-identical headers for the fields this script reads) even though
# total column COUNT grows over time (added taxonomy slots) -- selected
# by NAME via each vintage's own header row, never by fixed position.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          scratchpad/nppes_header_<vintage>.csv, nppes_body_<vintage>.csv
#            (written by the foreground extraction pass -- rerun that
#            pass, see docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md,
#            before re-running this script from a clean checkout)
#          /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb (4 vintages)
# Output : artifacts/nppes_subannual_panel.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(DBI); library(duckdb)})
source(file.path("R", "lib", "clean_state.R"))

TMP_DIR <- Sys.getenv("CLAUDE_SCRATCHPAD",
                       "/private/tmp/claude-501/-Users-tmuffly-midwifery/256ea951-7544-4ed5-b0ec-edd5104f0d91/scratchpad")
WAREHOUSE <- "/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb"
WAREHOUSE_VINTAGES <- list(
  list(vintage = "2020-07", table = "NPPES_Data_Dissemination_July_2020_npidata_pfile_20050523_20200712_csv"),
  list(vintage = "2021-04", table = "NPPES_Data_Disseminat_April_2021_npidata_pfile_20050523_20210411_csv"),
  list(vintage = "2022-04", table = "NPPES_Data_Disseminat_April_2022_npidata_pfile_20050523_20220410_csv"),
  list(vintage = "2026-02", table = "NPPES_Data_Dissemination_February_2026_npidata_pfile_20050523_20260208_csv")
)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>% filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(link), big.mark = ",")))

pick <- function(have, ...) { opts <- c(...); hit <- opts[opts %in% have]; if (!length(hit)) return(NULL); hit[1] }

extract_one_from_warehouse <- function(table, vintage) {
  con <- dbConnect(duckdb(), WAREHOUSE, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  have <- names(dbGetQuery(con, sprintf("SELECT * FROM %s LIMIT 0", dbQuoteIdentifier(con, table))))
  col_npi <- pick(have, "NPI"); col_entity <- pick(have, "Entity Type Code")
  col_addr <- pick(have, "Provider First Line Business Practice Location Address")
  col_city <- pick(have, "Provider Business Practice Location Address City Name")
  col_state <- pick(have, "Provider Business Practice Location Address State Name")
  col_zip <- pick(have, "Provider Business Practice Location Address Postal Code")
  col_deact <- pick(have, "NPI Deactivation Date")
  sql <- sprintf(r"(
    SELECT %s AS npi, %s AS practice_address, %s AS practice_city,
           %s AS practice_state, %s AS practice_zip, %s AS deactivation_date
    FROM %s WHERE %s = '1')",
    dbQuoteIdentifier(con, col_npi), dbQuoteIdentifier(con, col_addr), dbQuoteIdentifier(con, col_city),
    dbQuoteIdentifier(con, col_state), dbQuoteIdentifier(con, col_zip), dbQuoteIdentifier(con, col_deact),
    dbQuoteIdentifier(con, table), dbQuoteIdentifier(con, col_entity))
  rows <- dbGetQuery(con, sql)
  out <- rows %>% filter(trimws(npi) %in% link$npi) %>%
    transmute(npi = trimws(npi), vintage = vintage, practice_address, practice_city,
              practice_state = clean_state(practice_state), practice_zip = substr(practice_zip, 1, 5),
              deactivation_date = as.character(deactivation_date))
  cat(sprintf("  %s: %s cohort rows (warehouse)\n", vintage, format(nrow(out), big.mark = ",")))
  out
}

extract_one_from_files <- function(vintage) {
  header_file <- file.path(TMP_DIR, sprintf("nppes_header_%s.csv", vintage))
  body_file <- file.path(TMP_DIR, sprintf("nppes_body_%s.csv", vintage))
  if (!file.exists(header_file) || !file.exists(body_file)) {
    cat(sprintf("  %s: no pre-extracted files found, skipped\n", vintage)); return(NULL)
  }
  if (file.size(body_file) == 0) { cat(sprintf("  %s: 0 cohort rows matched, skipped\n", vintage)); return(NULL) }
  header <- names(read_csv(header_file, n_max = 0, col_types = cols(.default = "c"), progress = FALSE))
  body <- read_csv(body_file, col_names = header, col_types = cols(.default = "c"), progress = FALSE)

  col_npi <- pick(names(body), "NPI"); col_entity <- pick(names(body), "Entity Type Code")
  col_addr <- pick(names(body), "Provider First Line Business Practice Location Address")
  col_city <- pick(names(body), "Provider Business Practice Location Address City Name")
  col_state <- pick(names(body), "Provider Business Practice Location Address State Name")
  col_zip <- pick(names(body), "Provider Business Practice Location Address Postal Code")
  col_deact <- pick(names(body), "NPI Deactivation Date")

  out <- body %>%
    filter(.data[[col_entity]] == "1", .data[[col_npi]] %in% link$npi) %>%
    transmute(npi = trimws(.data[[col_npi]]), vintage = vintage,
              practice_address = .data[[col_addr]], practice_city = .data[[col_city]],
              practice_state = clean_state(.data[[col_state]]), practice_zip = substr(.data[[col_zip]], 1, 5),
              deactivation_date = .data[[col_deact]])
  cat(sprintf("  %s: %s cohort rows\n", vintage, format(nrow(out), big.mark = ",")))
  out
}

zip_vintages <- str_match(list.files(TMP_DIR, pattern = "^nppes_header_.*\\.csv$"), "^nppes_header_(.*)\\.csv$")[, 2]
zip_vintages <- sort(zip_vintages[!is.na(zip_vintages)])
cat(sprintf("Pre-extracted zip vintages found in scratchpad: %d\n", length(zip_vintages)))

all_out <- list()
for (v in WAREHOUSE_VINTAGES) all_out[[v$vintage]] <- extract_one_from_warehouse(v$table, v$vintage)
for (v in zip_vintages) all_out[[v]] <- extract_one_from_files(v)

out <- bind_rows(all_out)
write_csv(out, "artifacts/nppes_subannual_panel.csv", na = "")
cat(sprintf("\nwrote %s rows across %d vintages to artifacts/nppes_subannual_panel.csv\n",
            format(nrow(out), big.mark = ","), length(unique(out$vintage))))
