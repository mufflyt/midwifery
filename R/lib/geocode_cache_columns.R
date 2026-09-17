#' Resolve the geocoding cache's actual lat/lon column names
#'
#' The cache's coordinate columns have been renamed at least once already
#' (latitude/longitude -> lat/lon) without every reader being updated, which
#' is exactly what broke geocode_panel_addresses.R's cache query. Detecting
#' the actual column names instead of assuming either lets a future rename
#' degrade to a clear error here rather than a silent 0% hit rate or another
#' binder error.
#'
#' @param cache_cols [character] column names actually present in the
#'   geocoding_cache table (e.g. from DBI::dbListFields()).
#' @return a list(lat_col, lon_col), each a single column name string.
#'   Errors (does not return NA) if either coordinate is not resolvable.
resolve_lat_lon_columns <- function(cache_cols) {
  lat_col <- intersect(c("latitude", "lat"), cache_cols)[1]
  lon_col <- intersect(c("longitude", "lon"), cache_cols)[1]
  if (is.na(lat_col) || is.na(lon_col))
    stop("geocoding_cache has neither latitude/longitude nor lat/lon columns; ",
         "found: ", paste(cache_cols, collapse = ", "), call. = FALSE)
  list(lat_col = lat_col, lon_col = lon_col)
}
