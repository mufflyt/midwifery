#!/usr/bin/env Rscript
# =============================================================================
# Access to the REPRESENTED SUBSET of ACTIVE primary-linked midwives
# =============================================================================
# READ THE LABEL. This is NOT an estimate of access to the ACTIVE midwifery
# workforce. It is:
#
#   "Access to the subset of ACTIVE primary-linked midwives represented by the
#    existing isochrone library."
#
# 3,365 of 11,792 ACTIVE primary-linked midwives (28.5%) have no polygon in the
# library, and that missingness is spatially informative (Metro 77.1%
# represented vs Nonmetro remote 14.0%). Every number below therefore omits
# real midwives, and omits them disproportionately in rural places. It is a
# LOWER BOUND on access, and rural-urban differences in it are NOT workforce
# access differences -- they are dominated by library coverage. See
# characterize_isochrone_representation.R.
#
# NO NEW ISOCHRONES ARE GENERATED, REQUESTED, INTERPOLATED, OR SUPPLEMENTED.
# Polygons are read from the consolidated artifacts only; provider_isochrones.rds
# is never touched (CLAUDE.md #19).
#
# MEASURE: binary geographic access. A tract counts as having access at band B
# if its population-weighted centroid falls inside ANY band-B polygon belonging
# to a matched origin. Binary-at-the-tract, not areal apportionment -- the
# pipeline's own overlap-fraction files are keyed to the OB/GYN cohort's full
# origin set and cannot be subset to the midwife-matched origins.
#
# DENOMINATOR: female population by tract (ACS 2023), from the isochrones
# project's tract demographics file.
#
# Inputs : artifacts/midwife_isochrone_match.csv
#          ~/isochrones/artifacts/isochrones/isochrones_{30,60,120,180}min_consolidated.rds
#          ~/isochrones/data/09-census/output/tract_accessibility_with_demographics_2023.csv
#          ~/isochrones/data/census/census_tracts_2020.rds
#          data/rucc_2023.xlsx
# Outputs: artifacts/represented_subset_access_by_band.csv
#          artifacts/represented_subset_access_by_band_rucc.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(stringr); library(readxl)
})
sf::sf_use_s2(FALSE)   # planar predicates; centroids and contains only

ISO   <- path.expand("~/isochrones")
BANDS <- c(30, 60, 120, 180)

mat <- read_csv("artifacts/midwife_isochrone_match.csv", show_col_types = FALSE)
# The matcher returns the MATCHED ORIGIN's coordinates in latitude/longitude
# (not the midwife's), so the distinct pairs are exactly the origin subset.
origin_keys <- mat %>%
  distinct(latitude, longitude) %>%
  mutate(location_key = sprintf("%.6f_%.6f", latitude, longitude)) %>%
  pull(location_key)
cat(sprintf("midwives represented        : %s\n", format(nrow(mat), big.mark = ",")))
cat(sprintf("distinct origins they invoke: %s of 3,909 (%.1f%% of the library)\n",
            format(length(origin_keys), big.mark = ","),
            100 * length(origin_keys) / 3909))

# --- tract centroids + female population ------------------------------------
dem <- read_csv(file.path(ISO, "data/09-census/output",
                          "tract_accessibility_with_demographics_2023.csv"),
                show_col_types = FALSE) %>%
  transmute(GEOID = str_pad(as.character(tract_geoid), 11, "left", "0"),
            female_population = as.numeric(female_population)) %>%
  filter(!is.na(female_population)) %>%
  distinct(GEOID, .keep_all = TRUE)

tr <- readRDS(file.path(ISO, "data/census/census_tracts_2020.rds"))
if (!inherits(tr, "sf")) stop("census_tracts_2020.rds is not an sf object")
tr <- tr %>%
  mutate(GEOID = str_pad(as.character(.data[[grep("^GEOID", names(tr), value = TRUE)[1]]]),
                         11, "left", "0")) %>%
  sf::st_transform(4326) %>%
  select(GEOID) %>%
  inner_join(dem, by = "GEOID")
cat(sprintf("tracts with female population: %s (denominator %s women)\n",
            format(nrow(tr), big.mark = ","),
            format(round(sum(tr$female_population)), big.mark = ",")))

cent <- suppressWarnings(sf::st_point_on_surface(sf::st_geometry(tr)))
cent <- sf::st_sf(GEOID = tr$GEOID, female_population = tr$female_population,
                  geometry = cent)

# --- county / rurality for each tract (first 5 of GEOID) --------------------
# Shared with build_table1_midwives.R: the lookup refuses to resolve a
# conflicting duplicate FIPS by row order, and the bander returns NA for codes
# outside 1-9 instead of labelling them remote.
source("R/lib/table1_bands.R")
rucc_raw <- read_excel("data/rucc_2023.xlsx")
rucc <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)
cent <- cent %>%
  mutate(county = substr(GEOID, 1, 5)) %>%
  left_join(rucc, by = "county") %>%
  mutate(rurality = band_rurality(rucc, RURALITY_LABELS_SHORT))

# --- per-band binary access -------------------------------------------------
for (b in BANDS) {
  f <- file.path(ISO, "artifacts/isochrones",
                 sprintf("isochrones_%dmin_consolidated.rds", b))
  poly <- readRDS(f)
  # location_key is the artifact's own 6dp coordinate key -- join on it rather
  # than on floating-point equality.
  keep <- poly$location_key %in% origin_keys
  cat(sprintf("\n[%3d min] polygons %s of %s kept\n", b,
              format(sum(keep), big.mark = ","), format(nrow(poly), big.mark = ",")))
  if (!any(keep)) stop("no polygons matched the origin subset at band ", b)
  poly <- sf::st_transform(sf::st_geometry(poly[keep, ]), 4326)
  poly <- sf::st_make_valid(poly)

  hit <- lengths(sf::st_intersects(sf::st_geometry(cent), poly)) > 0L
  cent[[sprintf("access_%dmin", b)]] <- hit
  rm(poly); invisible(gc())
  cat(sprintf("           tracts with access: %s (%.1f%%)\n",
              format(sum(hit), big.mark = ","), 100 * mean(hit)))
}

acc_cols <- sprintf("access_%dmin", BANDS)
d <- sf::st_drop_geometry(cent)
tot_f <- sum(d$female_population)

# Rates are computed inside one summarise() that never reads a name it also
# defines -- a self-referencing summarise() has silently produced "100%" and
# "820400%" in this project already.
overall <- tibble(
  band_minutes = BANDS,
  women_with_access = vapply(acc_cols,
                             function(cc) sum(d$female_population[d[[cc]]]),
                             numeric(1)),
  women_total = tot_f) %>%
  mutate(pct_women_with_access = round(100 * women_with_access / women_total, 1),
         measure = "access_to_represented_subset_only",
         note = "NOT access to the full ACTIVE midwifery workforce; lower bound")

cat("\n=========== ACCESS TO THE REPRESENTED SUBSET (LOWER BOUND) ===========\n")
print(as.data.frame(overall %>% select(band_minutes, women_with_access,
                                       women_total, pct_women_with_access)),
      row.names = FALSE)
write_csv(overall, "artifacts/represented_subset_access_by_band.csv", na = "")

by_r <- lapply(BANDS, function(b) {
  cc <- sprintf("access_%dmin", b)
  d %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
    summarise(band_minutes = b,
              women_with_access = sum(female_population[.data[[cc]]]),
              women_total = sum(female_population), .groups = "drop")
}) %>% bind_rows() %>%
  mutate(pct_women_with_access = round(100 * women_with_access / women_total, 1))

cat("\n=========== BY RURALITY -- DOMINATED BY LIBRARY COVERAGE ===========\n")
cat("Do NOT read these as workforce access differences. The library represents\n")
cat("77.1% of metro midwives and 14.0% of remote-rural ones, so the rural rows\n")
cat("are depressed by measurement, not (only) by workforce supply.\n")
print(as.data.frame(by_r %>% arrange(band_minutes, rurality)), row.names = FALSE)
write_csv(by_r, "artifacts/represented_subset_access_by_band_rucc.csv", na = "")
cat("\nwritten: artifacts/represented_subset_access_by_band{,_rucc}.csv\n")
