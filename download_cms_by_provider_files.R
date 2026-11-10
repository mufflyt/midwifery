#!/usr/bin/env Rscript
# =============================================================================
# Download the CMS "by Provider" files that carry a practice state
# =============================================================================
# Medicare Part B (Physician & Other Practitioners) and Part D (Prescribers)
# are published by CMS one file per data year. The warehouse holds Part B
# 2013-2023 and Part D 2022-2023 as full tables; Part D 2013-2021 exists there
# only as the *_standardized cut, which DROPS Prscrbr_State_Abrvtn. Eleven
# years of Part D were therefore presence-only in this project until these
# files were fetched on 2026-11-09.
#
# WHY THIS RESOLVES URLS INSTEAD OF HARDCODING THEM. The download URLs embed a
# release year, a rotating UUID directory and a release-year code that changes
# between vintages of the same data year -- 2013 currently ships as
# mup_dpr_ry21_p04_v20_dy13_npi.csv under a 2026-08 directory, 2023 as
# MUP_DPR_RY25_... under 2025-04. A hardcoded list goes stale silently and
# then 404s, which is how ~/isochrones/R/download_medicare_partd_2022_2023.R
# ended up pinning two UUIDs by hand. CMS publishes a DCAT catalog at
# https://data.cms.gov/data.json listing every dataset with its current
# downloadURL; this script reads that and takes whatever CMS says is current.
#
# WHAT IS REACHABLE FROM HERE, tested 2026-11-09:
#   data.cms.gov/data.json ................................. 200, 3,522 datasets
#   data.cms.gov/sites/default/files/... (the file store) .. 200
#   data.cms.gov/provider-data/* ........................... 403, Akamai edge
#   openpaymentsdata.cms.gov metastore ..................... 403
# The 403s are why DAC/Facility-Affiliation history cannot be fetched here;
# see docs/source-series-reconstruction.md S2.3.
#
# IDEMPOTENT: a year whose file is already on the volume is skipped, not
# re-fetched. Re-running after an interrupted download resumes it (curl -C -).
#
# Inputs : https://data.cms.gov/data.json (live)
# Outputs: <volume>/medicare_part_b_by_provider/part_b_by_provider_<year>.csv
#          <volume>/medicare_part_d_by_provider/part_d_by_provider_<year>.csv
#          artifacts/cms_by_provider_download_manifest.csv (what was resolved,
#            what was fetched, and the sha256 of every file now present --
#            so a rebuild is traceable to bytes rather than to a file date)
# =============================================================================
suppressPackageStartupMessages({library(jsonlite); library(digest)})
source(file.path("R", "lib", "medicare_duckdb.R"))  # samsung_volume_path()

CATALOG <- "https://data.cms.gov/data.json"
# Which years this project wants. Part D 2022-2023 and Part B 2013-2023 are
# deliberately absent: the warehouse already holds those as the identical
# product, and re-fetching 1.3 GB to duplicate bytes on the same drive buys
# nothing. See extract_medicare_part_b_d_cohort_states.R for the year split.
WANT <- list(part_d = c(2013:2021, 2024L),
             part_b = 2024L)

TITLE_RE <- c(
  part_d = "^Medicare Part D Prescribers - by Provider : (\\d{4})-",
  part_b = "^Medicare Physician & Other Practitioners - by Provider : (\\d{4})-")

#' Resolve every by-provider CSV CMS currently publishes, by data year
#'
#' Reads the DCAT catalog once and returns one row per (source, year) with the
#' URL CMS is serving today. A dataset whose title does not match one of the
#' two families, or that publishes no CSV distribution, is ignored rather than
#' guessed at.
#'
#' @param catalog_url [character] the DCAT endpoint. Parameterised so a test
#'   can point it at a fixture instead of the network.
#' @return [data.frame] source, year, url -- sorted, unique, possibly empty.
resolve_by_provider_urls <- function(catalog_url = CATALOG) {
  cat(sprintf("reading %s ...\n", catalog_url))
  cat <- jsonlite::fromJSON(catalog_url, simplifyVector = FALSE)$dataset
  out <- list()
  for (ds in cat) {
    title <- if (is.null(ds$title)) "" else ds$title
    for (src in names(TITLE_RE)) {
      m <- regmatches(title, regexec(TITLE_RE[[src]], title))[[1]]
      if (length(m) < 2L) next
      urls <- vapply(ds$distribution %||% list(),
                     function(d) if (is.null(d$downloadURL)) "" else d$downloadURL, "")
      urls <- urls[grepl("\\.csv$", urls, ignore.case = TRUE)]
      if (!length(urls)) next
      out[[length(out) + 1L]] <- data.frame(source = src, year = as.integer(m[2]),
                                            url = urls[1], stringsAsFactors = FALSE)
    }
  }
  if (!length(out)) return(data.frame(source = character(), year = integer(), url = character()))
  r <- unique(do.call(rbind, out))
  r[order(r$source, r$year), , drop = FALSE]
}
`%||%` <- function(a, b) if (is.null(a)) b else a

#' Fetch one file unless it is already complete on disk
#'
#' @param url,dest [character] source and destination.
#' @return [integer] curl's exit status; 0 on success. A non-zero status is
#'   returned, never swallowed -- the caller records it in the manifest. This
#'   function captures the status immediately after curl for a reason: writing
#'   `rc=$?` inside a later `$(date)` interpolation reads the DATE command's
#'   status, which on 2026-11-09 made 9 failed downloads log as successes.
fetch_one <- function(url, dest) {
  if (file.exists(dest) && file.size(dest) > 0) {
    cat(sprintf("  have   %s (%.0f MB)\n", basename(dest), file.size(dest) / 1024^2))
    return(0L)
  }
  cat(sprintf("  GET    %s\n", basename(dest)))
  rc <- system2("curl", c("-fL", "-C", "-", "--retry", "5", "--retry-delay", "10",
                          "--connect-timeout", "60", "--max-time", "7200",
                          "-s", "-o", shQuote(dest), shQuote(url)))
  rc <- as.integer(rc)
  if (rc != 0L) cat(sprintf("  FAIL   %s (curl rc=%d)\n", basename(dest), rc))
  rc
}

if (sys.nframe() == 0L) {
  urls <- resolve_by_provider_urls()
  cat(sprintf("catalog lists %d by-provider files\n", nrow(urls)))

  rows <- list()
  for (src in names(WANT)) {
    dir_rel <- sprintf("medicare_%s_by_provider", src)
    dest_dir <- file.path(dirname(samsung_volume_path("DuckDB", must_exist = FALSE) %||%
                                  "/Volumes/MufflySamsung/DuckDB"), dir_rel)
    dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)
    cat(sprintf("\n%s -> %s\n", src, dest_dir))
    for (y in WANT[[src]]) {
      hit <- urls[urls$source == src & urls$year == y, , drop = FALSE]
      if (!nrow(hit)) {
        cat(sprintf("  MISS   %s %d not in catalog\n", src, y))
        rows[[length(rows) + 1L]] <- data.frame(source = src, year = y, url = NA_character_,
          path = NA_character_, bytes = NA_real_, sha256 = NA_character_,
          status = "not_in_catalog", stringsAsFactors = FALSE)
        next
      }
      dest <- file.path(dest_dir, sprintf("%s_by_provider_%d.csv", src, y))
      rc <- fetch_one(hit$url[1], dest)
      okf <- rc == 0L && file.exists(dest) && file.size(dest) > 0
      rows[[length(rows) + 1L]] <- data.frame(source = src, year = y, url = hit$url[1],
        path = dest, bytes = if (okf) file.size(dest) else NA_real_,
        # sha256 of a 600 MB CSV takes seconds and is the only thing that ties
        # this file to the artifact built from it without trusting mtime.
        sha256 = if (okf) digest::digest(dest, algo = "sha256", file = TRUE) else NA_character_,
        status = if (okf) "ok" else sprintf("curl_rc_%d", rc), stringsAsFactors = FALSE)
    }
  }
  man <- do.call(rbind, rows)
  dir.create("artifacts", showWarnings = FALSE)
  utils::write.csv(man, "artifacts/cms_by_provider_download_manifest.csv", row.names = FALSE)
  cat(sprintf("\n%d/%d ok -> artifacts/cms_by_provider_download_manifest.csv\n",
              sum(man$status == "ok"), nrow(man)))
  if (any(man$status != "ok")) quit(status = 1L)
}
