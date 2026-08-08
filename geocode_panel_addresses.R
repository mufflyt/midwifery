#!/usr/bin/env Rscript
# =============================================================================
# Geocode the address the linkage actually used
# =============================================================================
#
# Stage 3's ZIP-fallback validation compares a coordinate-derived county against
# a ZIP-derived one. That comparison is only meaningful if both describe the
# SAME address. It did not: midwives_geocoded.csv holds coordinates geocoded
# from the previous roster's address, keyed on certification_number, while the
# guarded linkage supplies the panel's last-observed ZIP. Pairing them compares
# two different practice locations for one person and scores the disagreement
# as error -- among discordant rows the two rosters' ZIPs differ 71.8% of the
# time, against 5.0% among validation rows overall, which is the whole story.
#
# So geocode the linkage's own address (nppes_practice_address / city / state /
# zip, carried from the panel snapshot named in nppes_location_year) against
# the shared isochrones cache. Nothing is sent to a geocoding service here;
# misses are queued.
#
# Output: midwives_panel_geocoded.csv, artifacts/panel_geocode_queue.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb); library(stringr)
})

FROZEN <- Sys.getenv("STAGE2_FROZEN", "artifacts/amcb_npi_linkage_FROZEN.csv")
cache_path <- Sys.getenv("GEOCODING_CACHE_PATH",
                         path.expand("~/isochrones/data/geocoding_cache.duckdb"))
stopifnot(file.exists(FROZEN), file.exists(cache_path))

roster <- read_csv(FROZEN, show_col_types = FALSE) %>%
  filter(!is.na(npi)) %>%
  mutate(across(c(nppes_practice_address, nppes_city, nppes_state, nppes_zip),
                ~ toupper(trimws(coalesce(.x, "")))))

# Same canonical key the isochrones cache is built on:
#   lower(street)|lower(city)|STATE|zip
key_of <- function(street, city, state, zip) {
  sprintf("%s|%s|%s|%s",
          tolower(ifelse(nzchar(street), street, "NA")),
          tolower(ifelse(nzchar(city), city, "NA")),
          ifelse(nzchar(state), state, "NA"),
          ifelse(nzchar(zip), zip, "NA"))
}
roster <- roster %>%
  mutate(address_hash = key_of(nppes_practice_address, nppes_city,
                               nppes_state, nppes_zip))

# Freshly geocoded coordinates must come from the run RESULTS as well as the
# cache: the cascade writes new cache rows keyed on
# MD5(normalized_address + geocoder_version), so a pipe-format lookup finds the
# seeded rows but silently misses everything geocoded since.
run_results <- c("artifacts/panel_geocode_results.csv",
                 "artifacts/geocode_rerun_results.csv")
fresh <- lapply(run_results[file.exists(run_results)], function(p)
  read_csv(p, show_col_types = FALSE) %>%
    transmute(nppes_practice_address = geocode_address_1, nppes_city = geocode_city,
              nppes_state = geocode_state, nppes_zip = geocode_zip,
              f_lat = lat, f_lon = lon, f_prov = geocode_source)) %>%
  bind_rows() %>%
  filter(!is.na(f_lat)) %>%
  distinct(nppes_practice_address, nppes_city, nppes_state, nppes_zip, .keep_all = TRUE)
cat(sprintf("fresh geocodes available: %s\n", format(nrow(fresh), big.mark = ",")))

con <- dbConnect(duckdb::duckdb(), cache_path, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
cache <- dbGetQuery(con, "
  SELECT address_hash, latitude, longitude, quality_score, census_tract, county_fips
  FROM geocoding_cache WHERE latitude IS NOT NULL") %>%
  distinct(address_hash, .keep_all = TRUE)

# Exact key first; then street+city+state ignoring zip, stripped identically on
# both sides so a 9-digit cached zip cannot silently defeat the fallback.
drop_zip <- function(x) sub("\\|[^|]*$", "", x)
cache$key_nozip <- drop_zip(cache$address_hash)
roster$key_nozip <- drop_zip(roster$address_hash)
nozip <- cache %>% distinct(key_nozip, .keep_all = TRUE) %>%
  select(key_nozip, lat2 = latitude, lon2 = longitude, q2 = quality_score,
         tract2 = census_tract, county2 = county_fips)

hit <- roster %>%
  left_join(fresh, by = c("nppes_practice_address", "nppes_city",
                          "nppes_state", "nppes_zip")) %>%
  left_join(select(cache, address_hash, latitude, longitude, quality_score,
                   census_tract, county_fips), by = "address_hash") %>%
  left_join(nozip, by = "key_nozip") %>%
  mutate(geocode_match = case_when(!is.na(latitude) ~ "exact_key",
                                   !is.na(f_lat)    ~ "run_results",
                                   !is.na(lat2)     ~ "no_zip_fallback",
                                   TRUE             ~ NA_character_),
         latitude = coalesce(latitude, f_lat, lat2),
         longitude = coalesce(longitude, f_lon, lon2),
         quality_score = coalesce(quality_score, q2),
         census_tract = coalesce(census_tract, tract2),
         county_fips = coalesce(county_fips, county2)) %>%
  select(-lat2, -lon2, -q2, -tract2, -county2)

# The cache's county_fips column is empty, so county comes from
# point-in-polygon against TIGER 2023 boundaries -- the same derivation
# geocode_midwives.R uses, and the same vintage as data/county_base.csv.
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
  hit$county_fips <- assign_county_from_points(hit)
}
hit <- hit %>% mutate(county_fips = if_else(is.na(county_fips), NA_character_,
                                            str_pad(as.character(county_fips), 5, "left", "0")))

out <- hit %>%
  transmute(certification_number, npi, match_status, match_resolution,
            practice_address = nppes_practice_address, practice_city = nppes_city,
            practice_state = nppes_state, practice_zip = nppes_zip,
            address_year = nppes_location_year,
            latitude, longitude, quality_score, geocode_match,
            GEOID = county_fips, census_tract)
write_csv(out, "midwives_panel_geocoded.csv", na = "")

queue <- hit %>% filter(is.na(latitude), nzchar(nppes_city)) %>%
  distinct(nppes_practice_address, nppes_city, nppes_state, nppes_zip)
write_csv(queue, "artifacts/panel_geocode_queue.csv", na = "")

n <- nrow(out); h <- sum(!is.na(out$latitude))
cat(sprintf("linked rows              : %s\n", format(n, big.mark = ",")))
cat(sprintf("cache hits               : %s (%.1f%%)\n", format(h, big.mark = ","), 100*h/n))
print(count(out, geocode_match))
cat(sprintf("with county FIPS         : %s (%.1f%%)\n",
            format(sum(!is.na(out$GEOID)), big.mark = ","), 100*mean(!is.na(out$GEOID))))
cat(sprintf("queued for geocoding     : %s distinct addresses\n",
            format(nrow(queue), big.mark = ",")))
