#' @title Artifact freshness, by content rather than by clock
#'
#' @description
#' CYCLE 18. Two rate corrections (cycles 16 and 17) rebuilt
#' `data/county_base.csv` and left **seven** downstream artifacts describing the
#' old numbers, with nothing to say so. A reader opening
#' `geocoding_completeness_rucc.csv` sees a table, not a date.
#'
#' @section Why not modification time:
#' `file.mtime()` finds this today and will lie tomorrow. `git checkout`, `cp`,
#' `rsync` and archive extraction all rewrite mtimes, in either direction, so a
#' fresh clone can show every artifact "newer" than its inputs while containing
#' stale numbers. mtime is a useful smoke alarm and a bad contract.
#'
#' Provenance is therefore recorded by CONTENT: when an artifact is written, the
#' SHA-256 of every input that produced it is written beside it. An artifact is
#' stale when an input's current hash differs from the one recorded, which
#' survives copying, cloning and restoring from backup.
#'
#' Uses the canonical `sha256_of()` from R/lib/provenance.R rather than a
#' seventh local copy (see cycle 9).
#'
#' @family provenance

source(file.path("R", "lib", "provenance.R"))

#' Write an artifact together with the hashes of its inputs
#'
#' @param x [data.frame]: the artifact.
#' @param path [character(1)]: where to write it.
#' @param inputs [character]: paths this artifact was computed from.
#' @return `path`, invisibly.
#' @family provenance
write_with_provenance <- function(x, path, inputs = character(0)) {
  readr::write_csv(x, path, na = "")
  inputs <- inputs[file.exists(inputs)]
  side <- paste0(path, ".provenance.json")
  jsonlite::write_json(
    list(artifact = basename(path),
         written_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
         inputs = if (length(inputs))
           lapply(inputs, function(p) list(path = p, sha256 = sha256_of(p)))
         else list()),
    side, auto_unbox = TRUE, pretty = TRUE)
  invisible(path)
}

#' Check an artifact against the inputs it recorded
#'
#' @param path [character(1)]: the artifact.
#' @return [data.frame] one row per input: `path`, `recorded`, `current`,
#'   `stale`. Zero rows when no sidecar exists, which is itself reportable.
#' @family provenance
check_provenance <- function(path) {
  side <- paste0(path, ".provenance.json")
  empty <- data.frame(path = character(0), recorded = character(0),
                      current = character(0), stale = logical(0))
  if (!file.exists(side)) return(empty)
  m <- jsonlite::read_json(side, simplifyVector = FALSE)
  if (!length(m$inputs)) return(empty)
  do.call(rbind, lapply(m$inputs, function(i) {
    cur <- if (file.exists(i$path)) sha256_of(i$path) else NA_character_
    data.frame(path = i$path, recorded = i$sha256, current = cur,
               stale = !identical(cur, i$sha256), stringsAsFactors = FALSE)
  }))
}
