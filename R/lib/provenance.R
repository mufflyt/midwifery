#' @title Byte-level provenance helpers
#'
#' @description
#' CYCLE 9. `sha256_of()` was defined independently in SIX scripts
#' (`05-stage-progression.R`, `10-county-birth-profiles.R`,
#' `11-wonder-county-ingest.R`, `12-district-profiles.R`,
#' `13-geocode-ob-hospitals.R`, `lib/ab_middle_name_common.R`) in two textual
#' forms -- a one-liner and a block -- that happen to compute the same digest.
#'
#' Happening to agree is not the same as being required to agree. This is the
#' hash that ties an artifact to the bytes it was built from, so if one copy
#' were ever changed (to `openssl::sha256()` for speed, say, or to hash content
#' rather than the file) two scripts would report different provenance for the
#' same input and nothing would flag it. A provenance function is the last
#' thing that should exist in six versions.
#'
#' Sourced by the scripts above; asserted single-definition by
#' tests/test_cycle9_joins.R T84.

#' SHA-256 of a file's bytes
#'
#' @param path [character(1)]: path to an existing file.
#' @return [character(1)] lowercase hex digest.
#' @family provenance
# Within-run memo, keyed on the file's IDENTITY rather than its name: path,
# size and mtime together. Keying on the path alone would be wrong -- a script
# that writes an artifact and then hashes it again as an input to the next step
# would get the stale hash -- and keying on nothing at all is what this cache
# exists to fix: write_with_provenance() hashes its inputs once per artifact, so
# three artifacts sharing one 10.8 GB NPPES dissemination re-read 32 GB over
# USB to compute the same digest three times. Not persisted; a new session
# hashes afresh, which is the only safe default for provenance.
.sha256_memo <- new.env(parent = emptyenv())

sha256_of <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    stop(sprintf("sha256_of: no such file: %s",
                 if (length(path) == 1L) path else "<not a single path>"),
         call. = FALSE)
  }
  fi <- file.info(path)
  # FRACTIONAL mtime, deliberately. format(mtime, "%s") is whole seconds, and a
  # file rewritten to the same size within the same second then produces an
  # identical key -- the cache would serve the digest of bytes that are gone.
  # file.info() carries sub-second resolution on this filesystem, and the test
  # for exactly that case is T221b in tests/test_cycle21_provenance_wiring.R.
  key <- paste(normalizePath(path, mustWork = FALSE), fi$size,
               sprintf("%.6f", as.numeric(fi$mtime)), sep = "|")
  hit <- .sha256_memo[[key]]
  if (!is.null(hit)) return(hit)
  out <- sub(" .*$", "", system2("shasum", c("-a", "256", shQuote(path)), stdout = TRUE)[1])
  assign(key, out, envir = .sha256_memo)
  out
}
