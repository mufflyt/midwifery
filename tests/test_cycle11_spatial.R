#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 11 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: R/spatial_crs_contract.R and the two point-in-polygon assignments
# that place every midwife in a county and a congressional district.
#
# THE FINDING, stated precisely rather than alarmingly. The CRS contract module
# advertises three layers of protection and opens with "Every spatial binary
# operation must be preceded by assert_crs_equal()". It had **zero call sites**
# anywhere in the repo. That is the third instance in this project of a guard
# whose documentation describes an intended design as an implemented one --
# after compute_match_score() in the sibling repo and safe_left_join()'s
# unusable default (cycle 9).
#
# But the honest severity is narrow, and measuring it mattered:
#
#   mismatched CRS       -> sf ERRORS on its own
#   NA CRS on one side   -> sf ERRORS on its own
#   NA CRS on BOTH sides -> sf is SILENT and returns matches
#
# Only the third case is a real hole, and it is exactly the one the module's
# roxygen says it closes. Both live call sites set CRS literally (4326), so the
# guard cannot fire today. Wiring it in makes the module's own rule true rather
# than aspirational; it does not fix a live defect, and this file says so.
#
# The tests with actual scientific consequence here are the assignment ones:
# a point in the wrong CRS, with swapped coordinates, or outside CONUS lands a
# midwife in the wrong county, and county is the unit of every access finding.
#
# Run: Rscript tests/test_cycle11_spatial.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
# DEPENDENCY GUARD. This file is discovered by ci.yml's cycle-test glob, which
# runs in the pure-function job -- and that job installs no system geo
# libraries by explicit design ("if a package here ever needs one, it does not
# belong here"). Rather than add sf to the cheap tier or drop this file from
# discovery, the requirement is declared and its absence is a LOUD, COUNTED
# skip: the line below is the same `  --   SKIP` the skip budget tallies, so a
# runner that cannot run this file says so and the budget expects it.
if (!requireNamespace("sf", quietly = TRUE)) {
  cat("  --   SKIP cycle 11 spatial checks [absent: package sf]\n")
  cat("\nPASS (0 failures, 1 skipped)\n")
  quit(status = 0)
}

suppressPackageStartupMessages({library(sf); library(dplyr)})
source(file.path(root, "R", "spatial_crs_contract.R"))
source(file.path(root, "R", "lib", "coordinate_plausibility.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
pt <- function(lon, lat, crs = 4326)
  st_sf(id = 1, geometry = st_sfc(st_point(c(lon, lat)), crs = crs))
poly <- function(crs = 4326)
  st_sf(g = "A", geometry = st_sfc(st_polygon(list(rbind(
    c(-105, 39), c(-104, 39), c(-104, 40), c(-105, 40), c(-105, 39)))), crs = crs))
errs <- function(expr) tryCatch({ force(expr); FALSE }, error = function(e) TRUE)

cat("\n-- BVA --\n")

# T101 (BVA). assert_crs_equal() at its four cases.
{
  chk(!errs(assert_crs_equal(pt(-104.9, 39.7), poly(), "t")),
      "T101a identical CRS passes")
  chk(errs(assert_crs_equal(pt(-104.9, 39.7), poly(4269), "t")),
      "T101b 4326 vs 4269 is a mismatch, though both are lat/long degrees")
  chk(errs(assert_crs_equal(pt(-104.9, 39.7, NA), poly(), "t")),
      "T101c an undefined CRS on one side is rejected")
  chk(errs(assert_crs_equal(pt(-104.9, 39.7, NA), poly(NA), "t")),
      "T101d an undefined CRS on BOTH sides is rejected")
}

# T102 (BVA). Degenerate inputs must not pass by accident.
{
  empty <- st_sf(id = integer(0), geometry = st_sfc(crs = 4326))
  chk(!errs(assert_crs_equal(empty, poly(), "t")),
      "T102a a zero-feature layer with a declared CRS still passes")
  chk(errs(assert_crs_equal(st_sf(id = integer(0), geometry = st_sfc()), poly(), "t")),
      "T102b a zero-feature layer with NO CRS is still rejected")
}

# T103 (BVA). CONUS coordinate bounds. Longitude is negative in the US; a
# positive longitude is a sign error, not a location.
{
  chk(identical(classify_coordinate(-104.9, 39.7), "conus"), "T103a Denver classifies as conus")
  chk(identical(classify_coordinate(-149.9, 61.2), "noncontiguous"), "T103b Anchorage is non-contiguous, not implausible")
  # The check that a naive sign test gets WRONG. Positive longitude is correct
  # for Guam and the Northern Marianas, and "longitude must be negative" would
  # delete obstetric capacity from the places least able to spare it.
  chk(identical(classify_coordinate(144.8, 13.5), "territory"), "T103c Guam has a POSITIVE longitude and is a real place")
  chk(identical(classify_coordinate(-170.7, -14.3), "territory"), "T103d American Samoa is south of the equator and is a real place")
  chk(identical(classify_coordinate(39.7, -104.9), "implausible"), "T103e a swapped Denver pair is implausible")
  chk(is.na(classify_coordinate(NA, 39.7)), "T103f a missing coordinate is NA, not implausible")

  # And against the real artifacts: no coordinate in the shipped data is
  # implausible, and the territory rows are RECOGNISED rather than discarded.
  for (a in c("artifacts/midwives_geography_FROZEN.csv",
              "artifacts/ob_hospitals_geocoded.csv")) {
    fp <- file.path(root, a)
    if (!file.exists(fp)) { cat(sprintf("       skip %s (absent)\n", basename(a))); next }
    d <- suppressWarnings(readr::read_csv(fp, show_col_types = FALSE, progress = FALSE))
    if (!all(c("latitude", "longitude") %in% names(d))) next
    cls <- classify_coordinate(d$longitude, d$latitude)
    chk(sum(cls == "implausible", na.rm = TRUE) == 0L,
        sprintf("T103g %s carries no implausible coordinate [%d implausible, %d territory]",
                basename(a), sum(cls == "implausible", na.rm = TRUE),
                sum(cls == "territory", na.rm = TRUE)))
  }
}

cat("\n-- SEMANTIC --\n")

# T104 (semantic). THE RULE, now enforced. Every spatial binary operation in
# R/ must be preceded by assert_crs_equal(), which is what the module says and
# what nothing did.
{
  ops <- character(0)
  for (f in list.files(file.path(root, "R"), pattern = "\\.R$",
                       recursive = TRUE, full.names = TRUE)) {
    if (basename(f) == "spatial_crs_contract.R") next
    src <- readLines(f, warn = FALSE)
    src[grepl("^\\s*#", src)] <- ""
    for (i in grep("st_(intersection|intersects|join|union|difference|within|contains)\\(", src)) {
      window <- src[max(1, i - 12):i]
      if (!any(grepl("assert_crs_equal\\(", window))) {
        ops <- c(ops, sprintf("%s:%d", basename(f), i))
      }
    }
  }
  chk(length(ops) == 0L,
      sprintf("T104 every spatial binary op is preceded by assert_crs_equal [%d unguarded: %s]",
              length(ops), paste(head(ops, 5), collapse = ", ")))
}

# T105 (semantic). The guard must not be redundant with sf. This asserts the
# ONE case sf leaves open, which is the module's entire residual justification.
{
  p <- st_sf(id = 1, geometry = st_sfc(st_point(c(-104.9, 39.7))))
  q <- st_sf(g = "A", geometry = st_sfc(st_polygon(list(rbind(
    c(-105, 39), c(-104, 39), c(-104, 40), c(-105, 40), c(-105, 39))))))
  sf_silent <- !errs(suppressWarnings(st_join(p, q, join = st_within)))
  chk(sf_silent,
      "T105a sf itself SILENTLY joins two layers that both have an undefined CRS")
  chk(errs(assert_crs_equal(p, q, "t")),
      "T105b assert_crs_equal catches exactly that case -- it is not redundant")
}

# T106 (semantic). Point-in-polygon assignment must be TOTAL: a midwife with
# valid coordinates belongs to exactly one county. An unassigned midwife is
# silently dropped from every county-level denominator.
{
  p <- pt(-104.9, 39.7)
  hit <- suppressMessages(st_join(p, poly(), join = st_within))
  chk(nrow(hit) == 1L && !is.na(hit$g),
      "T106a a point inside a polygon is assigned exactly once")
  outside <- suppressMessages(st_join(pt(-90, 30), poly(), join = st_within))
  chk(nrow(outside) == 1L && is.na(outside$g),
      "T106b a point outside every polygon yields one row with NA, not zero rows")
}

# T107 (semantic). s2 is switched OFF for the district assignment. That is
# correct for point-in-polygon, which is topological -- but it would be wrong
# for area or distance, which are metric. Pin the distinction so the setting is
# not carried into a measurement.
{
  src <- paste(readLines(file.path(root, "R", "12-district-profiles.R"), warn = FALSE),
               collapse = "\n")
  uses_s2_off <- grepl("sf_use_s2\\(FALSE\\)", src)
  measures <- grepl("st_area\\(|st_distance\\(|st_buffer\\(", src)
  chk(uses_s2_off && !measures,
      "T107 s2 is disabled only around a topological op, never around a measurement")
}

cat("\n-- ADVERSARIAL --\n")

# T108 (adversarial). Swapped coordinates. st_as_sf(coords = c("longitude",
# "latitude")) is order-sensitive, and (39.7, -104.9) is a valid point in the
# Indian Ocean rather than an error.
{
  swapped <- pt(39.7, -104.9)
  hit <- suppressMessages(st_join(swapped, poly(), join = st_within))
  chk(is.na(hit$g),
      "T108a swapped lon/lat silently lands outside every US polygon rather than erroring")
  in_conus <- function(g) {
    xy <- st_coordinates(g)
    xy[1, "X"] >= -125 && xy[1, "X"] <= -66 && xy[1, "Y"] >= 24 && xy[1, "Y"] <= 50
  }
  chk(!in_conus(swapped) && in_conus(pt(-104.9, 39.7)),
      "T108b a CONUS envelope check distinguishes the swap from a real location")
}

# T109 (adversarial). A degrees-vs-metres mix-up. A projected coordinate
# (metres) read as 4326 degrees is far outside any valid lat/long range, so it
# must be rejected rather than clamped.
{
  bad <- tryCatch(st_sfc(st_point(c(-11700000, 4800000)), crs = 4326),
                  error = function(e) NULL)
  ok <- !is.null(bad)
  coords <- if (ok) st_coordinates(bad) else matrix(NA_real_, 1, 2)
  chk(ok && abs(coords[1, "X"]) > 180,
      "T109 a Web-Mercator metre coordinate labelled 4326 is out of degree range and detectable")
}

# T110 (adversarial). Duplicate points must each get their own assignment row;
# a spatial join must not collapse them and shrink a count.
{
  two <- rbind(pt(-104.9, 39.7), pt(-104.9, 39.7))
  hit <- suppressMessages(st_join(two, poly(), join = st_within))
  chk(nrow(hit) == 2L,
      "T110 two midwives at the same address remain two people after a spatial join")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
