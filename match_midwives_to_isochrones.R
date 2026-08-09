#!/usr/bin/env Rscript
# =============================================================================
# Reuse EXISTING isochrones for midwife travel-time access
# =============================================================================
# No isochrones are generated here. An isochrone is a drive-time polygon around
# a POINT and is agnostic to whose practice prompted it, so the existing 3,909
# origins are reusable for any provider near them. The only question is
# geographic: is a midwife within the project's 5 km reuse radius of an existing
# origin? (CLAUDE.md non-negotiable #17: coverage is a 5 km haversine match,
# NEVER an exact coordinate match.)
#
# Origins come from load_canonical_isochrone_origins(), the one function that
# reads the consolidated artifacts; provider_isochrones.rds is the documented
# trap path that once inflated a coverage count 164 -> 445.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr); library(sf)})

ISO <- path.expand("~/isochrones")
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)

mw <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  select(certification_number, nppes_state) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  transmute(point_id = certification_number, lat = latitude, lon = longitude,
            state = nppes_state)
cat(sprintf("active midwives with coordinates: %s\n", format(nrow(mw), big.mark = ",")))

res <- local({
  owd <- setwd(ISO); on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages({
    source(file.path("R", "load_canonical_isochrone_origins.R"))
    source(file.path("R", "match_points_to_isochrones.R"))
  }))
  origins <- load_canonical_isochrone_origins()
  cat(sprintf("canonical isochrone origins: %s\n", nrow(origins)))
  match_points_to_isochrones(points_tbl = mw, iso_centers_tbl = origins,
                             threshold_km = 5.0, point_id_col = "point_id",
                             verbose = FALSE)
})

cat(sprintf("\nrows returned : %s\ncolumns       : %s\n",
            format(nrow(res), big.mark = ","), paste(names(res), collapse = ", ")))
print(utils::head(as.data.frame(res), 3))

write_csv(res, "artifacts/midwife_isochrone_match.csv", na = "")
