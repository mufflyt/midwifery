# =============================================================================
# One place that knows WHEN a source file is from
# =============================================================================
# Every cross-source comparison in this project pairs sources that were
# published on different dates, and until now nothing in the code knew those
# dates. build_cross_source_comparison.R takes each source at
# `filter(year == max(year))` -- its OWN newest vintage, independently. That is
# "freshest per source", which is NOT "closest to each other", and the two come
# apart badly: measured 2026-11-09, the current-snapshot pairwise matrix was
# comparing NPPES 2025-11-09 against Facility Affiliation 2026-10-02, a gap of
# ELEVEN MONTHS, and reporting the result in a CSV with no date column at all.
# A reader of artifacts/cross_source_pairwise_matrix.csv could not tell a
# one-month pairing from an eleven-month one.
#
# THE DATES WERE ALREADY THERE. midwife_panel.csv carries snapshot_date
# (20251109), not just snapshot_year; the NPPES archive names every release
# (npidata_pfile_20050523-20260809.csv); PECOS revalidation ships 39 MONTHLY
# files; DAC and the DOGE extracts carry their dates in filenames. The audit
# collapsed all of it to as.integer(year) and threw the rest away. This file
# does not invent provenance, it stops discarding it.
#
# TWO KINDS OF TIME, AND CONFLATING THEM IS THE TRAP. A snapshot source is true
# "as of" one instant. An interval source covers a span -- Open Payments PY2025
# is every payment in calendar 2025, published mid-2026, and is not "a
# 2026 source" just because that is when CMS posted it, nor a single day in
# 2025. Interval sources therefore carry start/end and are represented by their
# MIDPOINT for distance purposes, with the span kept so a caller can see what
# it is comparing against rather than trusting one collapsed number.
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

#' Read a vintage date out of a path, by this project's naming conventions
#'
#' Covers, in order: NPPES bulk (`...-20260809.csv`), dated directories and
#' files using `YYYY_MM_DD`, `YYYY-MM-DD`, `YYYY_MM` and `YYYY-MM`. A bare
#' `YYYY` is deliberately NOT matched -- a four-digit year in a filename is as
#' often a cohort label or a program year as a snapshot date, and guessing
#' January 1st would silently invent an eleven-month error of exactly the kind
#' this file exists to prevent.
#'
#' @param path [character] one or more paths.
#' @return [Date] same length as `path`; NA where no convention matches.
parse_vintage <- function(path) {
  out <- as.Date(rep(NA_character_, length(path)))
  b <- basename(as.character(path))
  # NPPES bulk files end in the release date: npidata_pfile_<start>-<end>.csv
  m <- stringr::str_match(b, "-(20[0-9]{2})([01][0-9])([0-3][0-9])\\.csv$")
  hit <- !is.na(m[, 1])
  out[hit] <- as.Date(sprintf("%s-%s-%s", m[hit, 2], m[hit, 3], m[hit, 4]))
  # YYYY_MM_DD or YYYY-MM-DD anywhere in the name
  m <- stringr::str_match(b, "(20[0-9]{2})[-_]([01][0-9])[-_]([0-3][0-9])")
  hit <- is.na(out) & !is.na(m[, 1])
  out[hit] <- as.Date(sprintf("%s-%s-%s", m[hit, 2], m[hit, 3], m[hit, 4]))
  # YYYY-MM or YYYY_MM -> first of that month, the resolution CMS publishes at
  m <- stringr::str_match(b, "(20[0-9]{2})[-_]([01][0-9])(?![0-9])")
  hit <- is.na(out) & !is.na(m[, 1])
  out[hit] <- as.Date(sprintf("%s-%s-01", m[hit, 2], m[hit, 3]))
  out
}

#' Last commit date of a tracked file, as recorded provenance
#'
#' For a scraped source with no date in its filename or its records, git is the
#' only place a date was ever written down. It is NOT equivalent to the scrape
#' date and must not be presented as one: a file is committed on or after the
#' day it was produced, so the commit date is an UPPER BOUND on the vintage and
#' makes the data look at least as fresh as it really is.
#'
#' It is still categorically better than file mtime, which git REWRITES to the
#' checkout time -- the same NDH artifact reported "today" in a fresh worktree.
#' A commit date is immutable history; an mtime is an accident of the filesystem.
#'
#' @param paths [character] repo-relative paths.
#' @param repo [character] directory inside the work tree.
#' @return [Date] one per path, NA for untracked files or on any git failure.
git_commit_date <- function(paths, repo = ".") {
  vapply(as.character(paths), function(f) {
    out <- suppressWarnings(tryCatch(
      system2("git", c("-C", shQuote(repo), "log", "-1", "--format=%cs", "--", shQuote(f)),
              stdout = TRUE, stderr = FALSE),
      error = function(e) character(0)))
    if (!length(out) || !nzchar(out[1])) return(NA_real_)
    as.numeric(as.Date(out[1]))
  }, numeric(1), USE.NAMES = FALSE) |> as.Date(origin = "1970-01-01")
}

#' Gap between two vintages, in months, signed (b - a)
vintage_gap_months <- function(a, b) as.numeric(as.Date(b) - as.Date(a)) / 30.44

#' The representative instant for an interval source
#'
#' Midpoint, not the publication date and not the start. Open Payments PY2025
#' is centred on 2025-07-01; calling it a 2026 source because CMS posted it in
#' June 2026 would misdate it by a year.
interval_representative <- function(start, end) {
  as.Date((as.numeric(as.Date(start)) + as.numeric(as.Date(end))) / 2,
          origin = "1970-01-01")
}

#' Pick the path whose vintage is nearest a target date
#'
#' @param paths [character] candidate files.
#' @param target [Date] the date to be near.
#' @param max_months [numeric] NA to allow any distance; otherwise error when
#'   even the nearest candidate is further than this.
#' @return [character(1)] the chosen path. Ties go to the LATER vintage, then to
#'   the larger file, so a truncated duplicate never beats a complete one.
nearest_vintage <- function(paths, target, max_months = NA_real_) {
  paths <- as.character(paths)
  v <- parse_vintage(paths)
  keep <- !is.na(v)
  if (!any(keep))
    stop("nearest_vintage(): no candidate carries a parseable vintage:\n  ",
         paste(utils::head(basename(paths), 10), collapse = "\n  "), call. = FALSE)
  paths <- paths[keep]; v <- v[keep]
  d <- abs(as.numeric(v - as.Date(target)))
  ord <- order(d, -as.numeric(v), -file.size(paths))
  best <- paths[ord[1]]
  if (!is.na(max_months) && d[ord[1]] / 30.44 > max_months)
    stop(sprintf(paste0("nearest_vintage(): closest candidate to %s is %s (%.1f months ",
                        "away), beyond the %.1f-month limit.\n  Widen the limit ",
                        "deliberately or obtain a closer vintage."),
                 format(as.Date(target)), basename(best), d[ord[1]] / 30.44, max_months),
         call. = FALSE)
  best
}

#' Refuse a comparison whose vintages are too far apart
#'
#' @return invisibly the gap in months. Errors past `max_months`.
assert_vintage_gap <- function(a, b, max_months = 6,
                               what_a = "source A", what_b = "source B") {
  g <- vintage_gap_months(a, b)
  if (is.na(g))
    stop(sprintf("assert_vintage_gap(): %s or %s has no vintage, so the gap is unknown.",
                 what_a, what_b), call. = FALSE)
  if (abs(g) > max_months)
    stop(sprintf(paste0("%s (%s) and %s (%s) are %.1f months apart, over the %.1f-month ",
                        "limit. Pair closer vintages, or raise the limit deliberately ",
                        "if you mean to measure across that gap."),
                 what_a, format(as.Date(a)), what_b, format(as.Date(b)), g, max_months),
         call. = FALSE)
  invisible(g)
}

#' The vintage of every source the cross-source comparisons use
#'
#' ONE definition, because two would drift. `audit_source_vintages.R` prints
#' and writes this table; `build_cross_source_comparison.R` joins it onto its
#' pairwise matrix so the gap travels with the agreement percentage. A second
#' copy of this logic in either caller is how the matrix ends up disagreeing
#' with the inventory about what was compared.
#'
#' Sources with no recorded date get `vintage_used = NA` and
#' `vintage_quality = "unrecorded"`. They are NOT given their file mtime: an
#' mtime is when a script ran or when a clone happened, never when the data was
#' true. Callers must decide what to do with an undated source; this function
#' will not invent a date for one.
#'
#' @return [tibble] one row per source: source, time_kind, vintage_used,
#'   period_start, period_end, vintage_quality, n_vintages_available,
#'   closest_unused, detail.
#' @param data_root [character] where the project's DATA lives, which is not
#'   always where its CODE is checked out. Defaults to MIDWIFERY_DATA_ROOT, then
#'   the working directory. This parameter exists because the alternative --
#'   symlinking data files into a git worktree -- shadowed TRACKED artifacts
#'   with a different branch's copies and broke ci_artifact_contracts with a
#'   cohort-count mismatch (canonical_n 11,920 against Table 1's 12,171) that
#'   looked like a real regression. Point this at the data instead.
source_vintage_table <- function(data_root = Sys.getenv("MIDWIFERY_DATA_ROOT", ".")) {
  vol <- function(rel) tryCatch(samsung_volume_path(rel, must_exist = FALSE),
                                error = function(e) NA_character_)
  dr <- function(...) file.path(data_root, ...)
  rows <- list()
  add <- function(source, kind, used, quality, detail,
                  period_start = NA, period_end = NA, available = NA_character_,
                  n_available = NA_integer_, closest_available = NA_character_) {
    rows[[length(rows) + 1L]] <<- tibble::tibble(
      source = source, time_kind = kind,
      vintage_used = as.Date(used), period_start = as.Date(period_start),
      period_end = as.Date(period_end), vintage_quality = quality,
      n_vintages_available = n_available, closest_unused = closest_available,
      detail = detail)
  }

  # --- NPPES: the anchor. Exact dates already in the panel ---------------------
  if (file.exists(dr("midwife_panel.csv"))) {
    p <- read_csv(dr("midwife_panel.csv"), col_types = cols(.default = "c"), progress = FALSE)
    dts <- sort(unique(as.Date(p$snapshot_date, format = "%Y%m%d")))
    used <- max(dts)
    arch <- vol("nppes_historical_downloads")
    cands <- character(0)
    if (!is.na(arch)) {
      cands <- c(Sys.glob(file.path(arch, "npidata_pfile_*.csv")),
                 Sys.glob(file.path(arch, "*", "npidata_pfile_*.csv")),
                 Sys.glob(file.path(arch, "*", "npidata_2*.csv")))
      cands <- cands[!grepl("header", cands, ignore.case = TRUE)]
    }
    av <- sort(unique(parse_vintage(cands)))
    newer <- av[av > used]
    add("nppes", "snapshot", used, "record (snapshot_date in midwife_panel.csv)",
        sprintf("panel holds %d snapshots, %s..%s", length(dts),
                format(min(dts)), format(used)),
        n_available = length(av),
        closest_available = if (length(newer)) format(min(newer)) else NA_character_)
  }

  # --- DAC / Physician Compare, current snapshot -------------------------------
  dac_c <- dr(c("DAC_NationalDownloadableFile_2026-07.csv", "DAC_NationalDownloadableFile_2026-06.csv"))
  dac_c <- dac_c[file.exists(dac_c)]
  # extract_dac_midwives.R takes the FIRST existing candidate in its own list,
  # which is the 2026-06 file -- so the artifact the audit reads is 2026-06 even
  # though 2026-07 is present. That is the kind of thing this inventory is for.
  if (length(dac_c)) {
    av <- sort(parse_vintage(dac_c))
    used <- min(av)   # the extract's first candidate wins, not the newest
    newer <- av[av > used]
    add("dac_physician_compare", "snapshot", used, "filename",
        sprintf("files on disk: %s", paste(basename(dac_c), collapse = ", ")),
        n_available = length(av),
        closest_available = if (length(newer)) format(max(newer)) else NA_character_)
  }

  # --- Open Payments: INTERVAL, a program year is not a publication date -------
  opdb <- vol(file.path("open_payments_data", "open_payments_merged_2013_2024.duckdb"))
  if (!is.na(opdb) && file.exists(opdb)) {
    con <- duckdb_connect(opdb, read_only = TRUE)
    tb <- grep("^op_[0-9]{4}$", DBI::dbListTables(con), value = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
    yrs <- sort(as.integer(sub("^op_", "", tb)))
    if (length(yrs)) {
      py <- max(yrs)
      add("open_payments", "interval",
          interval_representative(sprintf("%d-01-01", py), sprintf("%d-12-31", py)),
          "program year (table name)",
          sprintf("program years %d..%d; PY%d spans the calendar year and CMS published it ~%d-06",
                  min(yrs), py, py, py + 1L),
          period_start = sprintf("%d-01-01", py), period_end = sprintf("%d-12-31", py),
          n_available = length(yrs))
    }
  }

  # --- PECOS revalidation: 39 MONTHLY files, collapsed to a year by the audit --
  rv <- vol("cms_revalidation_raw")
  if (!is.na(rv) && dir.exists(rv)) {
    f <- Sys.glob(file.path(rv, "revalidation_reassignment_*.csv"))
    av <- sort(parse_vintage(f))
    if (length(av))
      add("pecos_revalidation", "snapshot", max(av), "filename",
          sprintf("%d MONTHLY vintages %s..%s -- the audit uses year resolution, discarding the month",
                  length(av), format(min(av)), format(max(av))),
          n_available = length(av))
  }

  # --- Facility affiliation: one snapshot --------------------------------------
  fa <- vol("facility_affiliation")
  if (!is.na(fa) && dir.exists(fa)) {
    d <- list.dirs(fa, recursive = FALSE)
    av <- sort(parse_vintage(d))
    if (length(av))
      add("facility_affiliation_ccn", "snapshot", max(av), "filename",
          sprintf("CMS does not archive this product; %d snapshot(s) held", length(av)),
          n_available = length(av))
  }

  # --- Medicaid enrollment segments (DOGE) -------------------------------------
  dg <- vol("doge_opendata")
  if (!is.na(dg) && dir.exists(dg)) {
    d <- Sys.glob(file.path(dg, "medicaid_provider_enrollment_segments_*"))
    av <- sort(parse_vintage(d))
    if (length(av))
      add("medicaid_enrollment", "snapshot", max(av), "filename",
          "dated enrollment intervals; published as one extract",
          n_available = length(av))
  }

  # --- Scrape / third-party sources: mtime is all there is ---------------------
  # These are labelled mtime_proxy on purpose. mtime is when the script ran, not
  # what the data is as of, and the DAC case above shows the two differ by months.
  # Doximity is the one third-party source that carries a real per-record date,
  # so it gets a vintage. The rest carry none and are recorded as unrecorded
  # rather than being handed their mtime.
  if (file.exists(dr("artifacts/doximity_public_matched.csv"))) {
    d <- read_csv(dr("artifacts/doximity_public_matched.csv"),
                  col_types = cols(.default = "c"), progress = FALSE)
    dm <- suppressWarnings(as.Date(d$date_modified))
    if (any(!is.na(dm)))
      add("doximity", "snapshot", max(dm, na.rm = TRUE), "record (date_modified)",
          sprintf("per-record date_modified, %s..%s across %s rows",
                  format(min(dm, na.rm = TRUE)), format(max(dm, na.rm = TRUE)),
                  format(sum(!is.na(dm)), big.mark = ",")))
    else
      add("doximity", "snapshot", NA, "unrecorded", "date_modified present but unparseable")
  }
  # CMS NDH carries no date in its filename or its records, and the bulk
  # manifest.json (which would hold the real release date) is not on disk. Its
  # commit is the only written-down date, so it is used AS AN UPPER BOUND.
  if (file.exists(dr("artifacts/cms_ndh_midwives.csv"))) {
    g <- git_commit_date("artifacts/cms_ndh_midwives.csv", repo = data_root)
    if (!is.na(g))
      add("cms_ndh_fhir", "snapshot", g, "git commit (UPPER bound on the vintage)",
          paste("no date in filename or records, and the CMS bulk manifest.json is absent;",
                "harvest landed on or before this commit"))
    else
      add("cms_ndh_fhir", "snapshot", NA, "unrecorded",
          "untracked and undated: no filename date, no record date, no commit")
  }

  # STATE BOARDS ARE NOT ONE SNAPSHOT. Eight states were scraped across seven
  # weeks, so collapsing them to a single date would misdate most of them. The
  # span is carried and represented by its midpoint, the same treatment Open
  # Payments gets for being an interval rather than an instant.
  bon <- Sys.glob(dr("artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv"))
  if (length(bon)) {
    g <- git_commit_date(sub(paste0("^", data_root, "/"), "", bon), repo = data_root)
    if (any(!is.na(g))) {
      lo <- min(g, na.rm = TRUE); hi <- max(g, na.rm = TRUE)
      add("state_boards_of_nursing", "interval", interval_representative(lo, hi),
          "git commit dates per state (UPPER bound)",
          sprintf("%d states scraped across %s..%s (%.0f days apart), not one snapshot",
                  length(bon), format(lo), format(hi), as.numeric(hi - lo)),
          period_start = lo, period_end = hi)
    } else {
      add("state_boards_of_nursing", "snapshot", NA, "unrecorded",
          sprintf("%d state scrape files, none carrying a scrape date", length(bon)))
    }
  }

  # Healthgrades is untracked AND undated -- no filename date, no record date,
  # no commit. There is genuinely nothing to read, and mtime is not a vintage.
  if (file.exists(dr("healthgrades_midwives.csv")))
    add("healthgrades", "snapshot", NA, "unrecorded",
        "untracked scrape with no date in filename or records; nothing recorded it")


  out <- dplyr::arrange(dplyr::bind_rows(rows), dplyr::desc(vintage_used))

  # A SOURCE THAT IS ABSENT MUST NOT LOOK LIKE A SOURCE THAT DOES NOT APPLY.
  # Every reader above is guarded by file.exists(), so a missing input simply
  # produced no row and the inventory looked complete. That is how the same
  # audit reported ten sources from one checkout and eight from another: the
  # cross-source comparisons run against origin/main's tracked artifacts, while
  # the large gitignored inputs live only in the working tree, and NEITHER
  # location holds all of them. Run it where code and data agree, and name what
  # is missing rather than quietly omitting it.
  expected <- c("nppes", "dac_physician_compare", "open_payments",
                "pecos_revalidation", "facility_affiliation_ccn",
                "medicaid_enrollment", "healthgrades", "doximity",
                "state_boards_of_nursing", "cms_ndh_fhir")
  absent <- setdiff(expected, out$source)
  if (length(absent))
    warning(sprintf(paste0("source_vintage_table(): %d expected source(s) produced NO ROW ",
                           "under data_root '%s', so they are missing from the inventory and ",
                           "from every gap this informs: %s.\n  Absent is not the same as ",
                           "undated -- check the inputs exist before reading the gaps as complete."),
                    length(absent), data_root, paste(absent, collapse = ", ")),
            call. = FALSE)
  attr(out, "absent_sources") <- absent
  out
}
