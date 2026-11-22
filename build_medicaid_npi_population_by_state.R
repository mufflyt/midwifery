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
# to 100% in South Dakota. Most states populate the field well, but a real
# low tail remains (Illinois 28%, Minnesota 34%, Michigan 43%), and 26 of
# the 54 reporting states and territories fall below the 90% that CMS's
# 10%-missing quality threshold implies. Pooled coverage or agreement
# statistics therefore rest on a state-varying identifiable subset; a
# cohort member enrolled in Oregon Medicaid is unobservable in this file
# regardless of how accurately the file records her state.
#
# This is a completeness property of the released file, computed over ALL
# segments, not only cohort-linked ones.
#
# COUNT(NPI) IS A VALID NUMERATOR HERE, which is a property of this file and
# not a general fact: SQL NULL has to be the only way the field spells absence,
# or a blank would count as present. Measured on the 2026-07-24 release --
# NPI is VARCHAR and nullable, 65,970,112 rows, 51,289,354 non-NULL, of which
# ZERO are blank and ZERO are any length but 10. Two sentinels are present,
# "0000000000" on 92 rows and "9999999999" on 12: 104 rows, 0.0002% of the
# non-NULL values, which moves no state's rate at the two decimal places this
# artifact rounds to. Re-checked by audit_medicaid_npi_coverage.R, which fails
# closed on a blank or short value, every time the file is re-released.
#
# The rate is COUNT(NPI) / COUNT(*) -- segments carrying an NPI over all
# segments. It is NOT COUNT(DISTINCT NPI) / COUNT(*), which this script did
# compute until 2026-11-21: that is distinct providers per segment, so any
# state filing many enrollment spells per provider read near zero (North
# Dakota 1.0% against a true 96.8%) and the states that looked complete were
# only the ones filing few spells each.
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

# The chokepoint, not a raw DBI::dbConnect(): duckdb_connect() defaults to an
# in-memory database, and routing through it is what gives this connection the
# encoding bootstrap and the temp-directory setting that a 66M-row parquet scan
# needs on an 8 GB machine. tests/duckdb_architecture_scan.R refuses a raw one.
con <- duckdb_connect()
out <- dbGetQuery(con, sprintf(
  "SELECT STATE_CD AS state,
          COUNT(*) AS n_segments,
          COUNT(NPI) AS n_segments_with_npi,
          COUNT(DISTINCT NPI) AS n_distinct_npi,
          ROUND(100.0 * COUNT(NPI) / COUNT(*), 2) AS pct_segments_with_npi
   FROM read_parquet('%s')
   GROUP BY STATE_CD
   -- `state` breaks the tie. Without it the order of equal rates is whatever
   -- the parallel scan produced, so Florida and Maryland (both 87.11) swapped
   -- places between two runs over an unchanged file and churned the artifact
   -- and its provenance sidecar.
   ORDER BY pct_segments_with_npi, state", parquet))
dbDisconnect(con, shutdown = TRUE)

write_with_provenance(out, OUT, inputs = parquet)
print(as.data.frame(out))
