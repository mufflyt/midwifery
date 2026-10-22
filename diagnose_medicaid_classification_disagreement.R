#!/usr/bin/env Rscript
# =============================================================================
# Section 6 diagnostic: why do the year-overlap and point-in-time-on-snapshot
# -date classification rules disagree on ~44% of NPI-years?
# =============================================================================
# This is a BLOCKING diagnostic, not a replacement analysis: it exists to
# determine whether the disagreement found in the first pass
# (build_medicaid_enrollment_concordance.R) is a coding error or two
# genuinely different, both-correct definitions answering different
# questions. Uses the CANONICAL cohort (R/lib/cohort_definitions.R::
# canonical_active_primary(), 12,170 on the current freeze -- the prior pass
# wrongly used the broader cohort_member=TRUE linkage-eligible population,
# 16,775; that is also corrected here).
#
# Input : midwife_panel.csv, artifacts/amcb_npi_linkage_FROZEN.csv,
#         /Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb
# Output: artifacts/medicaid_classification_disagreement_crosstab.csv
#         artifacts/medicaid_classification_disagreement_sample.csv
#         (deterministic sample, NPI-level -- NOT committed; see .gitignore)
#
# @family diagnostics
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

suppressPackageStartupMessages({library(DBI); library(duckdb)})
.this_script_dir <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg)) dirname(normalizePath(sub("^--file=", "", file_arg[1]))) else getwd()
})
source(file.path(.this_script_dir, "R", "lib", "medicare_duckdb.R"))
source(file.path(.this_script_dir, "R", "lib", "artifact_provenance.R"))
source(file.path(.this_script_dir, "R", "lib", "cohort_definitions.R"))

PANEL       <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
FROZEN      <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
MEDICAID_DB <- Sys.getenv("MEDICAID_ENROLLMENT_DB",
                          "/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb")
for (p in c(PANEL, FROZEN, MEDICAID_DB))
  if (!file.exists(p)) stop(sprintf("missing required input: %s", p), call. = FALSE)

YEARS <- 2018:2024

# ---- canonical cohort, per R/lib/cohort_definitions.R, NOT cohort_member=TRUE
linkage <- utils::read.csv(FROZEN, colClasses = "character", na.strings = "")
canon <- canonical_active_primary(linkage)
base::message(sprintf("Canonical cohort (canonical_active_primary()): %d distinct NPIs.", length(unique(canon$npi))))
base::message("(Spec quotes 12,171 against the freeze at time of writing; this freeze gives ",
              length(unique(canon$npi)), " -- disclosed, not silently reconciled.)")

tmp_cohort_csv <- file.path(.this_script_dir, "scratch", "canonical_cohort_npi_only.csv")
dir.create(dirname(tmp_cohort_csv), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(data.frame(npi = unique(canon$npi)), tmp_cohort_csv, row.names = FALSE)

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
tmp_spill <- file.path(.this_script_dir, "scratch", "duckdb_spill")
dir.create(tmp_spill, recursive = TRUE, showWarnings = FALSE)
dbExecute(con, sprintf("PRAGMA temp_directory='%s'", tmp_spill))
dbExecute(con, sprintf("ATTACH '%s' AS medicaid (READ_ONLY)", MEDICAID_DB))

dbExecute(con, sprintf("
  CREATE TEMP TABLE cohort AS
  SELECT DISTINCT npi, (npi ~ '^[0-9]{10}$') AS npi_valid_format
  FROM read_csv_auto('%s', ignore_errors=true, all_varchar=true)", tmp_cohort_csv))

dbExecute(con, sprintf("
  CREATE TEMP TABLE filtered_segments AS
  SELECT c.npi, e.STATE_CD AS state,
         CAST(e.ENRL_START_DT AS DATE) AS start_dt, CAST(e.ENRL_END_DT AS DATE) AS end_dt
  FROM cohort c JOIN medicaid.enrollment_segments e ON e.NPI = c.npi
  WHERE c.npi_valid_format AND e.PRVDR_TYPE = '03'
    AND e.ENRL_STATUS_CD NOT IN ('20','21','22','23','24','40','41','42','43','44','45','46','47')
    AND e.STATE_CD IS NOT NULL AND e.STATE_CD != ''"))
n_filtered <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM filtered_segments")$n
base::message(sprintf("%d qualifying enrollment-segment rows for the canonical cohort.", n_filtered))

dbExecute(con, "
  CREATE TEMP TABLE merged_intervals AS
  WITH ordered AS (
    SELECT npi, state, start_dt, end_dt,
           MAX(end_dt) OVER (PARTITION BY npi, state ORDER BY start_dt
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS running_max_end
    FROM filtered_segments
  ),
  flagged AS (
    SELECT *, CASE WHEN running_max_end IS NULL OR start_dt > running_max_end + INTERVAL 1 DAY
                   THEN 1 ELSE 0 END AS new_group
    FROM ordered
  ),
  grouped AS (
    SELECT *, SUM(new_group) OVER (PARTITION BY npi, state ORDER BY start_dt
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp
    FROM flagged
  )
  SELECT npi, state, MIN(start_dt) AS interval_start, MAX(end_dt) AS interval_end
  FROM grouped GROUP BY npi, state, grp")
n_intervals <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM merged_intervals")$n
base::message(sprintf("Merged into %d non-overlapping (npi, state) intervals.", n_intervals))

dbExecute(con, sprintf("
  CREATE TEMP TABLE nppes_year AS
  WITH panel AS (
    SELECT p.npi, CAST(p.snapshot_year AS INTEGER) AS year, p.practice_state,
           CAST(CASE WHEN p.snapshot_date ~ '^[0-9]{8}$'
                     THEN substr(p.snapshot_date,1,4)||'-'||substr(p.snapshot_date,5,2)||'-'||substr(p.snapshot_date,7,2)
                     ELSE p.snapshot_date END AS DATE) AS snapshot_date
    FROM read_csv_auto('%s', ignore_errors=true, all_varchar=true) p
    JOIN cohort c ON c.npi = p.npi AND c.npi_valid_format
    WHERE p.practice_state IS NOT NULL AND p.practice_state != ''
      AND p.snapshot_date IS NOT NULL AND p.snapshot_date != ''
  )
  SELECT npi, year, arg_max(practice_state, snapshot_date) AS state,
         arg_max(snapshot_date, snapshot_date) AS snapshot_date
  FROM panel WHERE year BETWEEN %d AND %d
  GROUP BY npi, year", PANEL, min(YEARS), max(YEARS)))

dbExecute(con, sprintf("
  CREATE TEMP TABLE medicaid_year_overlap AS
  WITH years(yr) AS (VALUES %s)
  SELECT m.npi, y.yr AS year, list_sort(array_agg(DISTINCT m.state)) AS states,
         COUNT(DISTINCT m.state) AS n_states
  FROM merged_intervals m CROSS JOIN years y
  WHERE m.interval_start <= make_date(y.yr, 12, 31) AND m.interval_end >= make_date(y.yr, 1, 1)
  GROUP BY m.npi, y.yr", paste(sprintf("(%d)", YEARS), collapse = ", ")))

dbExecute(con, "
  CREATE TEMP TABLE medicaid_point_in_time AS
  SELECT n.npi, n.year, list_sort(array_agg(DISTINCT m.state)) AS states,
         COUNT(DISTINCT m.state) AS n_states
  FROM nppes_year n
  LEFT JOIN merged_intervals m
    ON m.npi = n.npi AND m.interval_start <= n.snapshot_date AND m.interval_end >= n.snapshot_date
  GROUP BY n.npi, n.year")

classify_sql <- function(table_alias) sprintf("
  CASE
    WHEN n.state IS NULL THEN 'Indeterminate'
    WHEN coalesce(%1$s.n_states, 0) = 0 THEN 'Not observed'
    WHEN list_contains(%1$s.states, n.state) AND %1$s.n_states = 1 THEN 'Concordant'
    WHEN list_contains(%1$s.states, n.state) AND %1$s.n_states >= 2 THEN 'Multistate'
    ELSE 'Discordant'
  END", table_alias)

dbExecute(con, sprintf("
  CREATE TEMP TABLE both_rules AS
  SELECT c.npi, n.year, n.state AS nppes_state, n.snapshot_date,
         coalesce(yo.states, []) AS year_overlap_states,
         coalesce(yo.n_states, 0) AS year_overlap_n_states,
         (%s) AS classification_year_overlap,
         coalesce(pit.states, []) AS point_in_time_states,
         coalesce(pit.n_states, 0) AS point_in_time_n_states,
         (%s) AS classification_point_in_time
  FROM cohort c
  JOIN nppes_year n ON n.npi = c.npi
  LEFT JOIN medicaid_year_overlap yo ON yo.npi = c.npi AND yo.year = n.year
  LEFT JOIN medicaid_point_in_time pit ON pit.npi = c.npi AND pit.year = n.year",
  classify_sql("yo"), classify_sql("pit")))

base::message("\n== Cross-tabulation: year-overlap (rows) x point-in-time (cols) ==")
crosstab <- dbGetQuery(con, "
  SELECT classification_year_overlap, classification_point_in_time, COUNT(*) AS n
  FROM both_rules GROUP BY 1, 2 ORDER BY 1, 2")
print(crosstab, row.names = FALSE)

agree <- dbGetQuery(con, "
  SELECT ROUND(100.0 * SUM(CASE WHEN classification_year_overlap = classification_point_in_time
                                 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_agree,
         COUNT(*) AS n
  FROM both_rules")
base::message(sprintf("\nAgreement: %.1f%% of %d NPI-years (canonical cohort).",
                      agree$pct_agree, agree$n))

# ---- mechanism: is disagreement concentrated where year-overlap found MORE
# distinct states than point-in-time (i.e. a within-year transition touched
# a state the snapshot date itself was not inside)? --------------------------
mechanism <- dbGetQuery(con, "
  SELECT
    SUM(CASE WHEN classification_year_overlap != classification_point_in_time
              AND year_overlap_n_states > point_in_time_n_states THEN 1 ELSE 0 END) AS disagree_more_states_in_year_overlap,
    SUM(CASE WHEN classification_year_overlap != classification_point_in_time
              AND year_overlap_n_states = point_in_time_n_states THEN 1 ELSE 0 END) AS disagree_same_state_count,
    SUM(CASE WHEN classification_year_overlap != classification_point_in_time
              AND year_overlap_n_states < point_in_time_n_states THEN 1 ELSE 0 END) AS disagree_fewer_states_in_year_overlap,
    SUM(CASE WHEN classification_year_overlap != classification_point_in_time THEN 1 ELSE 0 END) AS total_disagree
  FROM both_rules")
base::message("\n== Mechanism: where does year-overlap's state SET differ from point-in-time's? ==")
print(mechanism, row.names = FALSE)

out1 <- "artifacts/medicaid_classification_disagreement_crosstab.csv"
write_with_provenance(crosstab, out1, inputs = c(PANEL, FROZEN, MEDICAID_DB))
base::message(sprintf("\nwrote %s", out1))

# ---- deterministic sample of disagreeing cases, for manual review ----------
sample <- dbGetQuery(con, "
  SELECT npi, year, nppes_state, snapshot_date,
         year_overlap_states, classification_year_overlap,
         point_in_time_states, classification_point_in_time
  FROM both_rules
  WHERE classification_year_overlap != classification_point_in_time
  ORDER BY npi, year LIMIT 20")
base::message("\n== First 20 disagreeing NPI-years (deterministic sample) ==")
print(sample, row.names = FALSE)
# DuckDB LIST columns arrive as R list-columns; write.csv() cannot encode
# those directly, so flatten to comma-joined strings for the file only (the
# printed version above keeps the richer list display).
sample_flat <- sample
for (col in c("year_overlap_states", "point_in_time_states"))
  sample_flat[[col]] <- vapply(sample_flat[[col]],
                               function(v) paste(v, collapse = ","), character(1))
# NPI-level: not committed. See .gitignore addition for this exact filename.
utils::write.csv(sample_flat, "artifacts/medicaid_classification_disagreement_sample.csv", row.names = FALSE)
