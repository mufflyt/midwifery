#!/usr/bin/env Rscript
# =============================================================================
# build_results_geographic_persistence.R: 5 synthetic providers, a hand-worked
# answer
# =============================================================================
# Shells out to a real `Rscript build_results_geographic_persistence.R`
# against tiny fixture files in a temp directory (env-var path overrides,
# same pattern as repin_frozen_cohort.R / geocode_queue_cascade.R), rather
# than sourcing the script's internals -- the thing actually worth testing is
# "does the real invocation produce the right numbers", not a reimplementation
# of the same logic that would drift with it.
#
# Fixture design (every number below is checked against a value worked out
# by hand, not re-derived from the script's own output):
#   1001: 2020,2021,2022, all zip 10001 (county A, metro) -- stable, 2 pairs
#   1002: 2020 zip 10001 (A), 2021 zip 20002 (B, nonmetro adj) -- 1 pair, a mover
#   1003: 2020 only -- single observation, excluded from every pair/career calc
#   1004: 2020 zip 10001 (A), 2022 zip 20002 (B) -- a GAP YEAR (2021 missing),
#         checking pairs are consecutive OBSERVED years, not y/y+1
#   1005: 2020 zip 99999 (no crosswalk entry -- unresolvable county),
#         2021 zip 10001 (A) -- checks a pair with an unresolved county is
#         excluded from the county denominator but still counts toward
#         zip/state, and that an unresolved FIRST observation drops a
#         provider from the rurality-origin and movers breakdowns entirely
#         (first_rucc is NA, not "Unknown")
#
# The ZCTA crosswalk fixture also gives zip 10001 TWO competing counties
# (county A, 800,000 sq units; county 33333, 200,000 sq units) so the
# canonical zip_county_dominant() is actually exercised picking the larger
# one, not merely monkey-patched to return what this test expects.

root <- if (basename(getwd()) == "tests") ".." else "."
script <- normalizePath(file.path(root, "build_results_geographic_persistence.R"))
stopifnot(file.exists(script))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
near <- function(x, y, tol = 0.01) !is.na(x) && !is.na(y) && abs(x - y) < tol

tmp <- tempfile("geo_persist_test_")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

writeLines(c(
  "npi,cohort_member",
  "1001,TRUE", "1002,TRUE", "1003,TRUE", "1004,TRUE", "1005,TRUE",
  "9999,FALSE"  # a non-cohort NPI present in the panel too (checked out below)
), file.path(tmp, "linkage.csv"))

writeLines(c(
  "npi,practice_zip,practice_state,snapshot_year",
  "1001,10001,XA,2020", "1001,10001,XA,2021", "1001,10001,XA,2022",
  "1002,10001,XA,2020", "1002,20002,XB,2021",
  "1003,10001,XA,2020",
  "1004,10001,XA,2020", "1004,20002,XB,2022",
  "1005,99999,XC,2020", "1005,10001,XA,2021",
  "9999,10001,XA,2020", "9999,20002,XB,2021"  # not cohort_member -- must be dropped
), file.path(tmp, "panel.csv"))

# Pipe-delimited, matching data/zcta_county_2020.txt's real schema exactly
# (zip_county_dominant() -> zcta_county_parts() reads these exact column
# names). zip 10001 deliberately split across two counties so the dominant
# (largest AREALAND_PART) pick is exercised, not assumed.
writeLines(c(
  "GEOID_ZCTA5_20|GEOID_COUNTY_20|AREALAND_PART",
  "10001|11111|800000",
  "10001|33333|200000",
  "20002|22222|2000000"
  # 99999 has NO row at all -- an unresolvable ZIP, on purpose
), file.path(tmp, "zcta.txt"))

writeLines(c(
  "GEOID,rucc_2023",
  "11111,2",   # Metro
  "22222,5"    # Nonmetro, adjacent
  # 33333 deliberately absent: it should never be looked up, since it's
  # never the dominant county for any ZIP in this fixture
), file.path(tmp, "county_base.csv"))

out_panel <- file.path(tmp, "out_panel_summary.csv")
out_rates <- file.path(tmp, "out_rates.csv")
out_rurality <- file.path(tmp, "out_rurality.csv")
out_movers <- file.path(tmp, "out_movers.csv")

env <- c(
  sprintf("GEO_PERSIST_LINKAGE=%s", file.path(tmp, "linkage.csv")),
  sprintf("GEO_PERSIST_PANEL=%s", file.path(tmp, "panel.csv")),
  sprintf("GEO_PERSIST_ZCTA_RAW=%s", file.path(tmp, "zcta.txt")),
  sprintf("GEO_PERSIST_CBASE=%s", file.path(tmp, "county_base.csv")),
  sprintf("GEO_PERSIST_OUT_PANEL_SUMMARY=%s", out_panel),
  sprintf("GEO_PERSIST_OUT_RATES=%s", out_rates),
  sprintf("GEO_PERSIST_OUT_RURALITY=%s", out_rurality),
  sprintf("GEO_PERSIST_OUT_MOVERS=%s", out_movers)
)
res <- suppressWarnings(system2("Rscript", c(shQuote(script)), env = env,
                                stdout = TRUE, stderr = TRUE, wait = TRUE, timeout = 60))
status <- attr(res, "status") %||% 0L
`%||%` <- function(a, b) if (is.null(a)) b else a
output <- paste(res, collapse = "\n")

chk(identical(status, 0L), sprintf("script exits 0 (status=%s)", status))
if (!identical(status, 0L)) cat(output, "\n")

chk(file.exists(out_panel), "panel summary written")
chk(file.exists(out_rates), "rates written")
chk(file.exists(out_rurality), "rurality written")
chk(file.exists(out_movers), "movers written")
chk(file.exists(paste0(out_panel, ".provenance.json")), "panel summary has a provenance sidecar")

if (file.exists(out_panel)) {
  p <- read.csv(out_panel)
  chk(p$observed == 5L, sprintf("5 cohort providers observed (got %s) -- 9999 excluded (not cohort_member)", p$observed))
  chk(p$provider_years == 10L, sprintf("10 provider-years (got %s)", p$provider_years))
  chk(p$pairs_total == 5L, sprintf("5 consecutive-year pairs total (got %s)", p$pairs_total))
  chk(p$pairs_used == 4L, sprintf("4 pairs have a resolved county on both ends (got %s) -- 1005's unresolved-ZIP year excluded", p$pairs_used))
  chk(p$providers_used == 4L, sprintf("4 providers have >1 observation (got %s) -- 1003 excluded", p$providers_used))
  chk(near(p$median_span, 1.5), sprintf("median career span 1.5 years (got %s) -- spans are 2,1,2,1", p$median_span))
}

if (file.exists(out_rates)) {
  r <- read.csv(out_rates)
  annual <- r[r$horizon == "year_to_year", ]
  career <- r[r$horizon == "first_vs_last", ]
  chk(near(annual$same_county_pct, 50), sprintf("annual same-county 50%% of 4 resolved pairs (got %s)", annual$same_county_pct))
  chk(near(annual$same_zip_pct, 40), sprintf("annual same-ZIP 40%% of all 5 pairs (got %s)", annual$same_zip_pct))
  chk(near(annual$same_state_pct, 40), sprintf("annual same-state 40%% of all 5 pairs (got %s)", annual$same_state_pct))
  chk(near(career$same_county_pct, 100 / 3), sprintf("career same-county 33.3%% of 3 resolved (got %s) -- 1005 excluded, first obs unresolved", career$same_county_pct))
  chk(near(career$same_zip_pct, 25), sprintf("career same-ZIP 25%% of all 4 (got %s)", career$same_zip_pct))
}

if (file.exists(out_rurality)) {
  u <- read.csv(out_rurality)
  chk(nrow(u) == 1L, sprintf("only Metro origin appears (got %d row(s)) -- nobody's FIRST observation starts nonmetro", nrow(u)))
  if (nrow(u) == 1L) {
    chk(u$origin[1] == "Metro (RUCC 1-3)", sprintf("the one origin row is Metro (got %s)", u$origin[1]))
    chk(u$providers[1] == 3L, sprintf("3 Metro-origin providers with a resolved pair (got %s) -- 1005 dropped: first-obs county unresolved means first_rucc is NA, not a stratum", u$providers[1]))
    chk(near(u$annual_same_county[1], 50), sprintf("Metro-origin annual same-county 50%% (got %s)", u$annual_same_county[1]))
    chk(near(u$career_same_county[1], 100 / 3), sprintf("Metro-origin career same-county 33.3%% (got %s)", u$career_same_county[1]))
  }
}

if (file.exists(out_movers)) {
  m <- read.csv(out_movers)
  chk(nrow(m) == 9L, sprintf("3x3 origin/destination grid, zero-filled (got %d rows)", nrow(m)))
  hit <- m[m$origin == "Metro (RUCC 1-3)" & m$destination == "Nonmetro, adjacent (RUCC 4-6)", ]
  chk(nrow(hit) == 1L && hit$n[1] == 2L,
      sprintf("Metro -> Nonmetro-adjacent carries 2 movers (1002, 1004) (got %s)", if (nrow(hit)) hit$n[1] else NA))
  other_cells <- m[!(m$origin == "Metro (RUCC 1-3)" & m$destination == "Nonmetro, adjacent (RUCC 4-6)"), ]
  chk(all(other_cells$n == 0), "every other cell is explicitly 0, not absent -- complete() filled the grid")
  # 1005 is a would-be Metro-destination mover (99999 -> 10001) but its FIRST
  # observation has no resolved county, so it must not inflate any cell,
  # including Metro -> Metro.
  mm <- m[m$origin == "Metro (RUCC 1-3)" & m$destination == "Metro (RUCC 1-3)", ]
  chk(nrow(mm) == 1L && mm$n[1] == 0L,
      "Metro -> Metro is 0, not 1 -- 1005 does not leak into the grid via its unresolved origin")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAILED", fails))
if (fails > 0L) quit(status = 1L)
