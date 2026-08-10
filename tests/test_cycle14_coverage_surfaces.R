#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 14 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: the dissolved coverage surfaces -- the central geographic claim of
# the study and untouched by cycles 1-13. Both defects here produce a
# PLAUSIBLE map from a broken input, which is the worst thing a figure can do.
#
# Run: Rscript tests/test_cycle14_coverage_surfaces.R
# =============================================================================

suppressPackageStartupMessages(library(sf))
source("R/lib/coverage_surface_contracts.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Two nested squares in an equal-area projection: areas are exact, so the
# assertions below are arithmetic rather than approximate.
sq <- function(x0, y0, w) {
  st_sfc(st_polygon(list(cbind(c(x0, x0 + w, x0 + w, x0, x0),
                               c(y0, y0, y0 + w, y0 + w, y0)))), crs = 5070)
}
outer_b <- sq(0, 0, 100000)          # 100 km square = 10,000 km^2
inner_b <- sq(10000, 10000, 50000)   #  50 km square =  2,500 km^2, fully inside
escapee <- sq(90000, 90000, 50000)   # overlaps the corner, 3/4 outside

cat("\n-- BVA --\n")

# T131. Degenerate inputs. An empty band must measure 0 escape, not error or
# NA -- a band with no isochrones is a real state early in a build.
{
  empty <- st_sfc(crs = 5070)
  chk(nesting_escape_km2(empty, outer_b) == 0 &&
        nesting_escape_km2(inner_b, outer_b) == 0,
      "T131 an empty inner band and a fully nested band both escape 0 km2")
}

# T132. The escape measurement itself: the MAGNITUDE matters, not just
# "nonzero" -- it is what says how badly the routing engines disagree.
# The overlap is exactly the 10 km x 10 km corner where the two squares meet,
# so the escape is 2,500 - 100 = 2,400 km^2. (First written as 1,875 on a
# careless reading of the geometry; the code was right and the expectation
# was wrong.)
{
  e <- nesting_escape_km2(escapee, outer_b)
  chk(abs(e - 2400) < 1,
      sprintf("T132 escape is %.0f km2 of 2,500, the 100 km2 corner overlap excluded", e))
}

# T133. The inversion rule at its boundary. Real inland water is a few percent;
# 50% is the line, and a mask at 102% of state area is the observed failure.
{
  chk(identical(is_inverted_water_mask(c(2, 49.9, 50.1, 102), rep(100, 4)),
                c(FALSE, FALSE, TRUE, TRUE)),
      "T133 inversion flags >50% of state land, not 49.9%")
}

cat("\n-- SEMANTIC --\n")

# T134. THE DEFECT. A missing mask directory must STOP a final build. The
# shipped code wrapped the clip in if (dir.exists(...)), so an unmounted drive
# silently produced surfaces that count the Great Lakes as drivable ground.
{
  refused <- tryCatch({
    water_clip_provenance("/no/such/drive/water_masks", c("MI", "WI"),
                          require_clip = TRUE); FALSE
  }, error = function(e) grepl("Great Lakes|land clip unavailable", e$message))
  chk(refused, "T134 a missing water-mask directory refuses a final build")
}

# T135. And when a non-final run is explicitly requested, the surface must
# still SAY it is unclipped rather than passing as finished.
{
  p <- water_clip_provenance("/no/such/drive/water_masks", c("MI", "WI"),
                             require_clip = FALSE)
  chk(nrow(p) == 1L && !p$clip_applied && !p$final && p$masks_found == 0L,
      "T135 an explicitly unclipped run is recorded as not final")
}

# T136. Privacy. A published surface is one dissolved feature; two features
# means per-provider polygons reached the map.
{
  one <- st_sf(band = "30", geometry = outer_b)
  two <- st_sf(band = c("30", "30"), geometry = c(outer_b, inner_b))
  refused <- tryCatch({ assert_dissolved_privacy(two, "30min"); FALSE },
                      error = function(e) grepl("identifiable", e$message))
  chk(isTRUE(assert_dissolved_privacy(one, "30min")) && refused,
      "T136 one feature passes, two features are refused as identifiable")
}

# T137. Escape must be measured BEFORE absorption. Once the smaller band is
# unioned into the larger, the escape is 0 by construction -- the fix and the
# evidence destroyed in one statement.
{
  before <- nesting_escape_km2(escapee, outer_b)
  absorbed <- st_union(st_geometry(outer_b), st_geometry(escapee))
  after <- nesting_escape_km2(escapee, absorbed)
  chk(before > 1000 && after == 0,
      sprintf("T137 escape is %.0f km2 before absorption and %.0f after -- measure first",
              before, after))
}

cat("\n-- ADVERSARIAL --\n")

# T138. ENFORCE THE SWEEP. No script may gate the land clip on a bare
# dir.exists() again. The construct is the defect: it converts a missing input
# into a silently different product.
{
  rfiles <- list.files(".", pattern = "[.]R$", recursive = TRUE, full.names = TRUE)
  rfiles <- rfiles[!grepl("/tests/|/renv/|coverage_surface_contracts", rfiles)]
  # COMMENTS STRIPPED FIRST. The initial version matched its own explanatory
  # comment in build_midwifery_isochrone_map.R -- the guard flagging its own
  # documentation. A text sweep that fires on prose either produces false
  # alarms or, worse, teaches the next person to delete the explanation to get
  # green. Only code is searched.
  offenders <- character(0)
  for (f in rfiles) {
    ln <- readLines(f, warn = FALSE)
    ln <- sub("#.*$", "", ln)
    hit <- grep("if\\s*\\(\\s*dir.exists\\(water_dir\\)\\s*\\)", ln)
    if (length(hit)) offenders <- c(offenders, sprintf("%s:%d", basename(f), hit[1]))
  }
  chk(length(offenders) == 0,
      sprintf("T138 no build gates the land clip on a bare dir.exists [%s]",
              if (length(offenders)) paste(offenders, collapse = ", ") else "none"))
}

# T139. Reported area must not depend on which CRS the surface happens to be
# carrying. Originally written expecting sf to return square DEGREES for a
# lon/lat layer with s2 disabled -- it does not: sf 1.1 computes a geodesic
# area either way and returns 10,000.28 km^2 against 10,000.00 from the
# equal-area projection. The premise was wrong, so the test now asserts the
# property that actually protects the number: the two routes AGREE to well
# under a percent, and a coverage area is therefore reproducible regardless of
# the CRS an intermediate step left behind.
{
  a_proj <- as.numeric(st_area(outer_b)) / 1e6
  ll <- st_transform(outer_b, 4326)
  a_geo <- as.numeric(st_area(ll)) / 1e6
  chk(abs(a_proj - 10000) < 1 && abs(a_proj - a_geo) / a_proj < 0.005,
      sprintf("T139 equal-area %.1f km2 and geodesic %.1f km2 agree to %.3f%%",
              a_proj, a_geo, 100 * abs(a_proj - a_geo) / a_proj))
}

# T140. The union must not silently drop a disjoint band. A second, separate
# coverage island is real (Alaska, an offshore community) and must survive
# dissolving as part of one multipolygon.
{
  far <- sq(500000, 500000, 20000)   # 400 km^2, disjoint
  u <- st_union(st_geometry(outer_b), st_geometry(far))
  chk(length(u) == 1L && abs(as.numeric(st_area(u)) / 1e6 - 10400) < 1,
      sprintf("T140 a disjoint island survives the dissolve [%.0f km2 of 10,400]",
              as.numeric(st_area(u)) / 1e6))
}

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
