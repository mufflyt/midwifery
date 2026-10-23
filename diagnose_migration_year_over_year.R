#!/usr/bin/env Rscript
# =============================================================================
# Year-by-year geographic migration among linked midwives, and whether two
# mobility spikes are explained by NPPES file-format changes
# =============================================================================
# For each consecutive pair of NPPES annual snapshots in `midwife_panel.csv`,
# restricted to the FROZEN analytic cohort, this computes the share of
# midwives whose practice state/county/ZIP5 changed between the two years.
#
# It exists because the two largest year-over-year state-move-rate
# transitions in the whole 2007-2026 series (2017->2018, 2023->2024) both
# coincide with the two NPPES file-format changes this repo tracks: the 2018
# Latin-1 -> UTF-8 switch, and the December 2024 "reshaped" restructure
# (docs/TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md SS3). That correlation
# does NOT mean the format change caused the spike -- see
# docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md for what was actually
# tested and what remains unexplained. This script reproduces only the
# measurement; it does not resolve the mechanism.
#
# Two noise tests, answering two different questions:
#   blip        did a one-year change REVERT the very next year (A,B,A)?
#               Already near-zero everywhere (incl. 2024), so round-trip
#               flicker was already ruled out before this cycle.
#   confirmed   did a one-year change PERSIST for at least a year on both
#               sides (A,A,B,B) -- the repo owner's bar, added this cycle.
#               A move that never reverts can still be a one-off artifact if
#               it doesn't hold; this is a strictly stronger requirement than
#               "not a blip", and the one that actually tests whether 2018/
#               2024's elevated rate is durable mobility or noise that
#               happens not to round-trip.
#
# Input : midwife_panel.csv (NPPES annual snapshots; gitignored, person-level)
#         artifacts/amcb_npi_linkage_FROZEN.csv (cohort_member flag)
#         artifacts/zcta_county_crosswalk.csv (dominant-county-per-ZCTA)
# Output: prints the year-by-year table, the one-year "blip" rate, and the
#         A,A,B,B confirmed-move rate to stdout; writes neither by default,
#         since this is a diagnostic, not a tracked result.
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

PANEL  <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
FROZEN <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
ZCTA   <- Sys.getenv("ZCTA_CROSSWALK", "artifacts/zcta_county_crosswalk.csv")
for (p in c(PANEL, FROZEN, ZCTA))
  if (!file.exists(p)) stop(sprintf("missing required input: %s", p), call. = FALSE)

con <- duckdb_connect()
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# ---- year-by-year mover rates -----------------------------------------------
by_year <- dbGetQuery(con, sprintf("
  WITH cohort AS (
    SELECT DISTINCT npi FROM read_csv_auto('%s', ignore_errors=true)
    WHERE cohort_member = true AND npi IS NOT NULL
  ),
  panel AS (
    SELECT p.npi, p.snapshot_year, p.practice_state,
           substr(p.practice_zip, 1, 5) AS zip5
    FROM read_csv_auto('%s', ignore_errors=true) p
    JOIN cohort c USING (npi)
    WHERE p.practice_state IS NOT NULL
  ),
  dedup AS (
    SELECT npi, snapshot_year,
           arg_max(practice_state, 1) AS practice_state,
           arg_max(zip5, 1) AS zip5
    FROM panel GROUP BY npi, snapshot_year
  ),
  cw AS (SELECT zcta5, county_fips FROM read_csv_auto('%s')),
  dedup_c AS (
    SELECT d.*, cw.county_fips FROM dedup d LEFT JOIN cw ON cw.zcta5 = d.zip5
  ),
  pairs AS (
    SELECT a.snapshot_year AS year_from, b.snapshot_year AS year_to,
           a.practice_state AS state_from, b.practice_state AS state_to,
           a.zip5 AS zip_from, b.zip5 AS zip_to,
           a.county_fips AS county_from, b.county_fips AS county_to
    FROM dedup_c a JOIN dedup_c b ON a.npi = b.npi AND b.snapshot_year = a.snapshot_year + 1
  )
  SELECT year_from, year_to, COUNT(*) AS n_pairs,
         ROUND(100.0 * SUM(CASE WHEN state_from <> state_to THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_moved_state,
         ROUND(100.0 * SUM(CASE WHEN county_from IS NOT NULL AND county_to IS NOT NULL
                                 AND county_from <> county_to THEN 1 ELSE 0 END)
               / NULLIF(SUM(CASE WHEN county_from IS NOT NULL AND county_to IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS pct_moved_county,
         ROUND(100.0 * SUM(CASE WHEN zip_from <> zip_to THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_moved_zip
  FROM pairs GROUP BY year_from, year_to ORDER BY year_from",
  FROZEN, PANEL, ZCTA))

cat("== year-by-year migration, FROZEN cohort ==\n")
print(by_year, row.names = FALSE)

FORMAT_CHANGE_YEARS <- c(2018, 2024)
flagged <- by_year$year_to %in% FORMAT_CHANGE_YEARS
cat(sprintf("\nKnown NPPES format-change transitions (ending %s): mean %.2f%% moved state, vs. %.2f%% for every other transition.\n",
            paste(FORMAT_CHANGE_YEARS, collapse = ", "),
            mean(by_year$pct_moved_state[flagged]), mean(by_year$pct_moved_state[!flagged])))

# ---- one-year "blip" test: does a change revert the very next year? --------
# A state that differs from both its neighbours only in one year is the
# signature of a parsing blip, not real migration. Centered on each middle
# year (2008-2025); near-zero and flat would mean no such artifact exists.
blips <- dbGetQuery(con, sprintf("
  WITH cohort AS (
    SELECT DISTINCT npi FROM read_csv_auto('%s', ignore_errors=true)
    WHERE cohort_member = true AND npi IS NOT NULL
  ),
  panel AS (
    SELECT p.npi, p.snapshot_year, p.practice_state
    FROM read_csv_auto('%s', ignore_errors=true) p
    JOIN cohort c USING (npi)
    WHERE p.practice_state IS NOT NULL
  ),
  dedup AS (
    SELECT npi, snapshot_year, arg_max(practice_state, 1) AS practice_state
    FROM panel GROUP BY npi, snapshot_year
  ),
  triples AS (
    SELECT m.snapshot_year AS year_mid, lo.practice_state AS st_lo,
           m.practice_state AS st_mid, hi.practice_state AS st_hi
    FROM dedup m
    JOIN dedup lo ON lo.npi = m.npi AND lo.snapshot_year = m.snapshot_year - 1
    JOIN dedup hi ON hi.npi = m.npi AND hi.snapshot_year = m.snapshot_year + 1
  )
  SELECT year_mid, COUNT(*) AS n_triples,
         SUM(CASE WHEN st_lo = st_hi AND st_lo <> st_mid THEN 1 ELSE 0 END) AS one_year_blips,
         ROUND(100.0 * SUM(CASE WHEN st_lo = st_hi AND st_lo <> st_mid THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_blip
  FROM triples GROUP BY year_mid ORDER BY year_mid", FROZEN, PANEL))

cat("\n== one-year round-trip blip rate, by middle year ==\n")
print(blips, row.names = FALSE)
cat(sprintf("\nBlip rate centered on 2024 (the reshaped-format year): %.2f%%, vs. %.2f%% median across every other year.\n",
            blips$pct_blip[blips$year_mid == 2024],
            median(blips$pct_blip[blips$year_mid != 2024])))

# ---- confirmed-move test: does the new address hold for a year on each side? ----
# Stricter than the blip test above. For transition year_from->year_to to
# count as a CONFIRMED move, practice_state must be stable for the year
# immediately BEFORE year_from (state_pre = state_from) and stable for the
# year immediately AFTER year_to (state_to = state_post) -- i.e. the pattern
# is A,A,B,B, not just A,B. Needs 4 consecutive annual snapshots per NPI, so
# transitions touching the first or last year of the panel (2007->2008,
# 2025->2026) cannot be confirmed at all and are reported as NA, not 0 --
# unconfirmable is not the same claim as unconfirmed. n_quads is the
# SAME denominator for both raw_pct and confirmed_pct in a given row, so the
# two percentages are directly comparable (confirmed is never computed on a
# different population than raw within a row).
confirmed <- dbGetQuery(con, sprintf("
  WITH cohort AS (
    SELECT DISTINCT npi FROM read_csv_auto('%s', ignore_errors=true)
    WHERE cohort_member = true AND npi IS NOT NULL
  ),
  panel AS (
    SELECT p.npi, p.snapshot_year, p.practice_state
    FROM read_csv_auto('%s', ignore_errors=true) p
    JOIN cohort c USING (npi)
    WHERE p.practice_state IS NOT NULL
  ),
  dedup AS (
    SELECT npi, snapshot_year, arg_max(practice_state, 1) AS practice_state
    FROM panel GROUP BY npi, snapshot_year
  ),
  quads AS (
    SELECT b.snapshot_year AS year_from, c.snapshot_year AS year_to,
           pre.practice_state AS state_pre, b.practice_state AS state_from,
           c.practice_state AS state_to, post.practice_state AS state_post
    FROM dedup b
    JOIN dedup pre  ON pre.npi  = b.npi AND pre.snapshot_year  = b.snapshot_year - 1
    JOIN dedup c    ON c.npi    = b.npi AND c.snapshot_year    = b.snapshot_year + 1
    JOIN dedup post ON post.npi = b.npi AND post.snapshot_year = b.snapshot_year + 2
  )
  SELECT year_from, year_to, COUNT(*) AS n_quads,
         ROUND(100.0 * SUM(CASE WHEN state_from <> state_to THEN 1 ELSE 0 END) / COUNT(*), 2) AS raw_pct,
         ROUND(100.0 * SUM(CASE WHEN state_pre = state_from AND state_from <> state_to
                                 AND state_to = state_post THEN 1 ELSE 0 END) / COUNT(*), 2) AS confirmed_pct
  FROM quads GROUP BY year_from, year_to ORDER BY year_from", FROZEN, PANEL))

# The pair years this cohort can't confirm (no year-before or year-after
# snapshot to check) -- reported explicitly rather than silently absent.
unconfirmable <- setdiff(paste(by_year$year_from, by_year$year_to),
                          paste(confirmed$year_from, confirmed$year_to))

cat("\n== confirmed-move rate (A,A,B,B), vs. raw, same n per row ==\n")
print(confirmed, row.names = FALSE)
if (length(unconfirmable))
  cat(sprintf("Unconfirmable (no year-before or year-after snapshot exists): %s\n",
              paste(unconfirmable, collapse = "; ")))

flagged_c <- confirmed$year_to %in% FORMAT_CHANGE_YEARS
cat(sprintf(paste0("\nFormat-change transitions (ending %s): raw %.2f%% -> confirmed %.2f%% ",
                   "(%.0f%% of the raw rate survives confirmation).\n"),
            paste(FORMAT_CHANGE_YEARS, collapse = ", "),
            mean(confirmed$raw_pct[flagged_c]), mean(confirmed$confirmed_pct[flagged_c]),
            100 * mean(confirmed$confirmed_pct[flagged_c]) / mean(confirmed$raw_pct[flagged_c])))
cat(sprintf(paste0("Every other transition: raw %.2f%% -> confirmed %.2f%% ",
                   "(%.0f%% of the raw rate survives confirmation).\n"),
            mean(confirmed$raw_pct[!flagged_c]), mean(confirmed$confirmed_pct[!flagged_c]),
            100 * mean(confirmed$confirmed_pct[!flagged_c]) / mean(confirmed$raw_pct[!flagged_c])))
