#!/usr/bin/env Rscript
# =============================================================================
# Attach coordinates to matched midwives from the shared geocoding cache
# =============================================================================
#
# Reuses the isochrones geocoding cache (55,843 already-geocoded addresses)
# rather than re-geocoding. Cache keys are the project's canonical address hash:
#
#   lower(street)|lower(city)|STATE|zip
#
# Addresses that miss are written to geocode_queue.csv for the existing
# geocode_with_config() pipeline; nothing here calls a geocoding service.
#
# Inputs : midwives_with_nppes.csv (carries practice_address from the NPI API)
# Outputs: midwives_geocoded.csv, geocode_queue.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})

cache_path <- Sys.getenv("GEOCODING_CACHE_PATH",
                         path.expand("~/isochrones/data/geocoding_cache.duckdb"))
stopifnot(file.exists(cache_path))

midwives <- read_csv("midwives_with_nppes.csv", show_col_types = FALSE)

if (!"practice_address" %in% names(midwives)) {
  stop("midwives_with_nppes.csv has no practice_address column -- it predates ",
       "the NPI API matcher. Re-run match_nppes.R first.", call. = FALSE)
}

located <- midwives %>%
  filter(!is.na(npi)) %>%
  mutate(address_hash = sprintf("%s|%s|%s|%s",
                                tolower(coalesce(practice_address, "NA")),
                                tolower(coalesce(practice_city, "NA")),
                                coalesce(practice_state, "NA"),
                                coalesce(practice_zip, "NA")))

con <- dbConnect(duckdb::duckdb(), cache_path, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cache <- dbGetQuery(con, "
  SELECT address_hash, latitude, longitude, quality_score, census_tract, county_fips
  FROM geocoding_cache
  WHERE latitude IS NOT NULL") %>%
  distinct(address_hash, .keep_all = TRUE)

# The cache stores 9-digit zips; ours are 5-digit, so try the exact key first
# and fall back to street+city+state. Both sides must drop the zip field the
# SAME way -- a "[0-9]*$" pattern leaves a non-numeric zip ("NA") in place on
# the cache side only, and then the fallback join silently never matches.
drop_zip <- function(x) sub("\\|[^|]*$", "", x)
cache$key5 <- drop_zip(cache$address_hash)
located$key5 <- drop_zip(located$address_hash)

hit <- located %>%
  left_join(select(cache, address_hash, latitude, longitude, quality_score,
                   census_tract, county_fips), by = "address_hash") %>%
  left_join(distinct(cache, key5, .keep_all = TRUE) %>%
              select(key5, lat5 = latitude, lon5 = longitude, q5 = quality_score,
                     tract5 = census_tract, county5 = county_fips), by = "key5") %>%
  mutate(latitude      = coalesce(latitude, lat5),
         longitude     = coalesce(longitude, lon5),
         quality_score = coalesce(quality_score, q5),
         census_tract  = coalesce(census_tract, tract5),
         county_fips   = coalesce(county_fips, county5)) %>%
  select(-lat5, -lon5, -q5, -tract5, -county5, -key5)

out <- midwives %>%
  left_join(select(hit, certification_number, latitude, longitude,
                   quality_score, census_tract, county_fips),
            by = "certification_number")

write_csv(out, "midwives_geocoded.csv", na = "")

queue <- hit %>%
  filter(is.na(latitude), !is.na(practice_city)) %>%
  distinct(practice_address, practice_city, practice_state, practice_zip)
write_csv(queue, "geocode_queue.csv", na = "")

cat(sprintf("Matched to NPPES : %s\n", format(nrow(hit), big.mark = ",")))
cat(sprintf("Cache hits       : %s (%.1f%%)\n",
            format(sum(!is.na(hit$latitude)), big.mark = ","),
            100 * mean(!is.na(hit$latitude))))
cat(sprintf("Queued to geocode: %s distinct addresses -> geocode_queue.csv\n",
            format(nrow(queue), big.mark = ",")))
