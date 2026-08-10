#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 5 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: carried-forward item (e), open since cycle 2 -- 13 unaudited
# `distinct(<key>, .keep_all = TRUE)` sites. The one in geocode_midwives.R is
# LIVE, not latent: 48 address keys in the cache carry conflicting
# coordinates, spread up to 1,074.8 km, and row order decided which one won.
# Coordinates feed isochrones, travel times and county assignment, so this is
# the highest-consequence defect the loop has found.
#
# Run: Rscript tests/test_cycle5_geocode_conflicts.R
# =============================================================================

source("R/lib/geocode_conflicts.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
# The retired rule, for anti-ceremony checks.
old_pick <- function(d) d[!duplicated(d$key), ]

cat("\n-- BVA --\n")

# T41. Degenerate sizes. Zero rows must return zero rows with the right column
# types; one row must pass through untouched.
{
  e <- resolve_geocode_key(character(0), numeric(0), numeric(0))
  one <- resolve_geocode_key("A", 39.7, -104.9, 8)
  chk(nrow(e) == 0L && is.character(e$key) && is.numeric(e$lat) &&
        nrow(one) == 1L && one$resolution == "unique" && one$lat == 39.7,
      "T41 zero rows -> typed empty frame; one row passes through as 'unique'")
}

# T42. The tolerance boundary. Just inside must resolve, just outside must
# refuse -- this is where a `<` / `<=` slip silently readmits a bad coordinate.
{
  # ~0.9 km and ~1.5 km apart in latitude at this longitude.
  near <- resolve_geocode_key(c("A", "A"), c(39.7000, 39.7081), c(-104.9, -104.9),
                              c(NA, NA), max_spread_km = 1)
  far  <- resolve_geocode_key(c("A", "A"), c(39.7000, 39.7135), c(-104.9, -104.9),
                              c(NA, NA), max_spread_km = 1)
  chk(near$resolution == "within_tolerance" && !is.na(near$lat) &&
        far$resolution == "refused_ambiguous" && is.na(far$lat),
      sprintf("T42 tolerance edge: %.2f km resolves, %.2f km refuses",
              near$spread_km, far$spread_km))
}

# T43. All-NA quality must not be read as a winner. max() on all-NA with
# na.rm=TRUE returns -Inf and a warning, and which.max() would still pick
# something -- fabricating a decision out of no information.
{
  r <- resolve_geocode_key(c("A", "A"), c(39.7, 40.9), c(-104.9, -104.9),
                           c(NA, NA))
  chk(r$resolution == "refused_ambiguous" && is.na(r$lat) && is.na(r$quality),
      "T43 all-NA quality refuses rather than picking a winner")
}

cat("\n-- SEMANTIC --\n")

# T44. THE DEFECT. Quality decides where it can; where it cannot, the key gets
# no coordinate. A 1,000 km disagreement must never yield a confident point.
{
  q <- resolve_geocode_key(c("A", "A"), c(36.10, 39.70), c(-80.25, -104.90),
                           c(9, 3))
  t <- resolve_geocode_key(c("B", "B"), c(36.10, 39.70), c(-80.25, -104.90),
                           c(5, 5))
  chk(q$resolution == "by_quality" && q$lat == 36.10 &&
        t$resolution == "refused_ambiguous" && is.na(t$lat),
      sprintf("T44 quality resolves (%.2f) and a tie refuses at %.0f km",
              q$lat, t$spread_km))
}

# T45. The reported disagreement must be the real great-circle distance, not a
# planar approximation -- a degree of longitude is not a degree of latitude.
#
# TOLERANCE, JUSTIFIED. geosphere::distHaversine defaults to the EQUATORIAL
# radius (6378.137 km); this resolver uses the mean radius (6371 km), the
# usual choice for haversine. The two differ by ~0.3%. That is 2.4 km over a
# 2,200 km separation and 3 m at the 1 km threshold where the refuse/resolve
# decision is actually made. So: relative agreement over long distances, and
# a tight ABSOLUTE bound near the threshold, which is the stricter test of the
# two and the one that matters.
{
  r <- resolve_geocode_key(c("A", "A"), c(36.0995, 39.7392), c(-80.2442, -104.9903),
                           c(1, 2))
  truth <- geosphere::distHaversine(c(-80.2442, 36.0995), c(-104.9903, 39.7392)) / 1000
  far_ok <- abs(r$spread_km - truth) / truth < 0.005

  near <- resolve_geocode_key(c("A", "A"), c(39.70000, 39.70900), c(-104.9, -104.9),
                              c(1, 2), max_spread_km = 1)
  near_truth <- geosphere::distHaversine(c(-104.9, 39.70000), c(-104.9, 39.70900)) / 1000
  near_ok <- abs(near$spread_km - near_truth) < 0.010   # 10 m at the threshold

  chk(far_ok && near_ok,
      sprintf("T45 spread_km is great-circle: %.1f vs %.1f km far (%.2f%%), %.0f m error at the 1 km threshold",
              r$spread_km, truth, 100 * abs(r$spread_km - truth) / truth,
              1000 * abs(near$spread_km - near_truth)))
}

# T46. One row per key, and no key invented or dropped. A resolver that loses
# keys silently shrinks the geocoded cohort.
{
  k <- c("A", "A", "B", "C", "C", "C")
  r <- resolve_geocode_key(k, c(1, 1, 2, 3, 3, 3), c(1, 1, 2, 3, 3, 3), rep(1, 6))
  chk(nrow(r) == 3L && identical(sort(r$key), c("A", "B", "C")) &&
        all(r$n_candidates == c(2, 1, 3)),
      "T46 exactly one row per key, key set preserved, candidates counted")
}

# T47. Identical duplicates are not a conflict. Over-refusing would discard
# most of the cache, which is the opposite failure and just as damaging.
{
  r <- resolve_geocode_key(c("A", "A", "A"), rep(39.7, 3), rep(-104.9, 3), rep(7, 3))
  chk(r$resolution == "within_tolerance" && r$spread_km == 0 && r$lat == 39.7,
      "T47 identical duplicates collapse without refusal")
}

cat("\n-- ADVERSARIAL --\n")

# T48. ROW ORDER. This is the defect itself: distinct() returns whichever row
# came first, so the same cache in a different order yields a different
# coordinate. The resolver must be order-invariant.
{
  d <- data.frame(key = c("A", "A"), lat = c(36.10, 39.70),
                  lon = c(-80.25, -104.90), q = c(9, 3))
  fwd <- resolve_geocode_key(d$key, d$lat, d$lon, d$q)
  rev <- resolve_geocode_key(rev(d$key), rev(d$lat), rev(d$lon), rev(d$q))
  chk(identical(fwd$lat, rev$lat) && identical(fwd$resolution, rev$resolution),
      "T48 resolution is invariant to row order")
  # ANTI-CEREMONY: the retired rule must FAIL this, or the test proves nothing.
  o1 <- old_pick(d); o2 <- old_pick(d[2:1, ])
  chk(!identical(o1$lat, o2$lat),
      sprintf("T48b the retired distinct() rule is discriminated (%.2f vs %.2f)",
              o1$lat, o2$lat))
}

# T49. A tie on quality where the coordinates ALSO tie is not ambiguous. The
# refusal must key on the coordinates disagreeing, not on the score tying.
{
  r <- resolve_geocode_key(c("A", "A"), c(39.7, 39.7), c(-104.9, -104.9), c(5, 5))
  chk(r$resolution == "within_tolerance" && !is.na(r$lat),
      "T49 tied quality with identical coordinates still resolves")
}

# T50. ENFORCE THE SWEEP (cycle 2 lesson: a manual grep missed three files).
# No coordinate-bearing table may be collapsed with distinct(.keep_all) again.
{
  rfiles <- list.files(".", pattern = "[.]R$", recursive = TRUE, full.names = TRUE)
  rfiles <- rfiles[!grepl("/tests/|/renv/|table1_bands|geocode_conflicts", rfiles)]
  offenders <- character(0)
  for (f in rfiles) {
    ln <- readLines(f, warn = FALSE)
    hit <- grep("distinct\\((cache_key|key_nozip)[^)]*\\.keep_all", ln)
    if (length(hit)) offenders <- c(offenders, sprintf("%s:%d", f, hit[1]))
  }
  chk(length(offenders) == 0,
      sprintf("T50 no coordinate key collapsed by distinct(.keep_all) [%s]",
              if (length(offenders)) paste(offenders, collapse = ", ") else "none"))
}

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
