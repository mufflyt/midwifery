#!/usr/bin/env Rscript
# =============================================================================
# Load CMS's Revoked Medicare Providers and Suppliers file into DuckDB
# =============================================================================
# Source: CMS public data (opendata.hhs.gov), "Revoked Medicare Providers and
# Suppliers" -- a PECOS re-enrollment bar list, Medicare-specific (not
# Medicaid). NPI-keyed. This snapshot is dated as updated 2026-03-02.
#
# Loaded whole and unfiltered, same as load_natality_to_duckdb.R: this table
# is small (7,547 rows) and other scripts may want rows outside the current
# cohort, so the join to the frozen cohort happens in SQL against this table
# rather than by re-reading the CSV.
#
# Inputs : CMS_PECOS_REVOKED_CSV (env var; default
#          ~/Downloads/medicare-revoked-providers-and-suppliers.csv)
# Output : table cms_pecos_revoked_providers in the DuckDB warehouse
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(readr); library(stringr)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
DB <- Sys.getenv("PECOS_DB", "")
if (!nzchar(DB)) DB <- resolve_midwifery_duckdb()

SRC <- path.expand(Sys.getenv("CMS_PECOS_REVOKED_CSV",
                               "~/Downloads/medicare-revoked-providers-and-suppliers.csv"))
if (!file.exists(SRC)) {
  stop(sprintf("CMS PECOS revocation file not found at %s.\n  Set CMS_PECOS_REVOKED_CSV to its path.",
               SRC), call. = FALSE)
}

con <- tryCatch(
  duckdb_connect(DB, read_only = FALSE),
  error = function(e)
    stop(sprintf(paste0("Could not open %s for writing: %s\nDuckDB allows one ",
                        "writer at a time and this warehouse is shared. Close ",
                        "the other session's connection, or set PECOS_DB to a ",
                        "different file."), DB, conditionMessage(e)),
         call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# Every column as character: NPI and the enrollment ID are identifiers, not
# numbers, and a date read numerically here would lose its own format.
d <- read_csv(SRC, show_col_types = FALSE, progress = FALSE,
              col_types = cols(.default = col_character()))
names(d) <- names(d) %>% str_replace_all("[^A-Za-z0-9]+", "_") %>%
  str_replace("^_+|_+$", "") %>% tolower()

dbWriteTable(con, "cms_pecos_revoked_providers", d, overwrite = TRUE)
cat(sprintf("loaded %-28s %6s rows x %2d cols (source: %s)\n",
            "cms_pecos_revoked_providers", format(nrow(d), big.mark = ","),
            ncol(d), SRC))

n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM cms_pecos_revoked_providers")$n
n_npi <- dbGetQuery(con, "SELECT COUNT(DISTINCT npi) AS n FROM cms_pecos_revoked_providers")$n
cat(sprintf("verification (read back from the warehouse): %s rows, %s distinct NPIs\n",
            format(n, big.mark = ","), format(n_npi, big.mark = ",")))
