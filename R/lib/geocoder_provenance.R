# =============================================================================
# What a geocoder_provenance value actually says, and what it does not
# =============================================================================
# 58.6% of the coordinates in the geocoding cache carry a label that identifies
# WHEN they arrived, not WHO produced them: `legacy_csv_20251011` (13,449),
# `cohort_backfill_20260603` (3,962), `unknown+shared_merge` (110). Only 41.4%
# name an actual geocoder. `match_type` tells the same story from the other
# side -- `cache_merge` for 17,411 rows, which describes the TRANSFER, not the
# geocode. These coordinates place every midwife on the access maps and drive
# the rurality assignment behind the persistence analysis, and this repository
# has already had to reconstruct one layer after finding values that turned out
# to be synthesised rather than sourced
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). "Came from a CSV on
# 2025-10-11" is a weaker floor than that history warrants. See issue #225.
#
# NOTHING HERE CLAIMS THE COORDINATES ARE WRONG. `validation_status` is `valid`
# for all 29,909. The claim is narrower: for 58.6% of them the recorded
# provenance cannot answer "which geocoder produced this, and at what
# precision". This file makes that distinction machine-readable instead of
# leaving it to a reader recognising a date suffix.
#
# THE RECOVERY PATH. `geocoding_attempt_log` records, per address_hash, which
# provider was tried and whether it succeeded. Where a successful attempt
# exists, it names the real geocoder behind an import label --
# resolve_effective_provenance() prefers it. Measured on the current cache,
# that resolves 3,644 of 3,962 `cohort_backfill_20260603` rows (92%) but only
# 146 of 13,449 `legacy_csv_20251011` rows (1%): the legacy import predates the
# attempt log, so for those the source file is the whole of the record and the
# provider is not recoverable from here.
#
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

#' Every geocoder_provenance value the cache is known to carry
#'
#' `class` is the point of this table:
#'   * `geocoder`      the label names the service that produced the coordinate.
#'   * `import_event`  the label names when a batch arrived. It says nothing
#'                     about who produced the coordinate or at what precision.
#'   * `unknown`       the label says, explicitly, that nobody knows.
#'
#' `is_defect` marks the values that should not be treated as provenance at all.
#' `unknown+shared_merge` is a defect class rather than a value: 110 coordinates
#' whose origin was already lost at merge time. They are excluded from
#' precision-sensitive use rather than carried as if described.
#'
#' Adding a row here is a deliberate act. An UNRECOGNISED value is an error in
#' [classify_geocoder_provenance()], not a silent "unknown" -- a new import
#' label appearing unannounced is exactly the drift this table exists to catch.
GEOCODER_PROVENANCE_REGISTRY <- data.frame(
  geocoder_provenance = c(
    "census_batch", "ArcGIS_World", "OpenStreetMap_Nominatim",
    "City_Centroid_Dataset",
    "legacy_csv_20251011", "cohort_backfill_20260603",
    "unknown+shared_merge"),
  class = c(
    "geocoder", "geocoder", "geocoder", "geocoder",
    "import_event", "import_event",
    "unknown"),
  is_defect = c(FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, TRUE),
  note = c(
    "US Census Bureau batch geocoder; returns street-segment interpolation",
    "ArcGIS World Geocoding Service",
    "OpenStreetMap Nominatim",
    "A city centroid, not a match to the address. One row, and a very different precision claim from a rooftop match",
    "A CSV imported 2025-10-11. The producing geocoder is not recorded, and predates the attempt log, so it is not recoverable from the cache",
    "A backfill run on 2026-06-03. The attempt log resolves the real provider for most of these",
    "DEFECT CLASS: origin already lost when these were merged in. Not usable where precision matters"),
  stringsAsFactors = FALSE
)

#' Precision, from `match_type` and the provenance together
#'
#' `match_type` alone is dominated by `cache_merge`, which describes how the row
#' got here rather than how the point was found. A city centroid is a legitimate
#' fallback but a very different precision claim from a rooftop match, so it is
#' never allowed to read as one.
#'
#' @param geocoder_provenance,match_type character vectors, same length.
#' @return character vector: `city_centroid`, `address_match`, `interpolated`,
#'   or `unknown`.
geocode_precision_class <- function(geocoder_provenance, match_type) {
  p <- as.character(geocoder_provenance)
  m <- as.character(match_type)
  out <- rep("unknown", length(p))
  out[!is.na(m) & m == "interpolated"] <- "interpolated"
  out[!is.na(m) & m == "match"] <- "address_match"
  # Last, so it wins: a centroid is a centroid whatever match_type says.
  out[!is.na(p) & p == "City_Centroid_Dataset"] <- "city_centroid"
  out
}

#' Classify provenance values against the registry
#'
#' @param x character vector of `geocoder_provenance` values.
#' @return data.frame with `geocoder_provenance`, `class`, `is_defect`, `note`,
#'   in the order given.
#' @details Stops on a value the registry does not know. Falling back to
#'   "unknown" would let a new import label enter the study wearing the same
#'   shape as a described one.
classify_geocoder_provenance <- function(x) {
  x <- as.character(x)
  unknown <- setdiff(unique(x[!is.na(x)]), GEOCODER_PROVENANCE_REGISTRY$geocoder_provenance)
  if (length(unknown)) {
    stop(sprintf(paste0(
      "geocoder_provenance value(s) not in GEOCODER_PROVENANCE_REGISTRY: %s.\n",
      "  Add each one to R/lib/geocoder_provenance.R with its class\n",
      "  (geocoder / import_event / unknown) and a note saying what it means.\n",
      "  A new label must be classified deliberately, not defaulted to 'unknown'."),
      paste(unknown, collapse = ", ")), call. = FALSE)
  }
  i <- match(x, GEOCODER_PROVENANCE_REGISTRY$geocoder_provenance)
  data.frame(
    geocoder_provenance = x,
    class = GEOCODER_PROVENANCE_REGISTRY$class[i],
    is_defect = GEOCODER_PROVENANCE_REGISTRY$is_defect[i],
    note = GEOCODER_PROVENANCE_REGISTRY$note[i],
    stringsAsFactors = FALSE
  )
}

#' The geocoder actually behind a coordinate, where the cache can say
#'
#' An import label is replaced by the provider of a SUCCESSFUL attempt on the
#' same address, when the attempt log has one. A label that already names a
#' geocoder is never overwritten: the recorded producer beats an inference.
#'
#' @param geocoder_provenance character vector, the cache's own label.
#' @param log_provider character vector, same length: the provider of a
#'   successful `geocoding_attempt_log` row for the same `address_hash`, or NA.
#' @return character vector. The resolved provider where one was recovered,
#'   otherwise the original label unchanged.
resolve_effective_provenance <- function(geocoder_provenance, log_provider) {
  stopifnot(length(geocoder_provenance) == length(log_provider))
  p <- as.character(geocoder_provenance)
  lp <- as.character(log_provider)
  cls <- GEOCODER_PROVENANCE_REGISTRY$class[
    match(p, GEOCODER_PROVENANCE_REGISTRY$geocoder_provenance)]
  replaceable <- !is.na(cls) & cls %in% c("import_event", "unknown") &
    !is.na(lp) & nzchar(lp)
  p[replaceable] <- lp[replaceable]
  p
}
