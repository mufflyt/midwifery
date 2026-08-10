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
#' Make a path repo-relative
#'
#' CYCLE 21. The first version recorded whatever path the caller passed, which
#' for `R/01` meant an ABSOLUTE one:
#'   "/Users/tylermuffly/midwifery/data/rucc_2023.xlsx"
#' On any other machine -- a clone, a collaborator, CI -- that file does not
#' exist, `check_provenance()` reports `current = NA`, and every artifact is
#' declared stale. That is the precise opposite of the property cycle 18 claimed
#' for this mechanism, which was that it survives copying and cloning where
#' mtime does not. Paths are therefore stored relative to the repo root.
#' @keywords internal
#' @noRd
.repo_relative <- function(p) {
  root <- normalizePath(".", winslash = "/", mustWork = FALSE)
  ab <- normalizePath(p, winslash = "/", mustWork = FALSE)
  ifelse(startsWith(ab, paste0(root, "/")), substring(ab, nchar(root) + 2L), p)
}

#' @param ... passed through to `readr::write_csv()`.
#'
#' CYCLE 21b. This used to hard-code `na = ""`. Of the 47 write sites in the
#' pipeline only 10 pass `na = ""` explicitly; the other 37 rely on readr's
#' default of `"NA"`. Converting them to a wrapper that forces `""` would have
#' rewritten every one of those artifacts -- silently changing how missingness
#' is represented in files this project has spent six cycles proving treat
#' missing and zero as different things. The wrapper now changes provenance
#' only, never content.
write_with_provenance <- function(x, path, inputs = character(0), ...) {
  readr::write_csv(x, path, ...)
  inputs <- inputs[file.exists(inputs)]
  side <- paste0(path, ".provenance.json")
  jsonlite::write_json(
    list(artifact = basename(path),
         written_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
         inputs = if (length(inputs))
           lapply(inputs, function(p) list(path = .repo_relative(p),
                                           sha256 = sha256_of(p)))
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
