#!/usr/bin/env Rscript
# =============================================================================
# Did direct osm.de routing actually close the represented-subset limitation?
# =============================================================================
# Run as: Rscript verify_osmde_full_cohort_coverage.R
#
# The claim being tested is narrow and falsifiable: every geocoded midwife now
# has a 30- AND a 60-minute polygon centred on her OWN practice coordinates,
# rather than borrowed from an OB/GYN-cohort origin up to 5 km away.
#
# The comparison is deliberately against the SAME denominator
# characterize_isochrone_representation.R used -- ACTIVE, primary_midwifery,
# usable coordinates -- because that is the number the limitation was stated in
# (71.5% overall; 77.0% metro vs 13.9% remote rural). Changing the denominator
# at the same time as the method would make the improvement unreadable.
#
# WHAT WOULD FALSIFY THE CLAIM, and is therefore checked rather than assumed:
#   * a location in the crosswalk with no polygon              -> still unmeasured
#   * a location with a 30 but no 60 (or vice versa)           -> half-measured
#   * a polygon that does not contain its own centre           -> unusable
#   * a 60-minute polygon smaller than its own 30-minute one   -> nesting broken
# Each is counted per rurality stratum, because a failure mode concentrated in
# rural locations reproduces the original bias in a new form and must not be
# reported as a national average.
#
# NOTE ON ENGINE. Coverage here is osm.de-only, which is the point: the mixed
# EC2/osm.de surface confounded engine with rurality (calibrate_osmde_vs_ec2.R).
# This artifact is single-engine. It is NOT interchangeable with the canonical
# EC2 library and must not be merged into it.
#
# Inputs : artifacts/osmde_location_crosswalk.csv
#          artifacts/isochrones_osmde/osmde_isochrones_30_60.rds
#          artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/midwives_geography_FROZEN.csv
#          artifacts/midwife_isochrone_match.csv
#          data/rucc_2023.xlsx
# Outputs: artifacts/osmde_full_cohort_coverage_by_rucc.csv
#          artifacts/osmde_full_cohort_coverage_by_state.csv
#          artifacts/osmde_polygon_quality_by_rucc.csv
#          artifacts/osmde_still_unmeasured.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(stringr); library(readxl)
})
source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "artifact_provenance.R"))
sf::sf_use_s2(FALSE)

XWALK <- "artifacts/osmde_location_crosswalk.csv"
POLY  <- "artifacts/isochrones_osmde/osmde_isochrones_30_60.rds"
LINK  <- "artifacts/amcb_npi_linkage_FROZEN.csv"
GEOF  <- "artifacts/midwives_geography_FROZEN.csv"
MATCH <- "artifacts/midwife_isochrone_match.csv"
RUCCF <- "data/rucc_2023.xlsx"

xw   <- read_csv(XWALK, show_col_types = FALSE)
poly <- readRDS(POLY)
link <- read_csv(LINK, show_col_types = FALSE)
geo  <- read_csv(GEOF, show_col_types = FALSE)
mat  <- read_csv(MATCH, show_col_types = FALSE)

rucc_raw <- read_excel(RUCCF)
rucc <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)

# --- 1. per-location polygon status -----------------------------------------
# Band completeness first. A location with one band is not "covered": every
# 60-minute figure computed from it would be short by exactly one midwife, and
# nothing downstream would notice.
band_status <- poly %>%
  sf::st_drop_geometry() %>%
  group_by(location_key) %>%
  summarise(bands = paste(sort(unique(drive_time_minutes)), collapse = "/"),
            n_bands = n_distinct(drive_time_minutes), .groups = "drop") %>%
  mutate(both_bands = n_bands == 2L)

# Geometry gates, computed once per polygon.
g   <- sf::st_geometry(poly)
val <- suppressWarnings(sf::st_is_valid(g))
g[!val] <- sf::st_make_valid(g[!val])
cat(sprintf("polygons repaired for validity: %s of %s\n",
            format(sum(!val), big.mark = ","), format(length(g), big.mark = ",")))

ctr <- sf::st_as_sf(sf::st_drop_geometry(poly)[, c("location_key", "center_lat",
                                                   "center_lng")],
                    coords = c("center_lng", "center_lat"), crs = 4326,
                    remove = FALSE)
cg <- sf::st_geometry(ctr)

# Each centre is tested against ITS OWN polygon only. An all-pairs
# st_intersects() over 16,718 polygons is 280M comparisons; testing in blocks
# and reading the diagonal keeps it to block-size^2 per block, and sf's bbox
# prefilter discards almost all of those immediately.
contains_ctr <- logical(length(g))
blk <- 500L
for (s in seq(1L, length(g), by = blk)) {
  idx <- s:min(s + blk - 1L, length(g))
  hit <- suppressMessages(sf::st_intersects(cg[idx], g[idx]))
  contains_ctr[idx] <- mapply(function(h, j) j %in% h, hit, seq_along(idx))
}

qual <- sf::st_drop_geometry(poly) %>%
  mutate(area_km2 = as.numeric(sf::st_area(sf::st_transform(g, 5070))) / 1e6,
         centre_inside = contains_ctr) %>%
  select(location_key, drive_time_minutes, area_km2, centre_inside)

nest <- qual %>%
  select(location_key, drive_time_minutes, area_km2) %>%
  tidyr::pivot_wider(names_from = drive_time_minutes, values_from = area_km2,
                     names_prefix = "area_") %>%
  mutate(nesting_ok = !is.na(area_30) & !is.na(area_60) & area_60 >= area_30)

loc <- band_status %>%
  left_join(qual %>% group_by(location_key) %>%
              summarise(centre_inside_all = all(centre_inside), .groups = "drop"),
            by = "location_key") %>%
  left_join(nest %>% select(location_key, nesting_ok), by = "location_key") %>%
  mutate(usable = both_bands & centre_inside_all & nesting_ok)

cat(sprintf("locations with a polygon      : %s\n",
            format(nrow(loc), big.mark = ",")))
cat(sprintf("  both 30 and 60 bands        : %s\n", format(sum(loc$both_bands), big.mark = ",")))
cat(sprintf("  centre inside its own band  : %s\n", format(sum(loc$centre_inside_all), big.mark = ",")))
cat(sprintf("  60 encloses 30 (by area)    : %s\n", format(sum(loc$nesting_ok), big.mark = ",")))
cat(sprintf("  USABLE (all three)          : %s\n", format(sum(loc$usable), big.mark = ",")))

# --- 2. the denominator the limitation was stated in ------------------------
den <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  select(certification_number, nppes_state) %>%
  inner_join(xw %>% select(certification_number, location_key),
             by = "certification_number") %>%
  left_join(geo %>% select(certification_number, county_best),
            by = "certification_number") %>%
  mutate(county = str_pad(as.character(county_best), 5, "left", "0")) %>%
  left_join(rucc, by = "county") %>%
  mutate(rurality = band_rurality(rucc, RURALITY_LABELS_SHORT),
         # Baseline: the 5 km reuse gate against the canonical library.
         canonical_5km = certification_number %in% mat$point_id,
         # New: a usable polygon centred on this midwife's own coordinates.
         osmde_exact   = location_key %in% loc$location_key[loc$usable])

n <- nrow(den)
cat(sprintf("\ndenominator (ACTIVE, primary_midwifery, usable coords): %s\n",
            format(n, big.mark = ",")))
cat(sprintf("canonical library, 5 km reuse gate : %s (%.1f%%)\n",
            format(sum(den$canonical_5km), big.mark = ","),
            100 * mean(den$canonical_5km)))
cat(sprintf("osm.de, exact own-location polygon : %s (%.1f%%)\n",
            format(sum(den$osmde_exact), big.mark = ","),
            100 * mean(den$osmde_exact)))

by_rucc <- den %>%
  group_by(rurality) %>%
  summarise(n_midwives = n(),
            n_canonical_5km = sum(canonical_5km),
            n_osmde_exact = sum(osmde_exact),
            pct_canonical_5km = round(100 * mean(canonical_5km), 1),
            pct_osmde_exact = round(100 * mean(osmde_exact), 1),
            .groups = "drop") %>%
  arrange(rurality)
cat("\n=========== REPRESENTATION BY RURALITY: 5 km REUSE vs DIRECT ROUTING ===========\n")
print(as.data.frame(by_rucc), row.names = FALSE)
write_with_provenance(by_rucc, "artifacts/osmde_full_cohort_coverage_by_rucc.csv",
                      inputs = prov_inputs(XWALK, LINK, GEOF, MATCH, RUCCF), na = "")

by_state <- den %>%
  group_by(nppes_state) %>%
  summarise(n_midwives = n(),
            pct_canonical_5km = round(100 * mean(canonical_5km), 1),
            pct_osmde_exact = round(100 * mean(osmde_exact), 1),
            .groups = "drop") %>%
  arrange(pct_osmde_exact)
cat("\n=========== WORST-COVERED STATES UNDER DIRECT ROUTING (n >= 50) ===========\n")
print(as.data.frame(head(filter(by_state, n_midwives >= 50), 10)), row.names = FALSE)
write_with_provenance(by_state, "artifacts/osmde_full_cohort_coverage_by_state.csv",
                      inputs = prov_inputs(XWALK, LINK, GEOF, MATCH, RUCCF), na = "")

# --- 3. failure modes, per stratum ------------------------------------------
# Reported by rurality on purpose: a national "99.7% usable" hides a stratum
# where routing systematically failed, and that stratum would be the rural one.
#
# The gates are reported as DISJOINT reasons, in the order a location has to
# pass them. Counting "no polygon" as also failing the band, centre and nesting
# checks makes every column equal to the first one and hides which gate is
# actually biting -- the first run of this script printed exactly that.
fail_by_rucc <- den %>%
  left_join(loc, by = "location_key") %>%
  mutate(gate = case_when(
    is.na(both_bands)   ~ "no_polygon_retrieved",
    !both_bands         ~ "missing_a_band",
    !centre_inside_all  ~ "centre_outside_own_polygon",
    !nesting_ok         ~ "60min_does_not_enclose_30min",
    TRUE                ~ "usable")) %>%
  group_by(rurality) %>%
  summarise(n_midwives = n(),
            usable                       = sum(gate == "usable"),
            no_polygon_retrieved         = sum(gate == "no_polygon_retrieved"),
            missing_a_band               = sum(gate == "missing_a_band"),
            centre_outside_own_polygon   = sum(gate == "centre_outside_own_polygon"),
            `60min_does_not_enclose_30min` =
              sum(gate == "60min_does_not_enclose_30min"),
            .groups = "drop") %>%
  arrange(rurality)
cat("\n=========== FAILURE MODES BY RURALITY (counts of midwives) ===========\n")
print(as.data.frame(fail_by_rucc), row.names = FALSE)
write_with_provenance(fail_by_rucc, "artifacts/osmde_polygon_quality_by_rucc.csv",
                      inputs = prov_inputs(XWALK, LINK, GEOF, RUCCF), na = "")

# --- 4. whoever is still unmeasured, named ----------------------------------
# Full panel, not just the ACTIVE denominator: a midwife excluded from today's
# analytic subset can enter tomorrow's, and an unrouted location should not have
# to be rediscovered then.
still <- xw %>%
  filter(!location_key %in% loc$location_key[loc$usable]) %>%
  left_join(loc, by = "location_key") %>%
  transmute(certification_number, location_key, latitude, longitude,
            practice_state, coordinate_class,
            reason = case_when(
              is.na(both_bands)           ~ "no_polygon_retrieved",
              !both_bands                 ~ "missing_a_band",
              !centre_inside_all          ~ "centre_outside_own_polygon",
              !nesting_ok                 ~ "60min_does_not_enclose_30min",
              TRUE                        ~ "unknown"),
            # Same discipline as characterize_isochrone_representation.R: this
            # is unmeasured exposure, never zero access.
            representation_status = "not_measured_by_osmde_direct_routing")
write_with_provenance(still, "artifacts/osmde_still_unmeasured.csv",
                      inputs = prov_inputs(XWALK), na = "")
cat(sprintf("\nfull panel midwives with a usable own-location polygon: %s of %s (%.2f%%)\n",
            format(nrow(xw) - nrow(still), big.mark = ","),
            format(nrow(xw), big.mark = ","),
            100 * (1 - nrow(still) / nrow(xw))))
if (nrow(still)) {
  cat("still unmeasured, by reason:\n")
  print(as.data.frame(count(still, reason, sort = TRUE)), row.names = FALSE)
  cat("  -> artifacts/osmde_still_unmeasured.csv\n")
  cat("  These are midwives with UNMEASURED exposure. Not 'no access'.\n")
}
