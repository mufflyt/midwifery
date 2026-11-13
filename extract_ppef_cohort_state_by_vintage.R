#!/usr/bin/env Rscript
# =============================================================================
# PECOS enrollment state per cohort midwife, per PPEF vintage (2016-2024)
# =============================================================================
# The PECOS series in this project begins 2021-12, because that is where
# cms_revalidation.duckdb's monthly Revalidation Reassignment releases begin.
# NBER separately mirrors the CMS Public Provider Enrollment File (PPEF), and
# those archives reach back to August 2016 -- five years earlier. They were
# downloaded on 2026-11-09 and nothing read them.
#
# WHAT THIS IS NOT. It is not a backfill of the existing
# pecos_revalidation_cohort_state_by_year.csv series. PPEF and the
# Revalidation Reassignment extract are different CMS products with different
# enrolment universes, and splicing them into one line would invent a
# continuity neither supports. This writes its own series, per vintage, and
# leaves the comparison to the consumer.
#
# OBSERVATION DATE IS VALIDATED, NOT TAKEN FROM THE FILENAME. Neither PPEF
# layout carries a date column, so there is no in-file date to parse. Two
# weaker but real forms of internal evidence are used instead, and which one
# was used is recorded per vintage in the validation artifact:
#
#   archive_mtime     the modification time the zip stores for its member.
#                     This can REFUTE a claimed vintage (a file packaged
#                     before the period it claims to cover is impossible) but
#                     cannot confirm one precisely. Checked 2026-11-09: all
#                     ten monthly archives are packaged ON OR AFTER their
#                     claimed month and inside the claimed year, with lags of
#                     0-3 months -- ppefenrol20168 claims 2016-08 and was
#                     packaged 2016-11-18.
#   member_filename   the quarterly bundle names each extract by its actual
#                     CMS extract date (PPEF_Enrollment_Extract_2023.03.31),
#                     which is an authoritative release identifier rather
#                     than a label someone chose.
#
# A vintage whose archive mtime falls BEFORE its claimed month, or in a
# different year, is written with status "refuted" and excluded. Nothing is
# silently relabelled.
#
# WHICH COLUMN HOLDS THE STATE DIFFERS BY LAYOUT, and getting it wrong is
# silent in the worst way. The NBER monthly files carry BOTH state_cd and
# state_cdstr, and state_cd is the numeric FIPS code (6, 36, 48) while
# state_cdstr is the two-letter abbreviation (CA, NY, TX). The CMS quarterly
# extracts carry only STATE_CD, and there it IS the two-letter code. Reading
# state_cd from a monthly file yields FIPS integers that clean_state() will
# reject -- loudly, as it happens, which is how this was caught -- but a
# looser cleaner would have produced a state series of numbers. The column is
# therefore chosen from the header: state_cdstr where it exists, state_cd
# otherwise, recorded per vintage in the validation artifact.
#
# ONE STATE PER (npi, vintage): about a tenth of enrolled providers hold
# several simultaneous enrolments in different states, which are concurrent
# registrations and not moves. The alphabetically first is taken, the same
# deterministic-by-content rule extract_pecos_revalidation_state_history.R
# uses, and n_states_this_vintage is written alongside so multiplicity stays
# a column rather than becoming an inference.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          /Volumes/MufflySamsung*/ppef_nber/**/ppefenrol*.csv.zip
#          /Volumes/MufflySamsung*/ppef_nber/2023_2024Q2/2023_2024Q2.zip
# Outputs: artifacts/ppef_cohort_state_by_vintage.csv
#          artifacts/ppef_vintage_validation.csv
#          artifacts/ppef_cohort_coverage_by_vintage.csv
# See    : docs/source-series-reconstruction.md, docs/temporal-evidence-validation.md
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})
source(file.path("R", "lib", "clean_state.R"))
source(file.path("R", "lib", "medicare_duckdb.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

COHORT <- "artifacts/amcb_npi_linkage_FROZEN.csv"
PPEF_REL <- "ppef_nber"

#' Every PPEF vintage available locally, with its claimed observation date
#'
#' @param root [character] the ppef_nber directory on the external volume.
#' @return [data.frame] zip, member (a regex for the member to extract),
#'   claimed_date [Date], vintage [character "YYYY-MM"], layout. Empty when
#'   the volume is not mounted.
ppef_vintages <- function(root) {
  if (is.na(root) || !dir.exists(root)) return(NULL)
  monthly <- Sys.glob(file.path(root, "*", "ppefenrol*.csv.zip"))
  out <- lapply(monthly, function(z) {
    ym <- sub("^ppefenrol([0-9]+)\\.csv\\.zip$", "\\1", basename(z))
    yr <- as.integer(substr(ym, 1, 4))
    mo <- as.integer(substr(ym, 5, nchar(ym)))
    data.frame(zip = z, member = "\\.csv$",
               claimed_date = as.Date(sprintf("%04d-%02d-01", yr, mo)),
               vintage = sprintf("%04d-%02d", yr, mo),
               layout = "nber_monthly", stringsAsFactors = FALSE)
  })
  bundle <- file.path(root, "2023_2024Q2", "2023_2024Q2.zip")
  if (file.exists(bundle)) {
    members <- utils::unzip(bundle, list = TRUE)$Name
    members <- grep("PPEF_Enrollment_Extract_[0-9.]+\\.csv$", members, value = TRUE)
    for (m in members) {
      d <- as.Date(sub(".*PPEF_Enrollment_Extract_([0-9.]+)\\.csv$", "\\1",
                       basename(m)), format = "%Y.%m.%d")
      out[[length(out) + 1L]] <- data.frame(
        zip = bundle, member = paste0(basename(m), "$"), claimed_date = d,
        vintage = format(d, "%Y-%m"), layout = "cms_quarterly",
        stringsAsFactors = FALSE)
    }
  }
  if (!length(out)) return(NULL)
  v <- do.call(rbind, out)
  v[order(v$claimed_date), , drop = FALSE]
}

#' Validate a claimed vintage against evidence inside the archive
#'
#' Year-level validation only. The archive's stored modification time is the
#' date the file was PACKAGED, which is on or after the period it describes,
#' so it bounds the claim from below rather than pinning it.
#'
#' @param zip,member [character] archive and the member regex.
#' @param claimed [Date] the vintage this file claims to represent.
#' @param layout [character] which naming scheme supplied the claim.
#' @return [list] method, evidence_date, status ("verified_year",
#'   "refuted", "unverified"), detail.
validate_vintage <- function(zip, member, claimed, layout) {
  info <- tryCatch(utils::unzip(zip, list = TRUE), error = function(e) NULL)
  if (is.null(info)) {
    return(list(method = "none", evidence_date = NA,
                status = "unverified", detail = "archive unreadable"))
  }
  hit <- info[grepl(member, info$Name), , drop = FALSE]
  if (!nrow(hit)) {
    return(list(method = "none", evidence_date = NA,
                status = "unverified", detail = "member not found"))
  }
  packed <- as.Date(hit$Date[1])
  method <- if (identical(layout, "cms_quarterly"))
    "member_filename+archive_mtime" else "archive_mtime"
  if (is.na(packed)) {
    return(list(method = method, evidence_date = NA,
                status = "unverified", detail = "no stored mtime"))
  }
  if (packed < claimed) {
    return(list(method = method, evidence_date = packed, status = "refuted",
                detail = "packaged before the period it claims to cover"))
  }
  # The quarterly members carry a CMS extract date in the filename, which is
  # an authoritative release identifier. The archive around them was bundled
  # by NBER later -- one packaging date for all six members, 2024-09-22 -- so
  # requiring the same year there would refute every 2023 quarter on the
  # strength of when someone zipped it. That rule belongs only where the
  # mtime is the ONLY corroboration, which is the monthly layout.
  if (identical(layout, "cms_quarterly")) {
    return(list(method = method, evidence_date = packed,
                status = "verified_date",
                detail = sprintf("CMS extract date in member name; archive bundled %s",
                                 format(packed, "%Y-%m-%d"))))
  }
  if (format(packed, "%Y") != format(claimed, "%Y")) {
    return(list(method = method, evidence_date = packed, status = "refuted",
                detail = "packaged in a different year than claimed"))
  }
  list(method = method, evidence_date = packed, status = "verified_year",
       detail = sprintf("packaged %d day(s) after the claimed month began",
                        as.integer(packed - claimed)))
}

#' Cohort enrolment state from one PPEF vintage
#'
#' Reads only this archive. No other vintage is in scope, so a later snapshot
#' cannot supply a value to an earlier one.
#'
#' @param con [DBIConnection] DuckDB.
#' @param zip,member [character] archive and member regex.
#' @param vintage [character] "YYYY-MM", attached to every row.
#' @return [list] `rows` (npi, vintage, state, n_states_this_vintage; NULL
#'   when nothing survives) and `state_col` (which column was read), so the
#'   caller can record the choice rather than leave it implicit.
pull_vintage <- function(con, zip, member, vintage) {
  tmp <- file.path(tempdir(), paste0("ppef_", gsub("-", "", vintage)))
  dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  nm <- utils::unzip(zip, list = TRUE)$Name
  nm <- grep(member, nm, value = TRUE)
  if (!length(nm)) return(NULL)
  utils::unzip(zip, files = nm[1], exdir = tmp, junkpaths = TRUE)
  csv <- list.files(tmp, pattern = "\\.csv$", full.names = TRUE)
  if (!length(csv)) return(list(rows = NULL, state_col = NA_character_))
  hdr <- tolower(names(utils::read.csv(csv[1], nrows = 1L,
                                       check.names = FALSE)))
  state_col <- if ("state_cdstr" %in% hdr) "state_cdstr" else "state_cd"
  q <- sprintf("
    WITH hit AS (
      SELECT trim(CAST(t.npi AS VARCHAR)) AS npi,
             upper(trim(CAST(t.%2$s AS VARCHAR))) AS state
        FROM read_csv(%1$s, all_varchar = true, union_by_name = true) t
        JOIN cohort_npi c ON trim(CAST(t.npi AS VARCHAR)) = c.npi
       WHERE t.%2$s IS NOT NULL
         AND length(trim(CAST(t.%2$s AS VARCHAR))) > 0
    ), tally AS (
      SELECT npi, state, COUNT(*) AS n FROM hit GROUP BY npi, state
    )
    SELECT npi, state,
           (SELECT COUNT(DISTINCT t2.state) FROM tally t2
             WHERE t2.npi = tally.npi) AS n_states_this_vintage
      FROM tally
     QUALIFY ROW_NUMBER() OVER (PARTITION BY npi ORDER BY state ASC) = 1",
    DBI::dbQuoteString(con, csv[1]), DBI::dbQuoteIdentifier(con, state_col))
  out <- DBI::dbGetQuery(con, q)
  if (nrow(out)) {
    out$state <- clean_state(out$state)
    out <- out[!is.na(out$state), , drop = FALSE]
  }
  # Guarded rather than assumed: a vintage whose every state fails
  # clean_state() means the wrong column was read, and assigning a vintage
  # label to a zero-row frame is an error, not an empty result.
  if (!nrow(out)) return(list(rows = NULL, state_col = state_col))
  out$vintage <- vintage
  list(rows = out[, c("npi", "vintage", "state", "n_states_this_vintage")],
       state_col = state_col)
}

if (sys.nframe() == 0L) {
  cohort <- readr::read_csv(COHORT, col_types = readr::cols(.default = "c"),
                            progress = FALSE) %>%
    filter(cohort_member == "TRUE") %>%
    transmute(npi = trimws(npi)) %>%
    filter(!is.na(npi), nzchar(npi)) %>% distinct()
  base::message(sprintf("cohort NPIs: %s", format(nrow(cohort), big.mark = ",")))

  root <- samsung_volume_path(PPEF_REL, must_exist = FALSE)
  v <- ppef_vintages(root)
  if (is.null(v)) stop("no PPEF archives found under ", PPEF_REL, call. = FALSE)
  base::message(sprintf("%d PPEF vintage(s), %s to %s", nrow(v),
                        min(v$vintage), max(v$vintage)))

  con <- duckdb_connect()   # encoding bootstrap; never a raw dbConnect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf("SET temp_directory=%s",
                              DBI::dbQuoteString(con, tempdir())))
  DBI::dbWriteTable(con, "cohort_npi", as.data.frame(cohort), overwrite = TRUE)

  val <- list(); rows <- list()
  for (i in seq_len(nrow(v))) {
    vi <- v[i, ]
    chk <- validate_vintage(vi$zip, vi$member, vi$claimed_date, vi$layout)
    val[[i]] <- tibble(vintage = vi$vintage, claimed_date = vi$claimed_date,
                       layout = vi$layout, validation_method = chk$method,
                       evidence_date = chk$evidence_date,
                       status = chk$status, detail = chk$detail,
                       archive = basename(vi$zip))
    if (!chk$status %in% c("verified_year", "verified_date")) {
      base::message(sprintf("  %-8s %-14s SKIPPED (%s)", vi$vintage,
                            chk$status, chk$detail))
      next
    }
    got <- pull_vintage(con, vi$zip, vi$member, vi$vintage)
    val[[i]]$state_column <- got$state_col
    r <- got$rows
    if (is.null(r)) {
      base::message(sprintf("  %-8s no cohort rows with a usable state",
                            vi$vintage))
      next
    }
    rows[[length(rows) + 1L]] <- r
    base::message(sprintf(
      "  %-8s %6s midwives, %2d states, %4.1f%% multi-state (%s)",
      vi$vintage, format(nrow(r), big.mark = ","),
      dplyr::n_distinct(r$state),
      100 * mean(r$n_states_this_vintage > 1), got$state_col))
  }
  stopifnot(length(rows) > 0)
  panel <- bind_rows(rows)
  validation <- bind_rows(val)

  cov <- panel %>% count(vintage, name = "n_midwives") %>%
    mutate(pct_of_cohort = round(100 * n_midwives / nrow(cohort), 1)) %>%
    arrange(vintage)

  write_with_provenance(panel, "artifacts/ppef_cohort_state_by_vintage.csv",
                        inputs = COHORT, na = "")
  write_with_provenance(validation, "artifacts/ppef_vintage_validation.csv",
                        inputs = COHORT, na = "")
  write_with_provenance(cov, "artifacts/ppef_cohort_coverage_by_vintage.csv",
                        inputs = COHORT, na = "")
  base::message(sprintf("\n%s rows, %s midwives, %d vintages %s..%s",
                        format(nrow(panel), big.mark = ","),
                        format(dplyr::n_distinct(panel$npi), big.mark = ","),
                        dplyr::n_distinct(panel$vintage),
                        min(panel$vintage), max(panel$vintage)))
}
