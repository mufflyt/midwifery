#!/usr/bin/env Rscript
# =============================================================================
# Obstetric workforce by CONGRESSIONAL DISTRICT (119th Congress)
# =============================================================================
# Counties do not nest inside congressional districts -- a single county can be
# split across several, and a district can span dozens of counties. So a
# county-to-CD crosswalk would have to apportion counts by some assumed
# within-county distribution, and providers are precisely the thing that is NOT
# uniformly distributed within a county (they cluster in the county seat and in
# cities). This assigns each provider to a district by POINT-IN-POLYGON on its
# own practice coordinates instead, which needs no apportionment assumption.
#
# TWO PROVIDER SOURCES, DIFFERENT UNIVERSES -- do not read the ratio naively:
#   * GENERAL OB/GYNs (ABOG "Generalist"), the clinically correct comparator
#     for midwives -- both attend routine births. Only 56.4% of ABOG
#     generalists are geocoded, so counts are a FLOOR, biased downward
#     non-uniformly. MFM is reported separately as the referral tier and is
#     never summed with midwives. See load_obstetric_providers.R.
#   * Midwives = AMCB-certified, ACTIVE, primary-linked study cohort. Also a
#                defined certification universe, not all practising midwives.
# Both are certification-based, which makes them comparable to each other in
# kind, but neither is "every provider in the district".
#
# Districts are 119th Congress (cb_2024_us_cd119_500k). District lines change;
# any figure using this must state the Congress number.
#
# Inputs : data/cd119/cb_2024_us_cd119_500k.shp
#          ~/isochrones/artifacts/isochrones/step_2.5_final_cohort.rds
#          midwives_panel_geocoded_enhanced.csv
#          artifacts/amcb_npi_linkage_FROZEN.csv
# Output : artifacts/cd_obstetric_workforce.csv
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr); library(tidyr)
})
sf::sf_use_s2(FALSE)

# The 2024 CB file carries STATEFP but no STUSPS, so the abbreviation is joined
# from the county spine (GEOID's first two digits are the state FIPS).
st_lu <- read_csv("data/county_base.csv", show_col_types = FALSE) %>%
  mutate(STATEFP = str_sub(str_pad(as.character(GEOID), 5, "left", "0"), 1, 2)) %>%
  distinct(STATEFP, state)

cd <- sf::st_read("data/cd119/cb_2024_us_cd119_500k.shp", quiet = TRUE) %>%
  sf::st_transform(4326) %>%
  left_join(st_lu, by = "STATEFP") %>%
  mutate(state = coalesce(state, STATEFP),   # territories absent from the spine
         cd_id = paste0(state, "-", CD119FP)) %>%
  select(cd_id, state, cd = CD119FP, cd_name = NAMELSAD, geometry)
cat(sprintf("districts loaded: %s\n", nrow(cd)))

# --- providers ---------------------------------------------------------------
source("load_obstetric_providers.R")
ob  <- load_generalists()
mfm <- load_subspecialists("MFM")
mw  <- load_midwives()

assign_cd <- function(df, label) {
  p <- sf::st_as_sf(df, coords = c("longitude", "latitude"), crs = 4326, remove = FALSE)
  j <- suppressMessages(sf::st_join(p, cd, join = sf::st_within))
  # Points falling in NO district are reported, never silently dropped: they are
  # offshore/territory coordinates or geocoding errors, and their count is a
  # data-quality signal worth seeing.
  n_out <- sum(is.na(j$cd_id))
  cat(sprintf("%-9s assigned %s, outside any district %s (%.1f%%)\n",
              label, sum(!is.na(j$cd_id)), n_out, 100 * n_out / nrow(j)))
  sf::st_drop_geometry(j) %>% filter(!is.na(cd_id))
}

# Provenance must survive to the published artifact: a district whose generalist
# count rests largely on city centroids is weaker evidence than one built from
# street-level geocodes, and a reader cannot tell without this column.
centroid_counts <- function(cd_tbl) {
  if (!"coord_source" %in% names(cd_tbl)) return(NULL)
  cd_tbl %>% filter(grepl("centroid", coord_source)) %>%
    count(cd_id, name = "n_general_obgyn_city_centroid")
}
ob_cd  <- assign_cd(ob,  "generalOB")
mfm_cd <- assign_cd(mfm, "MFM")
mw_cd <- assign_cd(mw, "midwife")

# --- counts per district -----------------------------------------------------
# Districts with zero providers must survive: a district with no obstetrician is
# the finding, and an inner join would delete it.
counts <- sf::st_drop_geometry(cd) %>%
  left_join(ob_cd  %>% count(cd_id, name = "n_general_obgyn"), by = "cd_id") %>%
  left_join(mfm_cd %>% count(cd_id, name = "n_mfm"),           by = "cd_id") %>%
  left_join(centroid_counts(ob_cd), by = "cd_id") %>%
  left_join(mw_cd %>% count(cd_id, name = "n_midwife"), by = "cd_id") %>%
  mutate(across(c(n_general_obgyn, n_mfm, n_midwife, n_general_obgyn_city_centroid), ~ coalesce(., 0L)),
         birth_attendants = n_general_obgyn + n_midwife,
         midwife_share = if_else(birth_attendants > 0,
                                 round(n_midwife / birth_attendants, 3), NA_real_),
         midwives_per_general_obgyn = if_else(n_general_obgyn > 0,
                                      round(n_midwife / n_general_obgyn, 2), NA_real_),
         provider_config = case_when(
           n_general_obgyn == 0 & n_midwife == 0 ~ "Neither",
           n_general_obgyn == 0 & n_midwife > 0  ~ "Midwife only",
           n_general_obgyn > 0  & n_midwife == 0 ~ "General OB only",
           TRUE                          ~ "Both"))

cat(sprintf("\ntotal districts            : %s\n", nrow(counts)))
cat(sprintf("OB/GYNs placed             : %s\n", format(sum(counts$n_general_obgyn), big.mark = ",")))
cat(sprintf("midwives placed            : %s\n", format(sum(counts$n_midwife), big.mark = ",")))

cat("\n=========== DISTRICT PROVIDER CONFIGURATION ===========\n")
print(as.data.frame(counts %>% count(provider_config) %>%
  mutate(pct = round(100 * n / sum(n), 1))), row.names = FALSE)

cat("\n=========== DISTRICTS WITH NO GENERAL OB/GYN ===========\n")
noob <- counts %>% filter(n_general_obgyn == 0)
cat(sprintf("districts with 0 general OB/GYN    : %s (%.1f%%)\n", nrow(noob),
            100 * nrow(noob) / nrow(counts)))
if (nrow(noob))
  print(as.data.frame(noob %>% select(cd_id, cd_name, n_general_obgyn, n_midwife) %>%
                        arrange(cd_id)), row.names = FALSE)

cat("\n=========== LOWEST 15 DISTRICTS BY OBSTETRIC WORKFORCE ===========\n")
print(as.data.frame(counts %>% arrange(birth_attendants, cd_id) %>%
  select(cd_id, cd_name, n_general_obgyn, n_midwife, birth_attendants) %>% head(15)),
  row.names = FALSE)

cat("\n=========== HIGHEST 10 DISTRICTS ===========\n")
print(as.data.frame(counts %>% arrange(desc(birth_attendants)) %>%
  select(cd_id, cd_name, n_general_obgyn, n_midwife, midwife_share) %>% head(10)),
  row.names = FALSE)

cat("\n=========== BY STATE (top 10 by district count) ===========\n")
print(as.data.frame(counts %>% group_by(state) %>%
  summarise(districts = n(), obgyn = sum(n_general_obgyn), midwife = sum(n_midwife),
            districts_no_obgyn = sum(n_general_obgyn == 0),
            midwives_per_general_obgyn = round(sum(n_midwife) / pmax(sum(n_general_obgyn), 1), 2),
            .groups = "drop") %>%
  arrange(desc(districts)) %>% head(10)), row.names = FALSE)

write_csv(counts, "artifacts/cd_obstetric_workforce.csv", na = "")
cat("\nwritten: artifacts/cd_obstetric_workforce.csv\n")
cat("NOTE: general OB/GYN counts are a FLOOR -- 56.4% of ABOG generalists are\n     geocoded. MFM is reported separately and never summed with midwives.\n")
