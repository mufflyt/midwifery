#!/usr/bin/env Rscript
# =============================================================================
# Route queue: EVERY geocoded midwife, not the represented subset
# =============================================================================
# Run as: Rscript build_osmde_route_queue_all_midwives.R
#
# WHAT PROBLEM THIS CLOSES. Travel-time access in this project has been
# "represented-subset only": a midwife had an exposure measurement if and only
# if she happened to sit within 5 km of an origin in a 3,909-point library built
# for the OB/GYN cohort. That gate represented 77.1% of metro midwives and 14.0%
# of remote-rural ones (characterize_isochrone_representation.R), so the
# missingness ran along the exact axis the study measures. Nothing downstream
# could distinguish "no access" from "never measured", and
# represented_subset_access.R has to label its own output a lower bound.
#
# The fix is not a better matcher or a wider reuse radius -- both make the
# reuse-radius assumption load-bearing. The fix is to route every distinct
# midwife location directly, so exposure is measured AT the midwife rather than
# borrowed from a physician-cohort origin up to 5 km away. This script builds
# that work list.
#
# THE REUSE RADIUS DISAPPEARS. The queue is keyed on the midwife's own
# coordinates to 6 decimal places (~11 cm), so every polygon this produces is
# centred on a real practice location. Locations shared by several midwives
# collapse to one request; the crosswalk restores the many-to-one join.
#
# WHY THE ORDER IS RANDOM. This is roughly an eight-hour run against a
# volunteer-operated public server and it WILL be interrupted and resumed. Any
# natural ordering -- input order, state, most-midwives-first -- makes a partial
# run spatially selective, which would recreate the very bias this exists to
# remove. A fixed-seed shuffle makes any prefix of the queue a random sample of
# locations, so a half-finished run is unbiased rather than urban-first.
#
# Implausible coordinates are dropped via the project's own classifier, which
# keeps AK/HI and the Pacific/Caribbean territories -- a naive "longitude must
# be negative" filter would delete Guam and American Samoa.
#
# NOTHING IS ROUTED HERE and nothing is written to artifacts/isochrones/. This
# script only writes a work list.
#
# Inputs : midwives_panel_geocoded_enhanced.csv
# Outputs: artifacts/route_queue_osmde_all_midwives.csv
#          artifacts/osmde_location_crosswalk.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})
source(file.path("R", "lib", "coordinate_plausibility.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

set.seed(20260816)   # fixed: the queue order must be reproducible for the paper

PANEL     <- "midwives_panel_geocoded_enhanced.csv"
QUEUE_OUT <- "artifacts/route_queue_osmde_all_midwives.csv"
XWALK_OUT <- "artifacts/osmde_location_crosswalk.csv"
CACHE_DIR <- "artifacts/isochrones_osmde/_cache"
LEGACY_Q  <- "artifacts/route_queue_osmde.csv"

crd <- suppressWarnings(read_csv(PANEL, show_col_types = FALSE))
cat(sprintf("panel rows                        : %s\n",
            format(nrow(crd), big.mark = ",")))

# --- 1. every midwife with a usable coordinate ------------------------------
# "All midwives" is taken literally: the whole geocoded panel, not the ACTIVE
# primary-linked analytic denominator. The analytic subset is contained in this
# one, so routing the superset cannot leave an analysis short, and status is a
# filter the analysis applies later rather than a reason to leave a location
# permanently unmeasured.
geo <- crd %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  mutate(coordinate_class = classify_coordinate(longitude, latitude))

drop_n <- sum(geo$coordinate_class == "implausible", na.rm = TRUE)
cat(sprintf("  no coordinate                   : %s\n",
            format(nrow(crd) - nrow(geo), big.mark = ",")))
cat(sprintf("  implausible coordinate (dropped): %s\n",
            format(drop_n, big.mark = ",")))
print(as.data.frame(count(geo, coordinate_class)), row.names = FALSE)

geo <- geo %>%
  filter(coordinate_class %in% c("conus", "noncontiguous", "territory")) %>%
  mutate(location_key = sprintf("%.6f_%.6f", latitude, longitude))

cat(sprintf("\nroutable midwives                 : %s\n",
            format(nrow(geo), big.mark = ",")))
cat(sprintf("distinct locations to route       : %s\n",
            format(n_distinct(geo$location_key), big.mark = ",")))

# --- 2. the crosswalk that replaces the 5 km reuse gate ---------------------
# Exact location identity, not proximity. Written before the queue so that a
# polygon can always be traced back to the midwives it belongs to even if the
# routing run is abandoned half way.
xwalk <- geo %>%
  transmute(certification_number, npi, location_key,
            latitude, longitude, coordinate_class,
            practice_state, practice_zip, address_year,
            match_method = "exact_location", match_distance_km = 0)
write_with_provenance(xwalk, XWALK_OUT, inputs = prov_inputs(PANEL), na = "")
cat(sprintf("written: %s (%s rows)\n", XWALK_OUT,
            format(nrow(xwalk), big.mark = ",")))

# --- 3. the deduplicated work list ------------------------------------------
q <- geo %>%
  group_by(location_key) %>%
  summarise(latitude = first(latitude), longitude = first(longitude),
            n_midwives = n(),
            coordinate_class = first(coordinate_class), .groups = "drop") %>%
  # arrange() is explicit insurance, not currently a fix: group_by()+
  # summarise() already returns rows sorted by the grouping key, which is why
  # this shuffle has been reproducible regardless of geo's own row order.
  # That is an INCIDENTAL property of summarise(), not a documented contract
  # -- verified that a plain distinct(location_key, .keep_all = TRUE) does
  # NOT sort and IS order-dependent (adversarial loop cycle 29). Stating the
  # sort explicitly means a future refactor away from summarise() cannot
  # silently reintroduce the dependency this file's own header already
  # promises does not exist.
  arrange(location_key) %>%
  slice_sample(prop = 1)          # fixed-seed shuffle; see header
q$queue_position <- seq_len(nrow(q))

# Locations already retrieved by the first (represented-residual) osm.de batch
# are reported, not removed. The generator skips them from its own cache; a
# queue that pre-filtered them would silently shrink whenever the cache changed,
# and the file would stop being a stable record of the work list.
have <- if (dir.exists(CACHE_DIR)) {
  sub("\\.rds$", "", list.files(CACHE_DIR, pattern = "\\.rds$"))
} else if (file.exists("artifacts/isochrones_osmde/_checkpoint.rds")) {
  names(readRDS("artifacts/isochrones_osmde/_checkpoint.rds"))
} else character(0)

q$already_retrieved <- q$location_key %in% have
write_with_provenance(q, QUEUE_OUT, inputs = prov_inputs(PANEL), na = "")

n_todo <- sum(!q$already_retrieved)
cat(sprintf("written: %s (%s rows)\n", QUEUE_OUT,
            format(nrow(q), big.mark = ",")))
cat(sprintf("  already retrieved on osm.de     : %s\n",
            format(sum(q$already_retrieved), big.mark = ",")))
cat(sprintf("  REMAINING to route              : %s\n",
            format(n_todo, big.mark = ",")))
cat(sprintf("  estimated wall clock at 3.0 s/req: %.1f h\n",
            n_todo * 4.2 / 3600))

if (file.exists(LEGACY_Q)) {
  old <- read_csv(LEGACY_Q, show_col_types = FALSE)
  orphan <- setdiff(old$location_key, q$location_key)
  cat(sprintf("\nlegacy queue (%s) locations not in this one: %s\n",
              LEGACY_Q, length(orphan)))
  if (length(orphan))
    cat("  (retrieved against panel coordinates that have since changed;\n",
        "  their cache entries are kept but no current midwife maps to them)\n",
        sep = "")
}

cat("\nThis file is a work list only. No isochrone has been requested.\n")
