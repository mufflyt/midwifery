#!/usr/bin/env Rscript
# =============================================================================
# Medicare Part B and Part D per-NPI-year practice state for the frozen cohort
# =============================================================================
# build_cross_source_comparison.R compares ten sources of a midwife's practice
# state. Two CMS sources the warehouse already holds were not among them:
# Medicare Part B (Physician & Other Practitioners) and Part D (Prescriber).
# This script extracts them in the same long npi/year/state shape the other
# sources use, so they join the comparison on the same terms.
#
# -----------------------------------------------------------------------------
# REVISED 2026-11-09: Part D now carries a state for EVERY year, 2013-2024.
# -----------------------------------------------------------------------------
# The first version of this script could only give Part D a state for 2022 and
# 2023, because those are the only years the warehouse holds as
# medicare_part_d_<year>. For 2013-2021 the warehouse holds only the
# *_standardized cut -- npi_char, data_year, name, claims, cost, beneficiaries
# -- which drops Prscrbr_State_Abrvtn entirely. Eleven years of Part D
# therefore entered the comparison as presence-only.
#
# That was a gap in this clone, not in the data. CMS publishes "Medicare Part D
# Prescribers - by Provider" for 2013-2024, and every one of those files does
# carry Prscrbr_State_Abrvtn. They were downloaded to the external volume on
# 2026-11-09 and are read here directly. The standardized cut turns out to be
# the same universe, not a subset: 2021 standardized holds 3,443 cohort NPIs
# and the 2021 by-provider file holds the same 3,443. So this is strictly
# additional columns on rows the comparison already had, not new rows.
#
# WHICH SOURCE SUPPLIES WHICH YEAR, and why it is split rather than uniform:
#
#   Part D   2013-2021  by-provider CSV on the external volume (downloaded)
#            2022-2023  medicare_part_d_<year> in the warehouse
#            2024       by-provider CSV on the external volume (downloaded)
#   Part B   2013-2023  medicare_part_b_<year> in the warehouse
#            2024       by-provider CSV on the external volume (downloaded)
#
# 2022 and 2023 are read from the warehouse rather than re-downloaded because
# medicare_part_d_<year> IS the by-provider file, same product and same column
# names -- re-fetching 1.3 GB to get bytes already on the drive would buy
# nothing. Part B 2024 moved OFF medicare_part_b_by_service_2024, which is one
# row per HCPCS code and so needed a modal reduction to answer a question the
# by-provider file answers directly, one row per NPI.
#
# WHAT EACH SOURCE CAN AND CANNOT ANSWER IS NOT THE SAME, and flattening that
# would be the bug. Checked against duckdb_columns() on every table and against
# the CSV headers on every downloaded file.
#
# ONE STATE PER NPI-YEAR, CHOSEN DETERMINISTICALLY: the modal state (most rows
# that year, ties broken alphabetically), the same rule
# extract_historical_facility_affiliation.R and build_cross_source_comparison.R
# use. n_states_this_year is written alongside so multiplicity is a column
# rather than an inference. The by-provider files are one row per NPI, so for
# those years the modal reduction is a no-op and n_states_this_year is 1 --
# the rule is applied uniformly anyway so that no year is reduced by a
# different rule than its neighbours.
#
# THE PRESENCE FILE IS NOW REDUNDANT AND IS NO LONGER WRITTEN. It existed only
# to carry the eleven years that had no state, and keeping it now would be
# worse than useless: it would be the same npi/year pairs as the state file
# under a second name, and any consumer treating the two as separate sources
# would count Part D twice. compare_all_sources_mysteryroster.R must drop
# medicare_part_d_presence from its presence-only list.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (cohort NPIs)
#          medicare_part_b_{2013..2023}, medicare_part_d_{2022,2023}
#            (MEDICARE_DUCKDB)
#          medicare_part_d_by_provider/part_d_by_provider_{2013..2021,2024}.csv
#          medicare_part_b_by_provider/part_b_by_provider_2024.csv
#            (external volume; see download provenance note above)
# Outputs: artifacts/cohort_midwives_part_b_state_by_year.csv
#          artifacts/cohort_midwives_part_d_state_by_year.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
cohort <- read_csv(COHORT, col_types = cols(.default = "c"), progress = FALSE) %>%
  filter(cohort_member == "TRUE") %>%
  transmute(npi = trimws(npi)) %>%
  filter(!is.na(npi), nzchar(npi)) %>%
  distinct()
cat(sprintf("cohort NPIs: %s\n", format(nrow(cohort), big.mark = ",")))

DB <- resolve_midwifery_duckdb()
con <- duckdb_connect(DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
# DuckDB writes spill files under the R session tempdir by default, and that
# directory can vanish under a long run; pin it somewhere that persists.
tmpd <- Sys.getenv("DUCKDB_TEMP_DIR", file.path(tempdir(), "duckdb_spill"))
dir.create(tmpd, showWarnings = FALSE, recursive = TRUE)
dbExecute(con, sprintf("SET temp_directory=%s", dbQuoteString(con, tmpd)))

dbWriteTable(con, "cohort_npi", as.data.frame(cohort), temporary = TRUE, overwrite = TRUE)

#' Does the warehouse hold this table?
#'
#' Asked rather than assumed because the table set is not the same in every
#' clone of this project, and because the whole point of the 2026-11-09 revision
#' was that eleven years of Part D state were sitting outside the warehouse
#' while the script quietly reported them as unavailable. A source that is
#' absent must say so in the log and return NULL; it must never become a silent
#' gap in the series.
#'
#' @param tb [character] one warehouse table name, unquoted.
#' @return [logical] TRUE when `duckdb_tables()` lists it in the attached
#'   database.
has_table <- function(tb) {
  nrow(dbGetQuery(con, sprintf(
    "SELECT 1 FROM duckdb_tables() WHERE table_name=%s", dbQuoteString(con, tb)))) > 0L
}

#' A warehouse table as a source expression
#'
#' A "source expression" is whatever can legally follow FROM: a quoted warehouse
#' table name, or a read_csv() over a file on the external volume. Both kinds
#' are built here into the same shape and handed to the same `pull_states()`,
#' so a year read from a downloaded CSV is reduced by exactly the rule that
#' reduces a year read from the warehouse. That uniformity is the point. The
#' alternative -- a second extraction path for the downloaded years -- is how a
#' series acquires a seam at 2021/2022 that looks like a finding.
#'
#' @param tb [character] warehouse table name.
#' @return [list] `sql` (the quoted identifier, safe to interpolate after FROM)
#'   and `label` (what to print in the per-year log), or NULL when the table is
#'   absent -- having logged that it was skipped.
tbl_src <- function(tb) {
  if (!has_table(tb)) { cat(sprintf("  %-44s absent, skipped\n", tb)); return(NULL) }
  list(sql = dbQuoteIdentifier(con, tb), label = tb)
}
#' A downloaded CSV on the external volume as a source expression
#'
#' `must_exist = FALSE` so that an unmounted drive degrades to a logged skip
#' rather than an error: this script is run on machines that do not all have the
#' volume attached, and the warehouse years still extract without it. `read_csv`
#' is given `all_varchar = true` because DuckDB's type sniffer reads a state
#' column of two-letter codes happily enough but will decide an NPI column of
#' ten digits is a BIGINT, and the cohort join is on character NPIs.
#'
#' @param relative [character] path beneath the MufflySamsung mount, resolved
#'   through the canonical `samsung_volume_path()` so a second mounted copy of
#'   the drive raises rather than silently picking one.
#' @return [list] `sql` and `label`, as `tbl_src()`, or NULL when the file is
#'   not there.
csv_src <- function(relative) {
  p <- samsung_volume_path(relative, must_exist = FALSE)
  if (is.na(p) || !file.exists(p)) {
    cat(sprintf("  %-44s absent, skipped\n", basename(relative))); return(NULL)
  }
  list(sql = sprintf("read_csv(%s, all_varchar = true)", dbQuoteString(con, p)),
       label = basename(p))
}
#' The downloaded by-provider file for one year, if it was fetched
#'
#' Part D has one for 2013-2021 and 2024; Part B has one for 2024 only. Years
#' with no downloaded file return NULL here and are read from the warehouse
#' instead -- see the year table in this script's header for which is which and
#' why the split is not uniform.
#'
#' @param y [integer] data year.
#' @return [list] a source expression, or NULL.
part_d_csv <- function(y) csv_src(file.path("medicare_part_d_by_provider",
                                            sprintf("part_d_by_provider_%d.csv", y)))
#' @rdname part_d_csv
part_b_csv <- function(y) csv_src(file.path("medicare_part_b_by_provider",
                                            sprintf("part_b_by_provider_%d.csv", y)))

#' One practice state per cohort NPI per year, chosen deterministically
#'
#' The modal state: the one appearing on the most rows for that NPI that year,
#' ties broken alphabetically. Alphabetical tie-breaking is not arbitrary
#' prettiness -- it is what makes a rerun byte-identical, and this artifact
#' feeds a provenance ratchet that treats a changed hash as a changed finding.
#'
#' For the by-provider files the reduction is a no-op, because those files carry
#' one row per NPI already. It is applied to them anyway so that no year in the
#' series is reduced by a different rule than its neighbours.
#'
#' The whole reduction runs in SQL rather than in R because the by-service
#' tables are tens of millions of rows before the cohort filter and the
#' downloaded CSVs are 500-790 MB each; pulling either into R to then join the
#' cohort away would be the slowest step in the script by a wide margin.
#'
#' `trim(CAST(... AS VARCHAR))` appears on both sides of the join because the
#' downloaded CSVs are read as all-varchar and the warehouse tables are not;
#' casting both to character and trimming both is the only way the same join
#' works against both without one of them silently matching nothing.
#'
#' @param src [list] a source expression from `tbl_src()` or `csv_src()`, or
#'   NULL -- in which case this returns NULL, so a missing year propagates as an
#'   absent year rather than as an error.
#' @param npi_col,state_col [character] column names in that source. They differ
#'   by product: Part B renders `Rndrng_NPI`/`Rndrng_Prvdr_State_Abrvtn`, Part D
#'   prescribes `Prscrbr_NPI`/`Prscrbr_State_Abrvtn`.
#' @param year [integer] the data year, supplied by the caller rather than read
#'   from the data, because the by-provider files carry no year column -- the
#'   year is a property of which file you opened.
#' @return [data.frame] npi, year, state, n_states_this_year -- one row per
#'   cohort NPI present that year. `n_states_this_year` is written alongside so
#'   that multiplicity is a column a reader can filter on rather than an
#'   inference they have to make. Rows whose state is not a US state are dropped
#'   by `clean_state()`: in the 2026-11-09 rebuild that was exactly one NPI, a
#'   prescriber in Dar Es Salaam carrying the foreign code `ZZ`.
pull_states <- function(src, npi_col, state_col, year) {
  if (is.null(src)) return(NULL)
  q <- sprintf("
    WITH hit AS (
      SELECT trim(CAST(t.%s AS VARCHAR)) AS npi, CAST(t.%s AS VARCHAR) AS state
        FROM %s t JOIN cohort_npi c ON trim(CAST(t.%s AS VARCHAR)) = c.npi
       WHERE t.%s IS NOT NULL AND length(trim(CAST(t.%s AS VARCHAR))) > 0
    ), tally AS (
      SELECT npi, state, COUNT(*) AS n FROM hit GROUP BY npi, state
    )
    SELECT npi, state, n,
           (SELECT COUNT(DISTINCT t2.state) FROM tally t2 WHERE t2.npi = tally.npi) AS n_states_this_year
      FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY npi ORDER BY n DESC, state ASC) = 1",
    dbQuoteIdentifier(con, npi_col), dbQuoteIdentifier(con, state_col),
    src$sql, dbQuoteIdentifier(con, npi_col),
    dbQuoteIdentifier(con, state_col), dbQuoteIdentifier(con, state_col))
  out <- dbGetQuery(con, q)
  if (!nrow(out)) { cat(sprintf("  %-44s 0 cohort rows\n", src$label)); return(NULL) }
  out$year <- as.integer(year)
  out$state <- clean_state(out$state)
  out <- out[!is.na(out$state), , drop = FALSE]
  cat(sprintf("  %-44s %6s NPIs, %2d distinct states\n", src$label,
              format(nrow(out), big.mark = ","), dplyr::n_distinct(out$state)))
  out[, c("npi", "year", "state", "n_states_this_year")]
}

cat("\nPart B (Physician & Other Practitioners), state by year:\n")
part_b <- bind_rows(
  bind_rows(lapply(2013:2023, function(y)
    pull_states(tbl_src(sprintf("medicare_part_b_%d", y)), "Rndrng_NPI",
                "Rndrng_Prvdr_State_Abrvtn", y))),
  pull_states(part_b_csv(2024), "Rndrng_NPI", "Rndrng_Prvdr_State_Abrvtn", 2024))

cat("\nPart D (Prescriber), state by year -- every year 2013-2024:\n")
part_d <- bind_rows(lapply(2013:2024, function(y) {
  src <- if (y %in% 2022:2023) tbl_src(sprintf("medicare_part_d_%d", y)) else part_d_csv(y)
  pull_states(src, "Prscrbr_NPI", "Prscrbr_State_Abrvtn", y)
}))

stopifnot(nrow(part_b) > 0, nrow(part_d) > 0)
write_with_provenance(part_b, "artifacts/cohort_midwives_part_b_state_by_year.csv",
                      inputs = COHORT, na = "")
cat(sprintf("\nPart B: %s NPI-years, %s NPIs, %d-%d\n",
            format(nrow(part_b), big.mark = ","),
            format(dplyr::n_distinct(part_b$npi), big.mark = ","),
            min(part_b$year), max(part_b$year)))

write_with_provenance(part_d, "artifacts/cohort_midwives_part_d_state_by_year.csv",
                      inputs = COHORT, na = "")
cat(sprintf("Part D: %s NPI-years, %s NPIs, %d-%d\n",
            format(nrow(part_d), big.mark = ","),
            format(dplyr::n_distinct(part_d$npi), big.mark = ","),
            min(part_d$year), max(part_d$year)))
