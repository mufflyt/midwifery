#!/usr/bin/env Rscript
# =============================================================================
# Geocode the residual general OB/GYNs that no existing output covers
# =============================================================================
# 49,919 of the 50,556 ABOG generalists already have coordinates from the
# project's own geocoding runs (the dedicated general-OB run plus the 80k cohort
# file). This handles only the 633 that neither covers.
#
# CITY CENTROID IS THE CEILING HERE, NOT A CHOICE. None of the 633 has a street
# address anywhere in the project -- not in canonical_abog_npi_LATEST.csv, not
# in abog_longitudinal_addresses.csv. 618 have city and state. So the best
# available geocode is the city centroid, produced by the project's existing
# geocode_city_centroid_dataset() against data/reference/us_city_centroids.csv.
#
# WHAT A CITY CENTROID IS AND IS NOT FIT FOR:
#   FIT   county and congressional-district assignment, where the error is
#         usually smaller than the polygon -- though a city straddling a
#         district line will be assigned wrongly, and large cities span many.
#   UNFIT any travel-time or isochrone work. A centroid is not a practice
#         location, and a 30-minute polygon drawn from one is fiction.
# Every row is written with coord_source = "city_centroid", and downstream code
# must be able to exclude them. They are NOT merged into any existing geocode
# artifact.
#
# Output: artifacts/generalist_residual_city_centroids.csv
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

ISO <- path.expand("~/isochrones")

roster <- read_csv(file.path(ISO, "canonical_abog_npi_LATEST.csv"),
                   show_col_types = FALSE) %>%
  filter(subspecialty == "Generalist") %>%
  mutate(npi = as.character(npi)) %>% distinct(npi, .keep_all = TRUE)

have <- unique(c(
  read_csv(file.path(ISO, "data/04-geocode/output",
                     "geocoded_general_obgyns_20260227_131734_fixed.csv"),
           show_col_types = FALSE) %>%
    filter(!is.na(lat), !is.na(lon)) %>% pull(npi) %>% as.character(),
  readRDS(file.path(ISO, "data/entire_80k_cohort_geocoded.rds")) %>%
    filter(!is.na(latitude), !is.na(longitude)) %>% pull(npi) %>% as.character()))

todo <- roster %>% filter(!npi %in% have)
cat(sprintf("generalists without any coordinate: %s\n", nrow(todo)))
cat(sprintf("  with city AND state             : %s\n",
            sum(!is.na(todo$city) & !is.na(todo$state))))

# The reference table keys on FULL state names ("Alaska"), while the ABOG roster
# carries abbreviations. Mapping through state.name/state.abb rather than
# assuming either side's format.
abb2name <- setNames(c(state.name, "District of Columbia", "Puerto Rico"),
                     c(state.abb, "DC", "PR"))
cent <- read_csv(file.path(ISO, "data/reference/us_city_centroids.csv"),
                 show_col_types = FALSE) %>%
  mutate(city_key = str_to_lower(str_trim(city)),
         state_key = str_to_lower(str_trim(state))) %>%
  distinct(city_key, state_key, .keep_all = TRUE)

out <- todo %>%
  filter(!is.na(city), !is.na(state)) %>%
  mutate(state_full = abb2name[str_to_upper(str_trim(state))],
         city_key  = str_to_lower(str_trim(city)),
         state_key = str_to_lower(str_trim(state_full))) %>%
  left_join(cent %>% select(city_key, state_key, latitude, longitude),
            by = c("city_key", "state_key"))

matched <- out %>% filter(!is.na(latitude), !is.na(longitude))
cat(sprintf("  matched to a city centroid      : %s (%.1f%% of the residual)\n",
            nrow(matched), 100 * nrow(matched) / nrow(todo)))

unmatched <- out %>% filter(is.na(latitude) | is.na(longitude))
if (nrow(unmatched)) {
  cat(sprintf("  city not in reference table     : %s\n", nrow(unmatched)))
  print(as.data.frame(unmatched %>% count(state, sort = TRUE) %>% head(6)),
        row.names = FALSE)
}

res <- matched %>%
  transmute(npi, city, state, latitude, longitude,
            coord_source = "city_centroid",
            geocode_precision = "city",
            usable_for_travel_time = FALSE)
write_csv(res, "artifacts/generalist_residual_city_centroids.csv", na = "")
cat(sprintf("\nwritten: artifacts/generalist_residual_city_centroids.csv (%s rows)\n",
            nrow(res)))
cat("These are CITY CENTROIDS. Valid for county/district counts, never for\n")
cat("isochrones or travel-time analysis.\n")
