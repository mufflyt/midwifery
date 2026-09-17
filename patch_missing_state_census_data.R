#!/usr/bin/env Rscript
# =============================================================================
# Patch WY (missing population) and CT (stale tract geometry) into the
# census inputs access_full_cohort.R reads from ~/isochrones
# =============================================================================
# WHY THIS EXISTS. access_full_cohort.R's by-state breakdown found 4 of 51
# jurisdictions missing: AK, HI, WY had zero rows in the sibling project's
# tract_accessibility_with_demographics_2023.csv, and CT's 884 rows there use
# tract GEOIDs that never match census_tracts_2020.rds's geometry, because
# Connecticut replaced its 8 counties with 9 planning regions in 2022 and the
# Census Bureau re-delineated CT's tracts onto the new boundaries starting
# with the 2022 vintage -- the local geometry file predates that change.
#
# AK and HI are NOT patched here. Nothing in the sibling project's own
# comments explains why they are absent (no batch-failure marker, no
# scope note), and this project's isochrone routing may never have reached
# them at all -- silently fabricating population coverage for two states
# with no origins nearby would misrepresent access there as "unmeasured"
# rather than "genuinely far from any located midwife". WY is different:
# its tract geometry is already present and correct in census_tracts_2020.rds
# (177 tracts, confirmed), so only the population figure was missing, not a
# judgment call about routing coverage.
#
# METHOD. access_full_cohort.R only ever reads two columns from the
# demographics file -- tract_geoid and female_population (ACS variable
# B01001_026E, per ~/isochrones/R/09-get-census-population.R's own variable
# list) -- never the area-weighted overlap columns the sibling project's
# fuller pipeline also computes. Reproducing those needs Step 8's isochrone-
# overlap batches, which belong to a different project's pipeline; this only
# needs the same plain ACS pull access_full_cohort.R was already relying on.
#
# WY:  pull tract-level female population (ACS5 2023, B01001_026E) directly,
#      matching census_tracts_2020.rds's existing (correct, unchanged) WY
#      tract vintage.
# CT:  the existing 884 rows in tract_accessibility_with_demographics_2023.csv
#      are themselves already the current (post-2022) vintage -- tidycensus
#      pulls whatever vintage the requested ACS year actually uses, so CT's
#      population figures needed no re-pull. Only CT's TRACT GEOMETRY needed
#      updating, via tigris::tracts(state = "CT", year = 2023).
#
# Outputs (this repo, not the sibling project -- census_tracts_2020.rds and
# tract_accessibility_with_demographics_2023.csv are left untouched):
#   data/census_patch_wy_female_population.csv
#   data/census_patch_ct_tracts_2023.rds
# =============================================================================

suppressPackageStartupMessages({
  library(tidycensus); library(tigris); library(sf); library(dplyr); library(readr)
})
options(tigris_use_cache = TRUE)

cat("-- WY: pulling tract-level female population, ACS5 2023 --\n")
wy <- get_acs(geography = "tract", variables = c(female_population = "B01001_026E"),
              state = "WY", year = 2023, survey = "acs5", output = "wide") %>%
  transmute(tract_geoid = GEOID, female_population = female_population)
stopifnot(nrow(wy) > 0L, all(substr(wy$tract_geoid, 1, 2) == "56"))
write_csv(wy, "data/census_patch_wy_female_population.csv")
cat(sprintf("   wrote data/census_patch_wy_female_population.csv (%d tracts, %s women)\n",
            nrow(wy), format(sum(wy$female_population, na.rm = TRUE), big.mark = ",")))

cat("\n-- CT: pulling current (2023-vintage, post-2022-planning-region) tract geometry --\n")
ct <- tigris::tracts(state = "CT", year = 2023, cb = FALSE) %>%
  st_transform(4326) %>%
  transmute(GEOID = GEOID)
stopifnot(nrow(ct) > 0L, all(substr(ct$GEOID, 1, 2) == "09"))
saveRDS(ct, "data/census_patch_ct_tracts_2023.rds")
cat(sprintf("   wrote data/census_patch_ct_tracts_2023.rds (%d tracts)\n", nrow(ct)))

cat("\nRun access_full_cohort.R after this -- it reads both patch files if present.\n")
