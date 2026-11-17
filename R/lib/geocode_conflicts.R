# =============================================================================
# Resolve conflicting coordinates for one address key
# =============================================================================
# The geocoding cache holds 55,843 rows for 54,225 distinct address keys, and
# 48 of those keys carry MORE THAN ONE coordinate: median spread 1.0 km, 90th
# percentile 13.8 km, maximum 1,074.8 km. The pipeline resolved this with
#
#     distinct(cache_key, .keep_all = TRUE)
#
# which keeps whichever row happens to sort first. Row order is not evidence.
# The same midwife could be placed in North Carolina or a thousand kilometres
# away depending on how the cache was written, and every isochrone, travel
# time and county assignment downstream inherits that choice silently.
#
# WHAT THIS DOES INSTEAD. Conflicts are resolved on quality_score, which is
# what that column is for. Where quality cannot discriminate and the
# disagreement is material, the key gets NO coordinate: an address we cannot
# place is missing data, not a coin flip. Every key carries the size of its
# disagreement so the loss is visible rather than inferred.
#
# WHY A THRESHOLD AT ALL. Geocoders differ in the last decimal for the same
# rooftop; refusing those would discard the entire cache. `max_spread_km`
# separates "same place, different precision" from "two different places".
# 1 km is deliberately tight for travel-time work -- at 30 mph it is two
# minutes of a 30-minute band.
#
# Sourced by geocode_midwives.R; tested by tests/test_cycle5_geocode_conflicts.R.
# =============================================================================

#' Collapse an address key to one coordinate, refusing to guess
#'
#' @param key [character]: address key; one output row per distinct value.
#' @param lat,lon [numeric]: coordinates.
#' @param quality [numeric]: quality score, higher is better. NA sorts last.
#' @param max_spread_km [numeric(1)]: disagreement above which an unresolved
#'   key is refused rather than picked.
#' @return [data.frame] one row per key: key, lat, lon, quality,
#'   `n_candidates`, `spread_km`, `resolution` in
#'   {"unique", "by_quality", "refused_ambiguous", "within_tolerance"}.
#'   Refused keys carry NA coordinates.
resolve_geocode_key <- function(key, lat, lon, quality = NULL,
                                max_spread_km = 1) {
  n <- length(key)
  stopifnot(length(lat) == n, length(lon) == n)
  if (is.null(quality)) quality <- rep(NA_real_, n)
  stopifnot(length(quality) == n)

  # Zero-length in, zero-length out with the right columns and types: an empty
  # data.frame with the wrong types poisons a downstream bind_rows().
  empty <- data.frame(key = character(0), lat = numeric(0), lon = numeric(0),
                      quality = numeric(0), n_candidates = integer(0),
                      spread_km = numeric(0), resolution = character(0),
                      stringsAsFactors = FALSE)
  if (!n) return(empty)

  d <- data.frame(key = as.character(key), lat = as.numeric(lat),
                  lon = as.numeric(lon), quality = as.numeric(quality),
                  stringsAsFactors = FALSE)

  # Great-circle spread within a key, in km. Not a bounding box: at these
  # latitudes a degree of longitude is not a degree of latitude, and a planar
  # approximation understates east-west disagreement.
  spread_km <- function(la, lo) {
    if (length(la) < 2) return(0)
    R <- 6371
    p <- la * pi / 180; l <- lo * pi / 180
    mx <- 0
    for (i in seq_along(la)) {
      dp <- p - p[i]; dl <- l - l[i]
      a <- sin(dp / 2)^2 + cos(p[i]) * cos(p) * sin(dl / 2)^2
      mx <- max(mx, max(2 * R * asin(pmin(1, sqrt(a)))))
    }
    mx
  }

  out <- lapply(split(d, d$key), function(g) {
    sp <- spread_km(g$lat, g$lon)
    res <- if (nrow(g) == 1L) "unique"
           else if (sp <= max_spread_km) "within_tolerance"
           else {
             # Quality decides only if it has a single strict winner.
             q <- g$quality
             if (all(is.na(q)) || sum(q == max(q, na.rm = TRUE), na.rm = TRUE) != 1L)
               "refused_ambiguous" else "by_quality"
           }
    pick <- switch(res,
      unique            = 1L,
      # Deterministic and order-independent: the tightest cluster is
      # represented by its first row after sorting by coordinate, never by
      # input order.
      within_tolerance  = order(g$lat, g$lon)[1],
      by_quality        = which.max(replace(g$quality, is.na(g$quality), -Inf)),
      refused_ambiguous = NA_integer_)
    data.frame(
      key = g$key[1],
      lat = if (is.na(pick)) NA_real_ else g$lat[pick],
      lon = if (is.na(pick)) NA_real_ else g$lon[pick],
      quality = if (is.na(pick)) NA_real_ else g$quality[pick],
      n_candidates = nrow(g), spread_km = sp, resolution = res,
      stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, out)
  rownames(out) <- NULL
  out[order(out$key), ]
}

#' Report what resolution cost, so the loss is never silent
#' @param resolved [data.frame]: output of `resolve_geocode_key()`.
#' @return [character(1)] one-line summary, invisibly also printed by callers.
summarise_geocode_resolution <- function(resolved) {
  tb <- table(factor(resolved$resolution,
                     levels = c("unique", "within_tolerance", "by_quality",
                                "refused_ambiguous")))
  sprintf(paste0("geocode keys: %s unique, %s within tolerance, %s resolved by ",
                 "quality, %s REFUSED as ambiguous (no coordinate)"),
          format(tb[["unique"]], big.mark = ","),
          format(tb[["within_tolerance"]], big.mark = ","),
          format(tb[["by_quality"]], big.mark = ","),
          format(tb[["refused_ambiguous"]], big.mark = ","))
}

#' The cache key with its ZIP field removed
#'
#' Both geocoding producers fall back to street+city+state when a record's ZIP
#' is missing or disagrees with the cache, and both have to strip it the SAME
#' way or a 9-digit cached ZIP defeats the fallback on one side only. The
#' one-liner lived in `geocode_midwives.R` and `geocode_panel_addresses.R`
#' separately, and it is the construction of a JOIN KEY -- the one category
#' where two copies drifting apart changes results silently.
#'
#' @param key [character] the pipe-delimited cache key.
#' @return [character] the key with its final `|field` dropped.
#' @export
drop_zip <- function(key) sub("\\|[^|]*$", "", key)

#' One row per zip-less key, chosen deterministically or not at all
#'
#' DROPPING THE ZIP MERGES KEYS THAT WERE DISTINCT, so this fallback can
#' create conflicts the keyed pass did not have: two different addresses on
#' the same street in different ZIPs collapse to one key. Both producers then
#' did the same four steps -- keep only rows whose coordinate matches the one
#' `resolve_geocode_key()` settled on, order totally, and take the first --
#' differing only in which columns break the tie and what the outputs are
#' called. The steps are here once; the renaming stays with the caller, where
#' the column names belong.
#'
#' `tiebreak` exists because the coordinate is already agreed by the time this
#' runs: what is left to choose is the METADATA row, and ordering by named
#' columns makes that choice reproducible instead of dependent on row order.
#'
#' @param cache_rows [data.frame] cache rows carrying `key_nozip`, `latitude`,
#'   `longitude`, `quality_score` and every column named in `tiebreak`.
#' @param resolved [data.frame] output of `resolve_geocode_key()` over
#'   `cache_rows$key_nozip`.
#' @param tiebreak [character] column names that break a remaining tie, in
#'   order. Required: an unordered pick is the defect this function prevents.
#' @return [data.frame] one row per resolved `key_nozip`, with `key_nozip`,
#'   `latitude`, `longitude`, `quality_score` and the `tiebreak` columns.
#' @export
collapse_zipless_key <- function(cache_rows, resolved, tiebreak) {
  missing_cols <- setdiff(c("key_nozip", "latitude", "longitude",
                            "quality_score", tiebreak), names(cache_rows))
  if (length(missing_cols)) {
    stop("collapse_zipless_key(): cache rows have no ",
         paste(missing_cols, collapse = ", "), " column. Without every ",
         "tiebreak column the ordering is partial and the surviving row ",
         "depends on row order, which is what this function exists to ",
         "prevent.", call. = FALSE)
  }
  if (!length(tiebreak)) {
    stop("collapse_zipless_key(): tiebreak is empty, so rows that agree on ",
         "coordinate and quality would be separated by row order alone.",
         call. = FALSE)
  }
  # match(), not merge(): resolve_geocode_key() returns ONE row per key, so
  # this is a lookup rather than a join, and a geocoding cache runs to a
  # million rows where merge() costs minutes and a copy of everything.
  settled <- resolved[!is.na(resolved$lat), , drop = FALSE]
  at <- match(cache_rows$key_nozip, settled$key)
  # The coordinate the resolver SETTLED ON, not merely some coordinate filed
  # under that key: a row the resolver did not pick must not supply the
  # metadata. A key it refused has no match and drops out here.
  keep <- !is.na(at) &
    cache_rows$latitude == settled$lat[at] &
    cache_rows$longitude == settled$lon[at]
  keep[is.na(keep)] <- FALSE
  kept <- cache_rows[keep, c("key_nozip", "latitude", "longitude",
                             "quality_score", tiebreak), drop = FALSE]
  ord <- do.call(order, c(list(kept$key_nozip, -xtfrm(kept$quality_score)),
                          unname(lapply(tiebreak, function(column)
                            kept[[column]]))))
  kept <- kept[ord, , drop = FALSE]
  kept <- kept[!duplicated(kept$key_nozip), , drop = FALSE]
  rownames(kept) <- NULL
  kept
}
