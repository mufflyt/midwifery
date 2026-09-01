#!/usr/bin/env Rscript
# =============================================================================
# Load CDC/NCHS natality artifacts into DuckDB
# =============================================================================
# Loads the WONDER-derived natality tables this project already builds into the
# warehouse so births can be joined to midwife supply in SQL rather than by
# re-reading CSVs in every script.
#
# THESE ARE AGGREGATES, NOT THE NATALITY MICRODATA. CDC WONDER natality is
# pre-tabulated and SUPPRESSED: county cells below 10 births are withheld, and
# WONDER publishes county natality only for counties of 100,000+ residents,
# pooling the rest by state. A county absent from the CNM table therefore has
# UNPUBLISHED midwife-attended births, not zero. The suppressed flag is carried
# through so no downstream join can silently read absence as zero -- the same
# error this repository has made three times.
#
# WRITE SAFETY. The warehouse is shared with other sessions. DuckDB takes an
# exclusive lock for writes, so this fails loudly if another process holds it
# rather than waiting or corrupting; re-run when the other session is idle.
# Set NATALITY_DB to write somewhere else instead.
#
# Inputs : data/wonder/natality_2016_2024_cnm_by_county.csv
#          artifacts/wonder/national_births_by_attendant_year.csv
#          artifacts/county_profiles/county_cnm_births.csv
# Output : tables natality_* in the DuckDB
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(dplyr); library(readr); library(stringr)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
DB <- Sys.getenv("NATALITY_DB", "")
if (!nzchar(DB)) DB <- resolve_midwifery_duckdb()

SRC <- list(
  natality_cnm_by_county_2016_2024 = "data/wonder/natality_2016_2024_cnm_by_county.csv",
  natality_births_by_attendant_year = "artifacts/wonder/national_births_by_attendant_year.csv",
  natality_county_cnm_births        = "artifacts/county_profiles/county_cnm_births.csv"
)
missing <- SRC[!file.exists(unlist(SRC))]
if (length(missing))
  stop(sprintf("Missing natality input(s): %s",
               paste(unlist(missing), collapse = ", ")), call. = FALSE)

con <- tryCatch(
  dbConnect(duckdb::duckdb(), DB, read_only = FALSE),
  error = function(e)
    stop(sprintf(paste0("Could not open %s for writing: %s\nDuckDB allows one ",
                        "writer at a time and this warehouse is shared. Close ",
                        "the other session's connection, or set NATALITY_DB to ",
                        "a different file."), DB, conditionMessage(e)),
         call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (tbl in names(SRC)) {
  f <- SRC[[tbl]]
  # Read every column as character: a FIPS code read as a number loses its
  # leading zero, which silently turns 01001 into 1001 and breaks every join.
  d <- read_csv(f, show_col_types = FALSE, progress = FALSE,
                col_types = cols(.default = col_character()))
  names(d) <- names(d) %>% str_replace_all("[^A-Za-z0-9]+", "_") %>%
    str_replace("^_+|_+$", "") %>% tolower()
  dbWriteTable(con, tbl, d, overwrite = TRUE)
  cat(sprintf("loaded %-36s %6s rows x %2d cols\n", tbl,
              format(nrow(d), big.mark = ","), ncol(d)))
}

cat("\nverification (read back from the warehouse):\n")
for (tbl in names(SRC)) {
  n <- dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", tbl))$n
  cat(sprintf("  %-36s %6s rows\n", tbl, format(n, big.mark = ",")))
}

sup <- dbGetQuery(con, "
  SELECT COUNT(*) AS counties,
         SUM(CASE WHEN suppressed = 'TRUE' THEN 1 ELSE 0 END) AS suppressed,
         SUM(CASE WHEN NULLIF(TRIM(cnm_births_2016_2024), '') IS NULL
                  THEN 1 ELSE 0 END) AS no_cnm_value
    FROM natality_county_cnm_births")
cat(sprintf("\ncounties: %s | flagged suppressed: %s | no CNM birth value: %s\n",
            format(sup$counties, big.mark = ","),
            format(sup$suppressed, big.mark = ","),
            format(sup$no_cnm_value, big.mark = ",")))
cat("A county with no CNM value has UNPUBLISHED midwife-attended births, not zero.\n")
