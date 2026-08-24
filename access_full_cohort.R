#!/usr/bin/env Rscript
# =============================================================================
# Population access to the FULL located midwife cohort
# =============================================================================
# Run as: Rscript access_full_cohort.R
#
# WHY THIS EXISTS SEPARATELY FROM represented_subset_access.R
# -----------------------------------------------------------
# That script answers a narrower question and says so in its filename: access to
# the subset of midwives the CANONICAL isochrone library happened to represent.
# It reads isochrones_{30,60}min_consolidated.rds and keeps the polygons whose
# location_key matches a midwife. It cannot see the osm.de-routed origins at
# all, so no amount of re-running it produces a full-cohort number.
#
# Its results were also rural-selective in the direction that flatters the
# conclusion: 77.1% of metropolitan midwives were represented against 14.0% of
# remote-rural ones, so rural access looked better than it is because rural
# midwives were disproportionately the ones missing a polygon.
#
# The full-cohort routing closed that gap -- every midwife in the ACTIVE
# primary-linked denominator now has an exact 30- and 60-minute isochrone. This
# script measures access against the DISSOLVED UNION of all of them.
#
# METHOD, deliberately identical to represented_subset_access.R so the two are
# comparable line for line: binary geographic access at the tract's
# point-on-surface, female population (ACS 2023) as the denominator, tracts
# stratified by the RUCC of their county, and the canonical banders from
# R/lib/table1_bands.R rather than an inline case_when.
#
# The union surfaces already have water removed, so a tract centroid in a lake
# cannot be counted as covered.
#
# Inputs : artifacts/maps/midwifery_isochrone_union_{30,60}min.rds
#          ~/isochrones/data/09-census/output/tract_accessibility_with_demographics_2023.csv
#          ~/isochrones/data/census/census_tracts_2020.rds
#          data/rucc_2023.xlsx
# Outputs: artifacts/full_cohort_access_by_band.csv
#          artifacts/full_cohort_access_by_band_rucc.csv
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr)
  library(tibble); library(readxl)
})
sf::sf_use_s2(FALSE)

# HARDCODED, matching represented_subset_access.R line 45, and not honouring
# ISOCHRONES_HOME. That variable is set in ~/.Renviron to ~/isochrones-main,
# a second checkout that does NOT carry data/09-census -- so respecting it
# fails on a missing tract file rather than falling back. ~/isochrones is the
# canonical checkout for this project's census inputs.
ISO   <- path.expand("~/isochrones")
BANDS <- c(30L, 60L)

source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

# --- the dissolved surfaces --------------------------------------------------
# ASSERTED, not assumed. A surface built before the full-cohort routing holds
# roughly half the origins and would understate access while looking complete;
# that is exactly the defect this script exists to correct, and it must not be
# reintroduced by reading a stale file.
surf <- list()
for (b in BANDS) {
  f <- sprintf("artifacts/maps/midwifery_isochrone_union_%dmin.rds", b)
  if (!file.exists(f)) stop("Missing ", f, ". Run build_midwifery_isochrone_map.R first.", call. = FALSE)
  s <- readRDS(f)
  if (nrow(s) != 1L) stop(f, " is not dissolved: ", nrow(s), " features.", call. = FALSE)
  cat(sprintf("[%2d min] %s origins dissolved, %s km2, engines: %s\n",
              b, format(s$n_origins_dissolved, big.mark = ","),
              format(round(s$area_km2), big.mark = ","), s$routing_engines))
  surf[[as.character(b)]] <- sf::st_make_valid(sf::st_transform(sf::st_geometry(s), 4326))
}

# --- tract centroids + female population ------------------------------------
dem <- read_csv(file.path(ISO, "data/09-census/output",
                          "tract_accessibility_with_demographics_2023.csv"),
                show_col_types = FALSE) %>%
  transmute(GEOID = str_pad(as.character(tract_geoid), 11, "left", "0"),
            female_population = as.numeric(female_population)) %>%
  filter(!is.na(female_population)) %>%
  distinct(GEOID, .keep_all = TRUE)

tr <- readRDS(file.path(ISO, "data/census/census_tracts_2020.rds"))
if (!inherits(tr, "sf")) stop("census_tracts_2020.rds is not an sf object", call. = FALSE)
tr <- tr %>%
  mutate(GEOID = str_pad(as.character(.data[[grep("^GEOID", names(tr), value = TRUE)[1]]]),
                         11, "left", "0")) %>%
  sf::st_transform(4326) %>%
  select(GEOID) %>%
  inner_join(dem, by = "GEOID")
cat(sprintf("tracts with female population: %s (denominator %s women)\n",
            format(nrow(tr), big.mark = ","),
            format(sum(tr$female_population), big.mark = ",")))

cent <- suppressWarnings(sf::st_point_on_surface(sf::st_geometry(tr)))
cent <- sf::st_sf(GEOID = tr$GEOID, female_population = tr$female_population,
                  geometry = cent)

rucc_raw <- read_excel("data/rucc_2023.xlsx")
rucc <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)
cent <- cent %>%
  mutate(county = substr(GEOID, 1, 5)) %>%
  left_join(rucc, by = "county") %>%
  mutate(rurality = band_rurality(rucc, RURALITY_LABELS_SHORT))

# --- per-band binary access --------------------------------------------------
for (b in BANDS) {
  hit <- lengths(sf::st_intersects(sf::st_geometry(cent), surf[[as.character(b)]])) > 0L
  cent[[sprintf("access_%dmin", b)]] <- hit
  cat(sprintf("[%2d min] tracts with access: %s (%.1f%%)\n",
              b, format(sum(hit), big.mark = ","), 100 * mean(hit)))
}

d <- sf::st_drop_geometry(cent)
acc_cols <- sprintf("access_%dmin", BANDS)
tot_f <- sum(d$female_population)

# One summarise() that never reads a name it also defines -- a self-referencing
# summarise() has produced "100%" and "820400%" in this project before.
overall <- tibble(
  band_minutes      = BANDS,
  women_with_access = vapply(acc_cols, function(cc) sum(d$female_population[d[[cc]]]), numeric(1)),
  women_total       = tot_f) %>%
  mutate(pct_women_with_access = round(100 * women_with_access / women_total, 1))

by_rucc <- lapply(seq_along(BANDS), function(i) {
  cc <- acc_cols[i]
  d %>% filter(!is.na(rurality)) %>%
    group_by(rurality) %>%
    summarise(women_with_access = sum(female_population[.data[[cc]]]),
              women_total = sum(female_population), .groups = "drop") %>%
    mutate(band_minutes = BANDS[i],
           pct_women_with_access = round(100 * women_with_access / women_total, 1))
}) %>% bind_rows() %>%
  select(rurality, band_minutes, women_with_access, women_total, pct_women_with_access) %>%
  arrange(band_minutes, rurality)

cat("\n== overall ==\n");  print(as.data.frame(overall), row.names = FALSE)
cat("\n== by rurality ==\n"); print(as.data.frame(by_rucc), row.names = FALSE)

prov <- prov_inputs("data/rucc_2023.xlsx",
                    "artifacts/maps/midwifery_isochrone_union_30min.rds",
                    "artifacts/maps/midwifery_isochrone_union_60min.rds")
write_with_provenance(overall, "artifacts/full_cohort_access_by_band.csv", inputs = prov)
write_with_provenance(by_rucc, "artifacts/full_cohort_access_by_band_rucc.csv", inputs = prov)
cat("\nwritten: artifacts/full_cohort_access_by_band{,_rucc}.csv\n")
