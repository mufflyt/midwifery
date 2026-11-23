#!/usr/bin/env Rscript
# One-shot: rebuild the segments parquet the extract script expects, from the
# csv inflated out of the 2026-07-24 zip. Typed auto-detection with a full
# sniff and explicit quoting: the extract script's SQL COALESCEs the segment
# dates against DATE values, so the parquet must carry real DATE columns
# (the earlier type-detection failure was quote misdetection, not mixed types).
suppressMessages(library(duckdb))
d <- "/Volumes/MufflySamsung/doge_opendata/medicaid_provider_enrollment_segments_2026_07_24"
csv <- file.path(d, "medicaid-provider-enrollment-segments.csv")
pq <- file.path(d, "medicaid-provider-enrollment-segments.parquet")
stopifnot(file.exists(csv))
con <- DBI::dbConnect(duckdb())
sql <- sprintf(
  "COPY (SELECT * FROM read_csv('%s', sample_size=-1, header=true, quote='\"', escape='\"')) TO '%s' (FORMAT PARQUET)",
  csv, pq)
DBI::dbExecute(con, sql)
cat("parquet rows:",
    DBI::dbGetQuery(con, sprintf("SELECT count(*) n FROM read_parquet('%s')", pq))$n,
    "\n")
print(DBI::dbGetQuery(con, sprintf(
  "SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('%s'))", pq)))
