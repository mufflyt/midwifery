# =============================================================================
# resolve_lat_lon_columns(): no swap, no fabricated coordinates
# =============================================================================
# geocode_panel_addresses.R broke once already when the geocoding cache's
# coordinate columns were renamed (latitude/longitude -> lat/lon) without
# every reader being updated. resolve_lat_lon_columns() (R/lib/geocode_cache_columns.R)
# was extracted from that fix so it can be proven in isolation: it must never
# resolve latitude and longitude to each other's column, must error rather
# than guess when neither naming scheme is present, and the end-to-end query
# built from its result must preserve NULL-coordinate rows as missing, not
# silently coerce or fabricate them.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "geocode_cache_columns.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

# -----------------------------------------------------------------------------
# 1. Pure column-name resolution
# -----------------------------------------------------------------------------
ci_section("resolve_lat_lon_columns(): naming schemes")

r1 <- resolve_lat_lon_columns(c("address_hash", "latitude", "longitude", "quality_score"))
if (identical(r1$lat_col, "latitude") && identical(r1$lon_col, "longitude")) {
  ci_ok("latitude/longitude naming resolves without swap")
} else {
  ci_fail("latitude/longitude naming resolved wrong: lat_col=%s lon_col=%s", r1$lat_col, r1$lon_col)
}

r2 <- resolve_lat_lon_columns(c("address_hash", "lat", "lon", "quality_score"))
if (identical(r2$lat_col, "lat") && identical(r2$lon_col, "lon")) {
  ci_ok("lat/lon naming resolves without swap")
} else {
  ci_fail("lat/lon naming resolved wrong: lat_col=%s lon_col=%s", r2$lat_col, r2$lon_col)
}

# Both naming schemes present at once: resolution must still be internally
# consistent -- lat_col and lon_col must come from the SAME scheme, never one
# from each (which would silently pair latitude's value with lon's column or
# vice versa further downstream).
r3 <- resolve_lat_lon_columns(c("latitude", "longitude", "lat", "lon"))
same_scheme <- (identical(r3$lat_col, "latitude") && identical(r3$lon_col, "longitude")) ||
               (identical(r3$lat_col, "lat") && identical(r3$lon_col, "lon"))
if (same_scheme) {
  ci_ok("both naming schemes present: resolves to one consistent scheme (lat_col=%s, lon_col=%s), not a cross-scheme mix",
        r3$lat_col, r3$lon_col)
} else {
  ci_fail("both naming schemes present: resolved to a cross-scheme mix (lat_col=%s, lon_col=%s) -- this could pair one scheme's latitude with the other's longitude", r3$lat_col, r3$lon_col)
}

# -----------------------------------------------------------------------------
# 2. Must error, not guess, when a coordinate is unresolvable
# -----------------------------------------------------------------------------
ci_section("resolve_lat_lon_columns(): fail-closed on missing columns")

expect_error <- function(cache_cols, label) {
  ok <- tryCatch({ resolve_lat_lon_columns(cache_cols); FALSE },
                 error = function(e) TRUE)
  if (ok) ci_ok("%s correctly errors instead of guessing", label)
  else ci_fail("%s did NOT error -- resolve_lat_lon_columns() silently guessed a missing coordinate", label)
}
expect_error(c("address_hash", "latitude"), "only latitude present (no lat/lon/longitude)")
expect_error(c("address_hash", "longitude"), "only longitude present (no lat/lon/latitude)")
expect_error(c("address_hash", "quality_score"), "neither coordinate column present")
expect_error(character(0), "empty column list")

# -----------------------------------------------------------------------------
# 3. End-to-end: no swap, correct column names, missingness preserved
# -----------------------------------------------------------------------------
ci_section("end-to-end query: no swap, correct schema, missingness preserved")

check_end_to_end <- function(con, table_sql, insert_sql, lat_col_name, lon_col_name, label) {
  DBI::dbExecute(con, table_sql)
  DBI::dbExecute(con, insert_sql)
  cache_cols <- DBI::dbListFields(con, "geocoding_cache")
  cols <- resolve_lat_lon_columns(cache_cols)
  result <- DBI::dbGetQuery(con, sprintf("
    SELECT address_hash, %s AS latitude, %s AS longitude, quality_score, census_tract, county_fips
    FROM geocoding_cache WHERE %s IS NOT NULL", cols$lat_col, cols$lon_col, cols$lat_col))

  if (setequal(names(result), c("address_hash", "latitude", "longitude",
                                 "quality_score", "census_tract", "county_fips"))) {
    ci_ok("%s: result columns are exactly latitude/longitude/... regardless of source naming", label)
  } else {
    ci_fail("%s: unexpected result columns: %s", label, paste(names(result), collapse = ", "))
  }

  row <- result[result$address_hash == "has_coords", ]
  if (nrow(row) == 1 && abs(row$latitude - 40.7128) < 1e-9 && abs(row$longitude - (-74.0060)) < 1e-9) {
    ci_ok("%s: latitude/longitude values are not swapped (lat=%.4f, lon=%.4f)", label, row$latitude, row$longitude)
  } else {
    ci_fail("%s: latitude/longitude values are wrong or swapped: %s", label,
            if (nrow(row) == 1) sprintf("lat=%s lon=%s", row$latitude, row$longitude) else "row missing")
  }

  if (!"has_null_lat" %in% result$address_hash) {
    ci_ok("%s: row with NULL latitude is excluded (missingness preserved, not fabricated)", label)
  } else {
    ci_fail("%s: row with NULL latitude was NOT excluded -- missingness semantics broken", label)
  }

  DBI::dbExecute(con, "DROP TABLE geocoding_cache")
}

con <- duckdb_connect()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

check_end_to_end(con,
  "CREATE TABLE geocoding_cache (address_hash VARCHAR, latitude DOUBLE, longitude DOUBLE,
     quality_score DOUBLE, census_tract VARCHAR, county_fips VARCHAR)",
  "INSERT INTO geocoding_cache VALUES
     ('has_coords', 40.7128, -74.0060, 0.9, '36061000100', '36061'),
     ('has_null_lat', NULL, -74.0060, 0.9, '36061000100', '36061')",
  "latitude", "longitude", "latitude/longitude-named cache table")

check_end_to_end(con,
  "CREATE TABLE geocoding_cache (address_hash VARCHAR, lat DOUBLE, lon DOUBLE,
     quality_score DOUBLE, census_tract VARCHAR, county_fips VARCHAR)",
  "INSERT INTO geocoding_cache VALUES
     ('has_coords', 40.7128, -74.0060, 0.9, '36061000100', '36061'),
     ('has_null_lat', NULL, -74.0060, 0.9, '36061000100', '36061')",
  "lat", "lon", "lat/lon-named cache table")

ci_finish()
