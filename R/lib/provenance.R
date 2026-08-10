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
sha256_of <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    stop(sprintf("sha256_of: no such file: %s",
                 if (length(path) == 1L) path else "<not a single path>"),
         call. = FALSE)
  }
  sub(" .*$", "", system2("shasum", c("-a", "256", shQuote(path)), stdout = TRUE)[1])
}
