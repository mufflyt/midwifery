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
#   * OB/GYN SUBSPECIALISTS, not general obstetricians. The ABOG cohort is
#     MFM (2,610), REI (1,423), GYN-ONC (1,292), FPMRS (1,172), MIGS (658),
#     CFP (243), PAG (218). A district with zero here has no OB/GYN
#     SUBSPECIALIST; it may well have many general obstetricians. AHRF's county
#     md_nf_obgyn_gen_23 counts general OB/GYNs and is a different quantity
#     entirely -- the two must never be combined or compared as like for like.
#     Getting general obstetricians to district level requires an NPPES
#     taxonomy 207V00000X extract, which is not wired in here.
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
ob <- readRDS(path.expand("~/isochrones/artifacts/isochrones/step_2.5_final_cohort.rds")) %>%
  as_tibble() %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  distinct(npi, .keep_all = TRUE) %>%
  select(id = npi, latitude, longitude)
cat(sprintf("OB/GYN subspecialists with coordinates: %s\n", nrow(ob)))

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
mw <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  select(id = certification_number, latitude, longitude)
cat(sprintf("midwives with coordinates: %s\n", nrow(mw)))

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
ob_cd <- assign_cd(ob, "OB/GYN")
mw_cd <- assign_cd(mw, "midwife")

# --- counts per district -----------------------------------------------------
# Districts with zero providers must survive: a district with no obstetrician is
# the finding, and an inner join would delete it.
counts <- sf::st_drop_geometry(cd) %>%
  left_join(ob_cd %>% count(cd_id, name = "n_obgyn_subspec"),   by = "cd_id") %>%
  left_join(mw_cd %>% count(cd_id, name = "n_midwife"), by = "cd_id") %>%
  mutate(across(c(n_obgyn_subspec, n_midwife), ~ coalesce(., 0L)),
         total_obstetric = n_obgyn_subspec + n_midwife,
         midwife_share = if_else(total_obstetric > 0,
                                 round(n_midwife / total_obstetric, 3), NA_real_),
         midwives_per_obgyn_subspec = if_else(n_obgyn_subspec > 0,
                                      round(n_midwife / n_obgyn_subspec, 2), NA_real_),
         provider_config = case_when(
           n_obgyn_subspec == 0 & n_midwife == 0 ~ "Neither",
           n_obgyn_subspec == 0 & n_midwife > 0  ~ "Midwife only",
           n_obgyn_subspec > 0  & n_midwife == 0 ~ "OB subspecialist only",
           TRUE                          ~ "Both"))

cat(sprintf("\ntotal districts            : %s\n", nrow(counts)))
cat(sprintf("OB/GYNs placed             : %s\n", format(sum(counts$n_obgyn_subspec), big.mark = ",")))
cat(sprintf("midwives placed            : %s\n", format(sum(counts$n_midwife), big.mark = ",")))

cat("\n=========== DISTRICT PROVIDER CONFIGURATION ===========\n")
print(as.data.frame(counts %>% count(provider_config) %>%
  mutate(pct = round(100 * n / sum(n), 1))), row.names = FALSE)

cat("\n=========== DISTRICTS WITH NO OB/GYN SUBSPECIALIST ===========\n")
noob <- counts %>% filter(n_obgyn_subspec == 0)
cat(sprintf("districts with 0 OB subspecialist    : %s (%.1f%%)\n", nrow(noob),
            100 * nrow(noob) / nrow(counts)))
if (nrow(noob))
  print(as.data.frame(noob %>% select(cd_id, cd_name, n_obgyn_subspec, n_midwife) %>%
                        arrange(cd_id)), row.names = FALSE)

cat("\n=========== LOWEST 15 DISTRICTS BY OBSTETRIC WORKFORCE ===========\n")
print(as.data.frame(counts %>% arrange(total_obstetric, cd_id) %>%
  select(cd_id, cd_name, n_obgyn_subspec, n_midwife, total_obstetric) %>% head(15)),
  row.names = FALSE)

cat("\n=========== HIGHEST 10 DISTRICTS ===========\n")
print(as.data.frame(counts %>% arrange(desc(total_obstetric)) %>%
  select(cd_id, cd_name, n_obgyn_subspec, n_midwife, midwife_share) %>% head(10)),
  row.names = FALSE)

cat("\n=========== BY STATE (top 10 by district count) ===========\n")
print(as.data.frame(counts %>% group_by(state) %>%
  summarise(districts = n(), obgyn = sum(n_obgyn_subspec), midwife = sum(n_midwife),
            districts_no_obgyn = sum(n_obgyn_subspec == 0),
            midwives_per_obgyn_subspec = round(sum(n_midwife) / pmax(sum(n_obgyn_subspec), 1), 2),
            .groups = "drop") %>%
  arrange(desc(districts)) %>% head(10)), row.names = FALSE)

write_csv(counts, "artifacts/cd_obstetric_workforce.csv", na = "")
cat("\nwritten: artifacts/cd_obstetric_workforce.csv\n")
cat("NOTE: counts are OB/GYN SUBSPECIALISTS (MFM/REI/GO/FPMRS/MIGS/CFP/PAG),\n     NOT general obstetricians. Zero here does not mean no obstetric care.\n")
