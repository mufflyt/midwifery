#!/usr/bin/env Rscript
# =============================================================================
# Attach coordinates and county FIPS to matched midwives
# =============================================================================
#
# Reuses the isochrones geocoding cache (55,843 already-geocoded addresses)
# rather than re-geocoding. Two pieces of isochrones infrastructure do the work
# that this script used to hand-roll:
#
#   canonical_address_key()      R/geocode_cache_utils.R
#     Builds the "addr1|city|STATE|zip" cache key with USPS street-type
#     abbreviation, punctuation handling, locale-safe lowercasing, 5-digit ZIP
#     truncation, and rejection of whitespace-only / single-punctuation values
#     that would otherwise create phantom keys ("?|denver|CO|80202") that miss
#     on every retry. The previous inline sprintf() had none of that.
#
#   enrich_with_census_tracts()  R/enrich_geocode_tracts.R
#     Point-in-polygon against cached tract boundaries, returning census_tract,
#     state_fips and county_fips.
#
# WHY THE TRACT JOIN IS NOT OPTIONAL: the cache's own county_fips column is
# populated on 0 of 55,843 rows and census_tract on 6. Reading county straight
# out of the cache -- which this script used to do -- returns an all-NA column
# with no error, and every county-level rate downstream is then NA or silently
# dropped. County MUST be derived from the coordinates.
#
# Addresses that miss the cache are written to geocode_queue.csv for the
# existing 3-tier cascade (R/geocode_with_3tier_cascade.R); nothing here calls
# a geocoding service.
#
# Inputs : midwives_with_nppes.csv (carries practice_address from the NPI API)
# Outputs: midwives_geocoded.csv, geocode_queue.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
  library(DBI); library(duckdb); library(checkmate); library(here)
})

ISO <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
cache_path <- Sys.getenv("GEOCODING_CACHE_PATH",
                         path.expand("~/isochrones/data/geocoding_cache.duckdb"))
stopifnot(dir.exists(ISO), file.exists(cache_path))

for (f in c("geocode_cache_utils.R", "enrich_geocode_tracts.R")) {
  src <- file.path(ISO, f)
  if (!file.exists(src)) stop("Missing isochrones module: ", src, call. = FALSE)
  source(src)
}
stopifnot(exists("canonical_address_key", mode = "function"),
          exists("enrich_with_census_tracts", mode = "function"))

midwives <- read_csv("midwives_with_nppes.csv", show_col_types = FALSE)

if (!"practice_address" %in% names(midwives)) {
  stop("midwives_with_nppes.csv has no practice_address column -- it predates ",
       "the NPI API matcher. Re-run match_nppes.R first.", call. = FALSE)
}

located <- midwives %>%
  filter(!is.na(npi)) %>%
  mutate(cache_key = canonical_address_key(practice_address, practice_city,
                                           practice_state, practice_zip))

# --- Cache side ------------------------------------------------------------
con <- dbConnect(duckdb::duckdb(), cache_path, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cache_raw <- dbGetQuery(con, "
  SELECT address_hash, latitude, longitude, quality_score,
         geocoder_provenance, match_type
  FROM geocoding_cache
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL")

# The stored address_hash was built by an older key format that keeps the full
# 9-digit ZIP ('...|VA|240183436'), while canonical_address_key() truncates to
# 5 ('...|VA|24018'). Joining raw hashes would therefore miss nearly every row.
# Split the stored key back into fields and re-derive it through the SAME
# function, so both sides are normalized identically.
parts <- str_split_fixed(cache_raw$address_hash, stringr::fixed("|"), 4)
cache <- cache_raw %>%
  mutate(cache_key = canonical_address_key(parts[, 1], parts[, 2],
                                           parts[, 3], parts[, 4])) %>%
  filter(!is.na(cache_key)) %>%
  distinct(cache_key, .keep_all = TRUE)

# Zip-less fallback: same key minus the ZIP field, for records whose ZIP is
# missing or disagrees. Both sides drop it the same way.
drop_zip <- function(x) sub("\\|[^|]*$", "", x)
cache_nozip <- cache %>%
  mutate(key_nozip = drop_zip(cache_key)) %>%
  distinct(key_nozip, .keep_all = TRUE) %>%
  select(key_nozip, lat_nz = latitude, lon_nz = longitude,
         q_nz = quality_score, prov_nz = geocoder_provenance)

hit <- located %>%
  left_join(select(cache, cache_key, latitude, longitude, quality_score,
                   geocoder_provenance, match_type), by = "cache_key") %>%
  mutate(key_nozip = drop_zip(cache_key)) %>%
  left_join(cache_nozip, by = "key_nozip") %>%
  mutate(
    geocode_match = case_when(
      !is.na(latitude) ~ "exact_key",
      !is.na(lat_nz)   ~ "no_zip_key",
      TRUE             ~ NA_character_
    ),
    latitude            = coalesce(latitude, lat_nz),
    longitude           = coalesce(longitude, lon_nz),
    quality_score       = coalesce(quality_score, q_nz),
    geocoder_provenance = coalesce(geocoder_provenance, prov_nz)
  ) %>%
  select(-lat_nz, -lon_nz, -q_nz, -prov_nz, -key_nozip)

# --- County / tract from coordinates ---------------------------------------
# Preferred path: the isochrones tract enricher, which also yields census_tract
# for any sub-county work. It degrades GRACEFULLY -- warns and returns the input
# unchanged when tract boundaries are missing -- so never assume the columns
# arrived; check.
hit <- enrich_with_census_tracts(hit, lat_col = "latitude", lon_col = "longitude",
                                 tract_rds = Sys.getenv("TRACT_BOUNDARY_RDS",
                                                        unset = NA_character_) %>%
                                   (\(x) if (is.na(x) || !nzchar(x)) NULL else x)())

for (col in c("census_tract", "county_fips", "state_fips")) {
  if (!col %in% names(hit)) hit[[col]] <- NA_character_
}

#' Assign county FIPS by point-in-polygon against TIGER county boundaries
#'
#' Fallback for when tract boundaries are unavailable. County is the grain this
#' analysis actually joins on (data/county_base.csv), and the county layer is
#' ~3.2K features versus ~85K tracts, so this needs no external artifact --
#' tigris caches it locally. Tract stays NA; only county is recovered.
#'
#' @param df [data.frame]: rows with `latitude`/`longitude`.
#' @return [character] 5-character county GEOID, NA where no polygon contains
#'   the point (offshore, bad coordinates, or non-US).
assign_county_from_points <- function(df) {
  ok <- !is.na(df$latitude) & !is.na(df$longitude)
  out <- rep(NA_character_, nrow(df))
  if (!any(ok)) return(out)

  suppressPackageStartupMessages({ library(sf); library(tigris) })
  options(tigris_use_cache = TRUE)

  counties <- tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE) %>%
    sf::st_transform(4326)
  pts <- sf::st_as_sf(df[ok, c("longitude", "latitude")],
                      coords = c("longitude", "latitude"), crs = 4326)
  idx <- sf::st_within(pts, sf::st_geometry(counties))
  first <- vapply(idx, function(i) if (length(i)) i[1] else NA_integer_, integer(1))
  out[ok] <- counties$GEOID[first]
  out
}

if (all(is.na(hit$county_fips))) {
  message("[county] Tract boundaries unavailable; falling back to point-in-polygon ",
          "against TIGER county boundaries (county only, tract stays NA).")
  hit$county_fips <- assign_county_from_points(hit)
  hit$county_source <- if_else(is.na(hit$county_fips), NA_character_, "tigris_county_pip")
} else {
  hit$county_source <- if_else(is.na(hit$county_fips), NA_character_, "census_tract_join")
}

# GEOID is the join key for data/county_base.csv; pad so single-digit state
# codes cannot silently fail to match.
hit <- hit %>%
  mutate(GEOID = if_else(is.na(county_fips), NA_character_,
                         str_pad(as.character(county_fips), 5, "left", "0")))

out <- midwives %>%
  left_join(select(hit, certification_number, latitude, longitude,
                   quality_score, geocoder_provenance, geocode_match,
                   census_tract, county_fips, state_fips, county_source, GEOID),
            by = "certification_number")

write_csv(out, "midwives_geocoded.csv", na = "")

queue <- hit %>%
  filter(is.na(latitude), !is.na(practice_city)) %>%
  distinct(practice_address, practice_city, practice_state, practice_zip)
write_csv(queue, "geocode_queue.csv", na = "")

# --- Report ----------------------------------------------------------------
n <- nrow(hit)
pct <- function(x) sprintf("%s (%.1f%%)", format(sum(x), big.mark = ","),
                           100 * mean(x))

cat(sprintf("Matched to NPPES  : %s\n", format(n, big.mark = ",")))
cat(sprintf("Unresolvable keys : %s\n", pct(is.na(hit$cache_key))))
cat(sprintf("Cache hits        : %s\n", pct(!is.na(hit$latitude))))
cat(sprintf("  exact key       : %s\n",
            format(sum(hit$geocode_match == "exact_key", na.rm = TRUE), big.mark = ",")))
cat(sprintf("  no-zip fallback : %s\n",
            format(sum(hit$geocode_match == "no_zip_key", na.rm = TRUE), big.mark = ",")))
cat(sprintf("County assigned   : %s\n", pct(!is.na(hit$GEOID))))
cat(sprintf("Distinct counties : %s\n",
            format(dplyr::n_distinct(hit$GEOID, na.rm = TRUE), big.mark = ",")))
cat(sprintf("Queued to geocode : %s distinct addresses -> geocode_queue.csv\n",
            format(nrow(queue), big.mark = ",")))

if (all(is.na(hit$GEOID))) {
  warning("No county was assigned by either path. Check that coordinates are ",
          "present and that tigris can reach the TIGER county file.", call. = FALSE)
}
