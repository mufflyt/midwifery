#!/usr/bin/env Rscript
# =============================================================================
# Load the FDA Debarment List (Drug Product Applications) into DuckDB
# =============================================================================
# Source: FDA's own public debarment list, published under FDCA section 306,
# for people barred from providing services to any company that has or seeks
# an FDA drug application. Download the current file from:
#
#   1. Open https://www.fda.gov/inspections-compliance-enforcement-and-criminal-investigations/compliance-actions-and-activities/fda-debarment-list-drug-product-applications
#   2. Follow the "Single Page Data Format" link under "Debarments (Drug
#      Applications)" -- an .xlsx, currently served from fda.gov/media/<id>
#      (the numeric media id changes with each FDA republish, so re-derive it
#      from the page rather than reusing an old direct link).
#   3. Save it locally and point FDA_DEBARMENT_XLSX at it, or leave it at the
#      default path below.
#
# This snapshot: "Data Format-Drug Applications (Oct 2, 2026).xlsx", 158 rows,
# downloaded 2026-10-26. The FIRMS section of that page reports "None as of
# this date" -- only individuals are current debarments right now.
#
# NAME-ONLY LIST. No NPI, no license number, no other identifier -- unlike the
# CMS NDH and CMS PECOS sources (load_cms_pecos_revocations_to_duckdb.R,
# match_cms_pecos_revocations.R), matching this against the cohort is a name
# match, not an NPI join. See match_fda_debarment.R for how that risk is
# contained.
#
# Inputs : FDA_DEBARMENT_XLSX (env var; default
#          ~/Downloads/fda_debarment_drug_applications.xlsx)
# Output : table fda_debarment_drug_applications in the DuckDB warehouse
# =============================================================================
suppressPackageStartupMessages({
  library(DBI); library(duckdb); library(readxl); library(dplyr); library(stringr)
})

source(file.path("R", "lib", "medicare_duckdb.R"))
DB <- Sys.getenv("FDA_DEBARMENT_DB", "")
if (!nzchar(DB)) DB <- resolve_midwifery_duckdb()

SRC <- path.expand(Sys.getenv("FDA_DEBARMENT_XLSX", "~/Downloads/fda_debarment_drug_applications.xlsx"))
if (!file.exists(SRC)) {
  stop(sprintf("FDA debarment file not found at %s.\n  Set FDA_DEBARMENT_XLSX to its path.",
               SRC), call. = FALSE)
}

# col_types = "text" on every column: FDA's own file mixes Excel-serial dates
# with typed strings like "01/04/2021" in the same column (confirmed on this
# snapshot -- readxl infers the whole column as character once it meets one),
# and at least one row has a malformed year ("10/5/20111"). Loading everything
# as the raw text FDA published, rather than guessing a date type and silently
# reformatting or discarding what doesn't parse, keeps this table honest about
# what the source file actually says.
d <- read_excel(SRC, sheet = 1, col_types = "text") %>%
  rename_with(~ .x %>% str_replace_all("[^A-Za-z0-9]+", "_") %>%
                str_replace("^_+|_+$", "") %>% tolower())

con <- tryCatch(
  duckdb_connect(DB, read_only = FALSE),
  error = function(e)
    stop(sprintf(paste0("Could not open %s for writing: %s\nDuckDB allows one ",
                        "writer at a time and this warehouse is shared. Close ",
                        "the other session's connection, or set FDA_DEBARMENT_DB to a ",
                        "different file."), DB, conditionMessage(e)),
         call. = FALSE))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbWriteTable(con, "fda_debarment_drug_applications", d, overwrite = TRUE)
cat(sprintf("loaded %-30s %6s rows x %2d cols (source: %s)\n",
            "fda_debarment_drug_applications", format(nrow(d), big.mark = ","),
            ncol(d), SRC))

n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM fda_debarment_drug_applications")$n
cat(sprintf("verification (read back from the warehouse): %s rows\n", format(n, big.mark = ",")))
