#!/usr/bin/env Rscript
# =============================================================================
# Share of public Medicaid enrollment segments that carry a provider NPI,
# by state
# =============================================================================
# The public Medicaid provider-enrollment segments release records one row
# per provider-program enrollment spell. Whether a cohort member can be
# linked to a spell at all depends on the segment carrying the provider's
# NPI -- and the share that does is strongly state-dependent, from 0% in
# Oregon and New Mexico (no segment in either state's file carries an NPI)
# to >90% in New York and Kentucky. Pooled coverage or agreement statistics
# therefore rest on a state-varying identifiable subset; a cohort member
# enrolled in Oregon Medicaid is unobservable in this file regardless of
# how accurately the file records her state.
#
# This is a completeness property of the released file, computed over ALL
# segments, not only cohort-linked ones.
#
# Inputs : <volume>/doge_opendata/medicaid_provider_enrollment_segments_
#          2026_07_24/medicaid-provider-enrollment-segments.parquet
# Outputs: artifacts/medicaid_npi_population_by_state.csv
# =============================================================================
suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(readr)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))

SEGMENTS_REL <- file.path("doge_opendata",
                          "medicaid_provider_enrollment_segments_2026_07_24",
                          "medicaid-provider-enrollment-segments.parquet")
OUT <- "artifacts/medicaid_npi_population_by_state.csv"

parquet <- samsung_volume_path(SEGMENTS_REL, must_exist = TRUE)

con <- dbConnect(duckdb())
out <- dbGetQuery(con, sprintf(
  "SELECT STATE_CD AS state,
          COUNT(*) AS n_segments,
          COUNT(DISTINCT NPI) AS n_distinct_npi,
          ROUND(100 * COUNT(DISTINCT NPI) / COUNT(*), 2) AS pct_segments_with_npi
   FROM read_parquet('%s')
   GROUP BY STATE_CD
   ORDER BY pct_segments_with_npi", parquet))
dbDisconnect(con, shutdown = TRUE)

write_with_provenance(out, OUT, inputs = parquet)
print(as.data.frame(out))
