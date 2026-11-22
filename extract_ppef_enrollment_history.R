#!/usr/bin/env Rscript
# =============================================================================
# Medicare enrollment year, from CMS's Public Provider Enrollment File (PPEF)
# =============================================================================
# PPEF is CMS's full Medicare provider enrollment extract (Provider
# Enrollment, Chain and Ownership System, PECOS) -- distinct from the
# "Revalidation Group Practice Reassignment" files extract_pecos_
# revalidation_state_history.R already reads. Revalidation tracks WHEN a
# provider's periodic revalidation cycle falls due, a recurring
# administrative deadline; PPEF is the enrollment roster itself, one row per
# active Medicare enrollment, and it has never been extracted for this
# project before this file was found on the external drive.
#
# ONE SNAPSHOT, NOT A YEAR SERIES -- but ENRLMT_ID embeds the ORIGINAL
# enrollment date: format I<YYYYMMDD><sequence> for an individual enrollment
# (confirmed against a sample; O<...> organizational enrollments are not
# relevant here since this join is by individual NPI). That makes this a
# different kind of year signal than every other source in
# build_table1_by_year.R -- those measure "is this person observable in that
# year's snapshot"; this measures "when did this person's (earliest)
# Medicare enrollment begin", a one-time historical fact from a single
# current file, the same way NPPES' enumeration_date is a one-time fact read
# from a single current extract.
#
# EARLIEST ENROLLMENT PER NPI. A provider can carry more than one enrollment
# record (different PECOS_ASCT_CNTL_ID / ENRLMT_ID across practice settings
# or after a gap); this takes the first-ever ENRLMT_ID date, same convention
# as "years since AMCB initial certification" elsewhere in this project --
# the question is when Medicare enrollment began, not how many times.
#
# Inputs : /Volumes/MufflySamsung/nppes_historical_downloads/pecos/PPEF_Enrollment_Extract_2026.07.17.csv
#          artifacts/amcb_npi_linkage_FROZEN.csv
# Output : artifacts/ppef_cohort_enrollment_year.csv (person-level, gitignored)
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr); library(stringr)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # duckdb_connect(): CSV-ingestion bootstrap

PPEF <- samsung_duckdb_path(file.path("nppes_historical_downloads", "pecos",
                                      "PPEF_Enrollment_Extract_2026.07.17.csv"),
                            "PPEF_ENROLLMENT_EXTRACT")
if (!file.exists(PPEF))
  stop(sprintf("PPEF extract not found at %s. It lives on an external volume; mount it or adjust the path.", PPEF), call. = FALSE)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"),
                 progress = FALSE)
coh <- link %>% filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(coh), big.mark = ",")))

con <- duckdb_connect(dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE)

sql <- sprintf(r"(
  SELECT p.NPI AS npi, p.ENRLMT_ID AS enrlmt_id, p.PROVIDER_TYPE_DESC AS provider_type_desc
    FROM read_csv_auto('%s', ALL_VARCHAR=TRUE) p
    INNER JOIN cohort_npis c ON c.npi = CAST(p.NPI AS VARCHAR)
   WHERE p.ENRLMT_ID LIKE 'I%%')", PPEF)
rows <- dbGetQuery(con, sql)
cat(sprintf("Raw matched enrollment records: %s across %s NPIs\n",
            format(nrow(rows), big.mark = ","), length(unique(rows$npi))))

parsed <- rows %>%
  mutate(enrlmt_date_raw = str_extract(enrlmt_id, "^I(\\d{8})", group = 1),
         enrlmt_date = suppressWarnings(as.Date(enrlmt_date_raw, format = "%Y%m%d")),
         enrlmt_year = as.integer(format(enrlmt_date, "%Y"))) %>%
  filter(!is.na(enrlmt_year))

by_npi <- parsed %>%
  group_by(npi) %>%
  summarise(first_enrlmt_year = min(enrlmt_year), n_enrollments = n(), .groups = "drop")
cat(sprintf("Parsed: %s NPIs with a valid enrollment date, range %d-%d\n",
            format(nrow(by_npi), big.mark = ","), min(by_npi$first_enrlmt_year),
            max(by_npi$first_enrlmt_year)))

write_csv(by_npi, "artifacts/ppef_cohort_enrollment_year.csv", na = "")
cat("written: artifacts/ppef_cohort_enrollment_year.csv\n")
