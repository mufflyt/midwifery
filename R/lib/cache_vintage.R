# =============================================================================
# Declaring the vintage of a mutable scientific input
# =============================================================================
# The geocoding cache decides coordinates. Coordinates decide counties. Counties
# decide rurality, and rurality is a headline of this study. So the cache is a
# scientific input -- and across every provenance sidecar in artifacts/ there
# are 105 distinct declared inputs and not one of them is a cache.
#
# The pipeline therefore computes
#
#     Y = f(X, whatever the cache holds at the moment it runs)
#
# while recording only X. Two researchers with identical code, identical frozen
# roster and identical declared inputs can legitimately get different geography,
# and nothing in the provenance would show why.
#
# THE FIX IS NOT AN IMMUTABLE CACHE. A cache that resolves more addresses next
# month is better evidence, not a bug, and forbidding it would be forbidding the
# study to improve. The fix is to record WHICH cache was used:
#
#     Y = f(X, C_v)
#
# where C_v is a specific snapshot with a recorded identity. A later C_v+1 is
# then a different declared input -- visible, attributable, and a reason for a
# number to move -- rather than unexplained drift.
#
# IDENTITY IS CONTENT, NOT TIME. An mtime changes when a row is read, when a
# file is copied, when a backup is restored; it does not change when the science
# does, and it changes when the science does not. The fingerprint below is a
# hash over the scientifically relevant fields only, sorted, so the same content
# written in any order yields the same identity.
#
# WHAT COUNTS AS SCIENTIFIC. Everything the answer depends on: the key, the
# coordinates, the geographies derived from them, the match quality and the
# provider that produced it. Deliberately excluded: created_at, last_accessed,
# expires_at, access_count -- bookkeeping that changes when the cache is merely
# CONSULTED. A fingerprint that moved because someone read the cache would be
# useless as an identity.
# =============================================================================

# The fields that decide a scientific answer. Ordered, so the hash is stable
# against a schema that gains or reorders columns.
CACHE_SCIENTIFIC_FIELDS <- c(
  "address_hash",          # the key the pipeline joins on
  "latitude", "longitude", # what the cache exists to supply
  "county_fips", "census_tract", "state_fips",
  "match_type", "validation_status", "geocoder_provenance"
)

# Bookkeeping that moves when the cache is READ. Never part of identity.
CACHE_VOLATILE_FIELDS <- c("created_at", "last_accessed", "expires_at",
                           "access_count", "run_id", "attempt_id")

#' Canonical fingerprint of a geocoding cache snapshot
#'
#' @param path [character]: DuckDB file.
#' @param table [character]: the cache table.
#' @return [list] identity fields. `available = FALSE` when the cache is absent
#'   or unreadable -- represented EXPLICITLY, never as an empty-but-valid
#'   snapshot, because "no cache" and "a cache with nothing relevant in it" are
#'   different claims and only one of them is a vintage.
#' @keywords internal
#' @noRd
geocode_cache_fingerprint <- function(path, table = "geocoding_cache") {
  absent <- function(reason) list(
    available = FALSE, reason = reason, path = path,
    n_entries = NA_integer_, content_sha256 = NA_character_,
    schema_fields = NA_character_, snapshot_utc = NA_character_)

  if (!file.exists(path)) return(absent("file does not exist"))
  if (!requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("duckdb", quietly = TRUE))
    return(absent("DBI/duckdb unavailable"))

  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = TRUE),
                  error = function(e) NULL)
  if (is.null(con)) return(absent("cannot open read-only (locked?)"))
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)

  if (!table %in% DBI::dbListTables(con)) return(absent(paste0("no table ", table)))
  have <- DBI::dbListFields(con, table)
  use <- intersect(CACHE_SCIENTIFIC_FIELDS, have)
  if (!length(use)) return(absent("no scientifically relevant field present"))

  # ORDER-INVARIANT BY CONSTRUCTION. Sorted in SQL by the key, and the columns
  # are selected in a fixed order rather than the table's, so neither row order
  # nor column order can move the identity.
  q <- sprintf("SELECT %s FROM %s ORDER BY %s",
               paste(sprintf('"%s"', use), collapse = ", "), table,
               paste(sprintf('"%s"', use), collapse = ", "))
  d <- tryCatch(DBI::dbGetQuery(con, q), error = function(e) NULL)
  if (is.null(d)) return(absent("cannot read cache table"))

  # Coordinates are rounded to six decimal places before hashing -- about 0.1 m,
  # far below any geocoder's real precision. Without it a float printed with one
  # more digit on another platform would read as a different scientific input.
  for (cc in intersect(c("latitude", "longitude"), names(d)))
    d[[cc]] <- sprintf("%.6f", suppressWarnings(as.numeric(d[[cc]])))
  flat <- paste(do.call(paste, c(lapply(d, as.character), sep = "\x1f")), collapse = "\n")

  list(available = TRUE, reason = NA_character_, path = path,
       n_entries = nrow(d),
       content_sha256 = as.character(openssl::sha256(flat)),
       schema_fields = paste(use, collapse = ","),
       snapshot_utc = format(Sys.time(), tz = "UTC", usetz = TRUE))
}

#' The fingerprint as a provenance input record
#'
#' Shaped like the other entries in a provenance sidecar so a stage can append
#' it without knowing anything about caches.
#' @keywords internal
#' @noRd
cache_provenance_entry <- function(fp) {
  if (!isTRUE(fp$available))
    return(list(path = fp$path, kind = "geocode_cache",
                available = FALSE, reason = fp$reason))
  list(path = fp$path, kind = "geocode_cache", available = TRUE,
       n_entries = fp$n_entries, sha256 = fp$content_sha256,
       schema_fields = fp$schema_fields, snapshot_utc = fp$snapshot_utc)
}
