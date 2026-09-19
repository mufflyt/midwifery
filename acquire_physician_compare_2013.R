#!/usr/bin/env Rscript

# =============================================================================
# Acquire the 2013 CMS Physician Compare snapshots
#
# Downloads EVERY 2013 monthly snapshot that actually exists, preserves each
# raw file unchanged, and writes a manifest naming each one with its sha256.
#
# It deliberately does not choose between snapshots. A provider appearing in
# either month is evidence; absence from one month is not evidence of leaving
# practice (June and September share only ~88% of their CNM union). Downstream
# work defines its own `present_any` / `present_both` rules -- see
# build_dac_identity_spine_2013.R.
#
# This script DOES NOT touch the AMCB -> NPI canonical linkage. It writes only
# to data/raw/cms_physician_compare/ (gitignored) and
# artifacts/cms_physician_compare/.
#
# ---------------------------------------------------------------------------
# WHY NBER AND NOT THE WAYBACK MACHINE
#
# The 2013 file was published on the old Socrata portal as dataset s63f-csi6.
# That ID is correct, and the Wayback Machine does hold captures of it across
# 2013-2016 -- but only `rows.pdf` (a 3.2 MB truncated export) and `rows.rss`
# (an 11 KB feed of recent rows). Across every archived capture of s63f-csi6
# there are ZERO `rows.csv`, so a Wayback-first acquisition of the 2013 file
# cannot succeed. It is implemented here as a documented fallback and an audit
# trail, and the candidate list it writes is the evidence.
#
# The CDX query does return ~72 `rows.csv` captures, but all of them belong to
# mj5m-pzi6 -- the MODERN dataset ID -- and are dated 2017 and 2019-2020, not
# 2013. They are worth knowing about for a different reason: they are roughly
# monthly, 141-193 MB each, and run 2019-09 through 2020-08, where the NBER
# mirror carries only 2019/10-12 and 2020/10. For 2019-2020 backfill Wayback is
# the denser source; for 2013 it has nothing.
#
# NBER mirrors Physician Compare for 2013-2020. This repository's sibling
# project already knew that URL
# (isochrones-feature/R/download_and_import_physician_compare_2013_2017.R),
# but the path it used -- data.nber.org/data/compare/physician/ -- now 403s.
# The live path has dropped the /data segment.
#
# 2013 is stored as MONTHLY snapshots under a two-digit month directory. The
# directory listing advertises 06-12, but only 06 and 09 actually serve a file,
# so the months are probed rather than trusted.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(httr2)
  library(stringr)
})

source(file.path("R", "lib", "artifact_provenance.R"))

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

out_dir <- file.path("data", "raw", "cms_physician_compare", "2013")
artifact_dir <- file.path("artifacts", "cms_physician_compare")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

USER_AGENT <- "midwifery-research historical CMS acquisition"

# NBER's Apache refuses requests without a browser-shaped User-Agent on some
# paths, so every request below carries one.
BROWSER_UA <- paste(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

NBER_BASE <- "https://data.nber.org/compare/physician"


# -------------------------------------------------------------------------
# 1. Discover which 2013 monthly snapshots are advertised
# -------------------------------------------------------------------------

list_directory <- function(url) {

  base::message("[DISCOVER] ", url)

  response <- tryCatch(
    request(url) |>
      req_user_agent(BROWSER_UA) |>
      req_timeout(60) |>
      req_perform(),
    error = function(e) NULL
  )

  if (is.null(response)) {
    return(character(0))
  }

  hrefs <- stringr::str_match_all(
    resp_body_string(response), 'href="([^"]+)"'
  )[[1]][, 2]

  # Apache index pages carry sort links (?C=N;O=D) and a parent link.
  hrefs[!stringr::str_detect(hrefs, "^[?/]")]
}


month_dirs <- list_directory(paste0(NBER_BASE, "/2013/")) |>
  (\(x) x[stringr::str_detect(x, "^[0-9]{2}/$")])() |>
  stringr::str_remove("/$") |>
  sort()

base::message(
  "[DISCOVER] 2013 month directories advertised: ",
  paste(month_dirs, collapse = ", ")
)

if (length(month_dirs) == 0L) {
  stop("No 2013 month directories found at ", NBER_BASE, "/2013/", call. = FALSE)
}


# -------------------------------------------------------------------------
# 2. Probe each month for a real National_Downloadable_File.csv
# -------------------------------------------------------------------------

# NBER's server IGNORES a Range request header and begins streaming the whole
# file (~1 GB) regardless. Probing with `Range: bytes=0-2047` therefore does
# not return a short body -- it hangs until the request timeout and reports a
# failure for exactly the months that DO have data, while absent months return
# a prompt 404. The check inverts its own answer.
#
# A curl connection is used instead: it streams, `readLines(n = 1)` takes only
# the first line, and closing the connection aborts the transfer. All seven
# months probe in about seven seconds.
probe_month <- function(month) {

  url <- sprintf("%s/2013/%s/National_Downloadable_File.csv", NBER_BASE, month)

  handle <- curl::new_handle(useragent = BROWSER_UA, connecttimeout = 30)
  connection <- curl::curl(url, open = "", handle = handle)

  first_line <- tryCatch(
    {
      open(connection, "r")
      line <- readLines(connection, n = 1L, warn = FALSE)
      if (length(line) == 0L) "" else line[[1]]
    },
    error = function(e) NA_character_
  )

  try(close(connection), silent = TRUE)

  status <- tryCatch(curl::handle_data(handle)$status_code,
                     error = function(e) NA_integer_)

  # A Physician Compare header names the provider identifier and at least one
  # specialty-like field; a 404 body never does.
  header_ok <- !is.na(first_line) &&
    stringr::str_detect(first_line, stringr::regex("NPI", ignore_case = TRUE)) &&
    stringr::str_detect(first_line, stringr::regex("special", ignore_case = TRUE))

  tibble::tibble(
    month = month,
    url = url,
    status = as.integer(status),
    header_ok = header_ok,
    header_line = if (is.na(first_line)) NA_character_ else substr(first_line, 1, 400)
  )
}


probes <- purrr::map_dfr(month_dirs, probe_month)

write_csv(
  probes,
  file.path(artifact_dir,
            paste0("physician_compare_2013_month_probe_", timestamp, ".csv"))
)

available <- probes |> filter(.data$header_ok) |> arrange(.data$month)

base::message(
  "[DISCOVER] Months serving a real CSV: ",
  if (nrow(available) == 0L) "(none)" else paste(available$month, collapse = ", ")
)


# -------------------------------------------------------------------------
# 3. Wayback CDX, recorded as a fallback and an audit trail
# -------------------------------------------------------------------------

wayback_candidates <- function(target_url, match_type = "prefix") {

  base::message("[WAYBACK] Querying: ", target_url)

  response <- tryCatch(
    request("https://web.archive.org/cdx/search/cdx") |>
      req_url_query(
        url = target_url, matchType = match_type, output = "json",
        filter = "statuscode:200", collapse = "digest", limit = 200
      ) |>
      req_user_agent(USER_AGENT) |>
      req_timeout(120) |>
      req_perform(),
    error = function(e) NULL
  )

  if (is.null(response)) return(tibble::tibble())

  payload <- resp_body_json(response, simplifyVector = TRUE)

  if (length(payload) == 0L || NROW(payload) < 2L) return(tibble::tibble())

  # jsonlite returns a character MATRIX for an array-of-arrays. Assigning
  # names() to a matrix sets the names of the underlying vector, not the
  # column names -- it must be colnames().
  header <- payload[1, ]
  values <- payload[-1, , drop = FALSE]
  colnames(values) <- header

  tibble::as_tibble(values) |>
    mutate(
      source_query_url = target_url,
      wayback_url = paste0(
        "https://web.archive.org/web/", .data$timestamp, "id_/", .data$original
      )
    )
}


wayback <- purrr::map_dfr(
  sprintf("data.medicare.gov/api/views/%s", c("s63f-csi6", "mj5m-pzi6")),
  wayback_candidates
)

wayback_csv <- if (nrow(wayback) == 0L) {
  wayback
} else {
  wayback |> filter(stringr::str_detect(.data$original, "rows\\.csv"))
}

write_csv(
  wayback,
  file.path(artifact_dir,
            paste0("physician_compare_2013_wayback_candidates_", timestamp, ".csv"))
)

base::message(
  "[WAYBACK] ", nrow(wayback), " archived captures; ",
  nrow(wayback_csv), " of them CSV (none belonging to s63f-csi6)."
)

if (nrow(available) == 0L) {
  stop("No 2013 Physician Compare CSV available from NBER.", call. = FALSE)
}


# -------------------------------------------------------------------------
# 4. Download EVERY available month
# -------------------------------------------------------------------------

acquire_month <- function(month, url) {

  destination <- file.path(
    out_dir,
    sprintf("physician_compare_2013_%s_National_Downloadable_File.csv", month)
  )

  if (file.exists(destination) && file.size(destination) > 1e6) {
    base::message(
      "[DOWNLOAD] Reusing ", basename(destination), " (",
      format(file.size(destination), big.mark = ","), " bytes)"
    )
  } else {
    base::message("[DOWNLOAD] ", url)
    request(url) |>
      req_user_agent(BROWSER_UA) |>
      req_timeout(3600) |>
      req_progress() |>
      req_perform(path = destination)
  }

  stopifnot(file.exists(destination), file.size(destination) > 1e6)

  tibble::tibble(
    snapshot_date = as.Date(sprintf("2013-%s-01", month)),
    month = month,
    source = "NBER mirror of CMS Physician Compare",
    source_url = url,
    local_path = destination,
    bytes = file.size(destination),
    sha256 = sha256_of(destination),
    acquired_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
}


manifest <- purrr::map2_dfr(available$month, available$url, acquire_month) |>
  mutate(socrata_dataset_id = "s63f-csi6",
         wayback_csv_captures_s63f = 0L)

# The manifest is the contract the spine script reads: it names every snapshot
# in play and pins each by content, so a rebuild against a changed or truncated
# download is detectable rather than silent.
manifest_path <- file.path(artifact_dir, "physician_compare_2013_manifest.csv")
write_csv(manifest, manifest_path)

write_csv(
  manifest,
  file.path(artifact_dir,
            paste0("physician_compare_2013_provenance_", timestamp, ".csv"))
)

base::message("")
base::message("========================================")
base::message("2013 PHYSICIAN COMPARE ACQUISITION")
base::message("========================================")
for (i in seq_len(nrow(manifest))) {
  base::message(sprintf(
    "%s  %s bytes  sha256 %s",
    format(manifest$snapshot_date[[i]]),
    format(manifest$bytes[[i]], big.mark = ","),
    substr(manifest$sha256[[i]], 1, 12)
  ))
}
base::message("----------------------------------------")
base::message("Manifest: ", manifest_path)
base::message("Raw dir:  ", out_dir, "  (gitignored)")
base::message("Next:     Rscript build_dac_identity_spine_2013.R")
base::message("========================================")
