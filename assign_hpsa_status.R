#!/usr/bin/env Rscript
# =============================================================================
# HPSA (Health Professional Shortage Area) status for each midwife
# =============================================================================
# Point-in-polygon of each midwife's geocoded practice location against the
# HRSA primary-care HPSA layer.
#
# TWO DISTINCTIONS THAT DECIDE THE NUMBER, both preserved rather than collapsed:
#
# 1. STATUS. The layer holds 22,033 features, of which only 9,819 are
#    "Designated". The other 12,214 are "Proposed For Withdrawal" -- HRSA has
#    begun removing the designation. Counting every polygon would overstate
#    shortage-area exposure by more than half. Only Designated counts here;
#    proposed-for-withdrawal is reported separately so the choice is visible.
#
# 2. TYPE. 16,496 features are "HPSA Population": the designation applies to a
#    POPULATION GROUP within the area (low-income, migrant farmworker,
#    homeless), not to everyone practising there. A midwife whose office falls
#    inside one is not thereby serving the designated group. Only "Geographic
#    HPSA" and "High Needs Geographic HPSA" describe the location itself, so
#    those are the ones that support a statement about where a midwife works.
#    Population-group overlap is reported as its own, weaker line.
#
# DISCIPLINE. Every feature is Primary Care. There is no obstetric or midwifery
# HPSA, so this measures primary-care shortage where midwives practise -- a
# proxy for underservice, not a measure of maternity-care shortage. That
# distinction belongs in any sentence built from this.
#
# Inputs : artifacts/midwives_geography_FROZEN.csv  (certification_number, lat, lon)
#          /Volumes/MufflySamsung/HRSA_HPSA_data/HPSA_CMPPC_SHP_DET_CUR_VX.shp
# Output : artifacts/hpsa_status.csv                (person-level, gitignored)
#          artifacts/hpsa_status_summary.csv        (aggregate, tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr)
})
source("R/join_safety.R")   # assert_unique_keys(): conflict-safe dedup

source(file.path("R", "lib", "medicare_duckdb.R"))
HPSA <- Sys.getenv("HPSA_SHP", "")
if (!nzchar(HPSA))
  HPSA <- samsung_volume_path(file.path("HRSA_HPSA_data",
                                        "HPSA_CMPPC_SHP_DET_CUR_VX.shp"))
if (!file.exists(HPSA)) {
  stop(sprintf(paste0("HPSA layer not found at %s. It lives on an external ",
                      "volume; mount it or set HPSA_SHP. Refusing to emit a ",
                      "shortage-area attribute with no shortage-area data."),
               HPSA), call. = FALSE)
}

geo <- read_csv("artifacts/midwives_geography_FROZEN.csv",
                show_col_types = FALSE, progress = FALSE)
lat <- intersect(c("latitude", "lat"), names(geo))[1]
lon <- intersect(c("longitude", "lon"), names(geo))[1]
if (is.na(lat) || is.na(lon))
  stop("geography artifact carries no coordinate columns", call. = FALSE)

# assert_unique_keys(), not distinct(.keep_all=TRUE): a midwife with TWO
# geocoded practice locations (a real, plausible shape for this file -- other
# geography artifacts in this repo carry more than one address per person)
# would have one location silently picked by row order, deciding by accident
# which of two real addresses gets tested against the HPSA layer. A genuine
# lat/lon conflict is a question for a human (which location is current?),
# not a row-order tie-break.
pts <- geo %>%
  filter(!is.na(.data[[lat]]), !is.na(.data[[lon]])) %>%
  assert_unique_keys("certification_number",
                     label = "geocoded midwife locations (HPSA input)", dedupe = TRUE)
cat(sprintf("midwives with coordinates: %s of %s\n",
            format(nrow(pts), big.mark = ","), format(nrow(geo), big.mark = ",")))

h <- st_read(HPSA, quiet = TRUE)
h <- st_make_valid(h)

# Designated only, split by whether the designation describes the PLACE or a
# population group within it.
geo_types <- c("Geographic HPSA", "High Needs Geographic HPSA")
h_des <- h %>% filter(HpsStatDes == "Designated")
h_place <- h_des %>% filter(HpsTypDes %in% geo_types)
h_pop   <- h_des %>% filter(!HpsTypDes %in% geo_types)
h_wdrw  <- h %>% filter(HpsStatDes != "Designated")
cat(sprintf("HPSA polygons: %s designated (%s geographic, %s population), %s proposed for withdrawal\n",
            format(nrow(h_des), big.mark = ","), format(nrow(h_place), big.mark = ","),
            format(nrow(h_pop), big.mark = ","), format(nrow(h_wdrw), big.mark = ",")))

sfp <- st_as_sf(pts, coords = c(lon, lat), crs = 4326, remove = FALSE)
old_s2 <- sf_use_s2(); suppressMessages(sf_use_s2(FALSE))
on.exit(suppressMessages(sf_use_s2(old_s2)), add = TRUE)

hits <- function(layer, label) {
  if (!nrow(layer)) return(character(0))
  ix <- st_intersects(sfp, st_transform(layer, 4326))
  sfp$certification_number[lengths(ix) > 0]
}
in_place <- hits(h_place)
in_pop   <- hits(h_pop)
in_wdrw  <- hits(h_wdrw)

# Worst (highest) shortage score among the geographic polygons a point falls in.
score <- rep(NA_real_, nrow(sfp))
if (nrow(h_place)) {
  ix <- st_intersects(sfp, st_transform(h_place, 4326))
  score <- vapply(ix, function(i) if (length(i)) max(h_place$HpsScore[i], na.rm = TRUE) else NA_real_,
                  numeric(1))
}

out <- tibble(
  certification_number = sfp$certification_number,
  hpsa_geographic      = sfp$certification_number %in% in_place,
  hpsa_population_only = !(sfp$certification_number %in% in_place) &
                           sfp$certification_number %in% in_pop,
  hpsa_withdrawal_only = !(sfp$certification_number %in% c(in_place, in_pop)) &
                           sfp$certification_number %in% in_wdrw,
  hpsa_score           = score)
write_csv(out, "artifacts/hpsa_status.csv", na = "")
cat("written: artifacts/hpsa_status.csv\n")

summ <- tibble(
  built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  with_coords = nrow(out),
  geographic = sum(out$hpsa_geographic),
  population_only = sum(out$hpsa_population_only),
  withdrawal_only = sum(out$hpsa_withdrawal_only),
  none = sum(!out$hpsa_geographic & !out$hpsa_population_only & !out$hpsa_withdrawal_only),
  median_score = suppressWarnings(median(out$hpsa_score, na.rm = TRUE)))
write_csv(summ, "artifacts/hpsa_status_summary.csv")

f <- function(x, lab) cat(sprintf("  %-52s %6s (%4.1f%%)\n", lab,
                                  format(x, big.mark = ","), 100 * x / nrow(out)))
f(summ$geographic,      "In a DESIGNATED geographic primary-care HPSA")
f(summ$population_only, "Only in a population-group HPSA (weaker claim)")
f(summ$withdrawal_only, "Only in one proposed for withdrawal")
f(summ$none,            "In no HPSA polygon")
cat(sprintf("  median shortage score where geographic: %s (3-25, higher = worse)\n",
            summ$median_score))
