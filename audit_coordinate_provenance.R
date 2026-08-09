#!/usr/bin/env Rscript
# =============================================================================
# Why does county_exact cover only 4,948 of 16,892 accepted links?
# =============================================================================
# Claimed explanation was "~10,000 addresses not yet geocoded", but only 1,624
# addresses are new relative to the previously geocoded population, so at most
# 6,572 could be reached that way. Something else is suppressing coordinates.
# This audits every accepted link before any new API call is made.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(DBI); library(duckdb)
})

fro <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types=FALSE) %>%
  mutate(npi = as.character(npi)) %>% filter(!is.na(npi))
geo <- read_csv("midwives_geography_guarded.csv", show_col_types=FALSE)
pg  <- read_csv("midwives_panel_geocoded.csv", show_col_types=FALSE)

key_of <- function(street, city, state, zip)
  sprintf("%s|%s|%s|%s", tolower(coalesce(street,"NA")), tolower(coalesce(city,"NA")),
          coalesce(state,"NA"), coalesce(zip,"NA"))

cache_path <- Sys.getenv("GEOCODING_CACHE_PATH",
                         path.expand("~/isochrones/data/geocoding_cache.duckdb"))
con <- dbConnect(duckdb::duckdb(), cache_path, read_only=TRUE)
on.exit(dbDisconnect(con, shutdown=TRUE), add=TRUE)
cache <- dbGetQuery(con, "SELECT address_hash, latitude, longitude, geocoder_provenance
                          FROM geocoding_cache WHERE latitude IS NOT NULL") %>%
  distinct(address_hash, .keep_all=TRUE)

# Coordinates the previous runs produced, keyed on address FIELDS (the cache's
# own hash changed format between eras, so field-joins are the stable key).
prior <- lapply(c("artifacts/panel_geocode_results.csv",
                  "artifacts/geocode_rerun_results.csv"), function(p)
  if (file.exists(p)) read_csv(p, show_col_types=FALSE) %>%
    transmute(a=geocode_address_1, c=geocode_city, s=geocode_state, z=geocode_zip,
              prior_lat=lat) else NULL) %>% bind_rows() %>%
  filter(!is.na(prior_lat)) %>% distinct(a, c, s, z, .keep_all=TRUE)

aud <- fro %>%
  transmute(certification_number, npi, linkage_tier,
            addr = nppes_practice_address, city = nppes_city,
            state = nppes_state, zip = nppes_zip) %>%
  mutate(address_hash = key_of(addr, city, state, zip),
         has_address = !is.na(addr) & nzchar(addr)) %>%
  left_join(cache %>% transmute(address_hash, cache_lat = latitude,
                                cache_prov = geocoder_provenance), by="address_hash") %>%
  left_join(prior, by=c("addr"="a","city"="c","state"="s","zip"="z")) %>%
  left_join(pg %>% transmute(certification_number, stage3_lat = latitude), by="certification_number") %>%
  left_join(geo %>% transmute(certification_number, county_exact, geo_source), by="certification_number") %>%
  mutate(reason = case_when(
    !is.na(county_exact)                              ~ "1 coords available, county assigned",
    (!is.na(cache_lat) | !is.na(prior_lat)) & is.na(stage3_lat)
                                                      ~ "2 coords in cache/prior but ABSENT from Stage 3 input",
    !is.na(stage3_lat) & is.na(county_exact)          ~ "3 coords in Stage 3 input, no county (PIP fail/quarantine)",
    !has_address                                      ~ "6 missing or invalid address",
    is.na(cache_lat) & is.na(prior_lat)               ~ "4 address hash never geocoded",
    TRUE                                              ~ "7 other"))

cat(sprintf("accepted links audited: %s\n\n", format(nrow(aud), big.mark=",")))
tab <- aud %>% count(reason) %>% arrange(reason)
print(as.data.frame(tab))
cat(sprintf("\nsum: %s (must equal %s)\n", format(sum(tab$n),big.mark=","),
            format(nrow(aud), big.mark=",")))
stopifnot(sum(tab$n) == nrow(aud))

cat("\nof rows whose coords exist but never reached Stage 3, where were they found?\n")
print(as.data.frame(aud %>% filter(grepl("^2 ", reason)) %>%
  summarise(in_cache=sum(!is.na(cache_lat)), in_prior_results=sum(!is.na(prior_lat)),
            both=sum(!is.na(cache_lat) & !is.na(prior_lat)))))

write_csv(aud, "artifacts/coordinate_provenance_audit.csv", na="")
cat("\nwritten: artifacts/coordinate_provenance_audit.csv\n")
