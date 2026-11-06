#!/usr/bin/env Rscript
# =============================================================================
# PECOS enrollment state, by year, from the revalidation/reassignment warehouse
# =============================================================================
# archive_revalidation_reassignment.R already discovers and ingests every
# monthly "Revalidation Group Practice Reassignment" release CMS publishes
# into /Volumes/MufflySamsung/DuckDB/cms_revalidation.duckdb
# (revalidation_reassignment table: individual_npi, individual_state,
# individual_specialty, vintage "YYYY-MM"). 40 monthly vintages exist,
# 2021-12 through 2026-09 -- this is PECOS enrollment state, independent of
# NPPES self-report, genuinely spanning 5 real years, not a single snapshot.
#
# One row per (npi, year): the LAST vintage within that year (a year-end
# snapshot), joined to the cohort by NPI rather than by re-filtering
# specialty text, since the cohort's own NPI list is the precise target.
#
# Output: artifacts/pecos_revalidation_cohort_state_by_year.csv (person-level
# NPI-year-state; same standing as the other per-source extracts this
# session, see .gitignore).
#
# Also writes the UNCOLLAPSED monthly panel (artifacts/pecos_revalidation_
# cohort_state_monthly.csv, one row per NPI-vintage) -- added 2026-11-06 to
# let the 2020-21 truth-fusion signal (docs/TECHNICAL_APPENDIX_TRUTH_FUSION_
# MIGRATION.md S4) be checked at monthly resolution. The warehouse's own
# vintages start 2021-12, so this cannot see 2020 or most of 2021, only
# confirm/deny whether elevation continues or concentrates from 2021-12 on.
# =============================================================================
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr); library(readr)})

WAREHOUSE <- "/Volumes/MufflySamsung/DuckDB/cms_revalidation.duckdb"
stopifnot(file.exists(WAREHOUSE))

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = cols(.default = "c"),
                  progress = FALSE)
coh <- link %>% filter(cohort_member == "TRUE") %>% transmute(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>% distinct()
cat(sprintf("Cohort NPIs: %s\n", format(nrow(coh), big.mark = ",")))

con <- dbConnect(duckdb(), WAREHOUSE, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbWriteTable(con, "cohort_npis", coh, overwrite = TRUE, temporary = TRUE)

sql <- r"(
  SELECT individual_npi AS npi, individual_state AS pecos_state, vintage
  FROM revalidation_reassignment r
  INNER JOIN cohort_npis c ON c.npi = r.individual_npi
  WHERE individual_state IS NOT NULL AND individual_state <> '')"
rows <- dbGetQuery(con, sql)
cat(sprintf("Raw matched rows: %s across %s NPIs, %s vintages\n",
            format(nrow(rows), big.mark = ","), length(unique(rows$npi)),
            length(unique(rows$vintage))))

rows$year <- as.integer(substr(rows$vintage, 1, 4))
by_year <- rows %>%
  group_by(npi, year) %>%
  filter(vintage == max(vintage)) %>%
  slice(1) %>%
  ungroup() %>%
  select(npi, year, pecos_state, vintage)

write_csv(by_year, "artifacts/pecos_revalidation_cohort_state_by_year.csv", na = "")
cat(sprintf("wrote %s NPI-year rows (%s distinct NPIs, years %d-%d) -> artifacts/pecos_revalidation_cohort_state_by_year.csv\n",
            format(nrow(by_year), big.mark = ","), length(unique(by_year$npi)),
            min(by_year$year), max(by_year$year)))

# same arbitrary-but-deterministic pick as by_year above -- ~10% of
# npi-vintage combos carry multiple simultaneous group-practice states
# (e.g. ME/VT/NH in the same month), not real moves; one state per
# (npi, vintage) is required for a move-rate computation to mean anything
monthly <- rows %>% select(npi, vintage, pecos_state) %>% distinct() %>%
  group_by(npi, vintage) %>% slice(1) %>% ungroup()
write_csv(monthly, "artifacts/pecos_revalidation_cohort_state_monthly.csv", na = "")
cat(sprintf("wrote %s NPI-vintage rows (%s distinct NPIs, %d vintages) -> artifacts/pecos_revalidation_cohort_state_monthly.csv\n",
            format(nrow(monthly), big.mark = ","), length(unique(monthly$npi)), length(unique(monthly$vintage))))
