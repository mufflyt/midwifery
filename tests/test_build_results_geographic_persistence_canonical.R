#!/usr/bin/env Rscript
# =============================================================================
# build_results_geographic_persistence_canonical.R: the fan-out join and the
# method-comparison output
# =============================================================================
# The pairs/career/rurality/movers MATH is shared with (and already tested
# by) test_build_results_geographic_persistence.R via
# R/lib/geographic_persistence_stats.R. This test covers only what's unique
# to the canonical script: fanning one geocoded DISTINCT address out across
# every provider-year that shares it, an address with no geocode result at
# all resolving to NA (not a crash or a silently wrong county), and the
# method-comparison file.
#
# Fixture:
#   2001: 2020,2021,2022, all "1 MAIN ST, CITYA, XA, 10001" (-> county 11111,
#         metro) -- the SAME geocode result fans out across all 3 years
#   2002: 2020 "2 MAIN ST, CITYA, XA, 10001" (-> 11111), 2021 "3 OAK ST,
#         CITYB, XB, 20002" (-> 22222, nonmetro adj) -- a mover, 2 distinct
#         addresses each geocoded once
#   2003: 2020 "1 MAIN ST, CITYA, XA, 10001" (-> 11111), 2021 "9 UNKNOWN AVE,
#         CITYC, XC, 99999" -- this second address has NO row in the geocode
#         results at all (simulating "All_Methods_Failed" or simply never
#         queued), so the pair must be excluded from the county denominator,
#         not crash and not silently inherit the previous year's county

root <- if (basename(getwd()) == "tests") ".." else "."
script <- normalizePath(file.path(root, "build_results_geographic_persistence_canonical.R"))
stopifnot(file.exists(script))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
near <- function(x, y, tol = 0.01) !is.na(x) && !is.na(y) && abs(x - y) < tol
`%||%` <- function(a, b) if (is.null(a)) b else a

tmp <- tempfile("geo_persist_canonical_test_")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

writeLines(c(
  "npi,cohort_member",
  "2001,TRUE", "2002,TRUE", "2003,TRUE"
), file.path(tmp, "linkage.csv"))

writeLines(c(
  "npi,practice_address,practice_city,practice_state,practice_zip,snapshot_year",
  "2001,1 MAIN ST,CITYA,XA,10001,2020",
  "2001,1 MAIN ST,CITYA,XA,10001,2021",
  "2001,1 MAIN ST,CITYA,XA,10001,2022",
  "2002,2 MAIN ST,CITYA,XA,10001,2020",
  "2002,3 OAK ST,CITYB,XB,20002,2021",
  "2003,1 MAIN ST,CITYA,XA,10001,2020",
  "2003,9 UNKNOWN AVE,CITYC,XC,99999,2021"
), file.path(tmp, "panel.csv"))

# Same 25-column schema geocode_queue_cascade.R actually writes (see its real
# output's header) -- this script's col_types = cols(.default = "c") reads
# every column as character, so only the 5 actually used need real values;
# the rest are blank, matching how a real run leaves optional fields.
geocode_header <- "geocode_address_1,geocode_city,geocode_state,geocode_zip,address_hash,matched_address,lon,lat,match_indicator,matched_zip,geocode_source,match_type,geocoder_provenance,tract_name,county_name,state_name,confidence_score,quality_score,failure_reason,latitude,longitude,census_tract,state_fips,county_fips,county_geoid_5char"
geocode_row <- function(addr, city, state, zip, county5) {
  sprintf('%s,%s,%s,%s,,,,,,,,,,,,,,,,,,,,,%s', addr, city, state, zip, county5)
}
writeLines(c(
  geocode_header,
  geocode_row("1 MAIN ST", "CITYA", "XA", "10001", "11111"),
  geocode_row("2 MAIN ST", "CITYA", "XA", "10001", "11111"),
  geocode_row("3 OAK ST", "CITYB", "XB", "20002", "22222")
  # "9 UNKNOWN AVE, CITYC, XC, 99999" deliberately has NO row -- simulating a
  # failed/never-queued geocode
), file.path(tmp, "geocode_results.csv"))

writeLines(c(
  "GEOID,rucc_2023",
  "11111,2",  # Metro
  "22222,5"   # Nonmetro, adjacent
), file.path(tmp, "county_base.csv"))

out_panel <- file.path(tmp, "out_panel_summary.csv")
out_rates <- file.path(tmp, "out_rates.csv")
out_rurality <- file.path(tmp, "out_rurality.csv")
out_movers <- file.path(tmp, "out_movers.csv")
out_comparison <- file.path(tmp, "out_comparison.csv")

run_it <- function(zcta_rates_path) {
  env <- c(
    sprintf("GEO_PERSIST_LINKAGE=%s", file.path(tmp, "linkage.csv")),
    sprintf("GEO_PERSIST_PANEL=%s", file.path(tmp, "panel.csv")),
    sprintf("GEO_PERSIST_CANONICAL_GEOCODE=%s", file.path(tmp, "geocode_results.csv")),
    sprintf("GEO_PERSIST_CBASE=%s", file.path(tmp, "county_base.csv")),
    sprintf("GEO_PERSIST_ZCTA_RATES=%s", zcta_rates_path),
    sprintf("GEO_PERSIST_CANONICAL_OUT_PANEL_SUMMARY=%s", out_panel),
    sprintf("GEO_PERSIST_CANONICAL_OUT_RATES=%s", out_rates),
    sprintf("GEO_PERSIST_CANONICAL_OUT_RURALITY=%s", out_rurality),
    sprintf("GEO_PERSIST_CANONICAL_OUT_MOVERS=%s", out_movers),
    sprintf("GEO_PERSIST_OUT_COMPARISON=%s", out_comparison)
  )
  suppressWarnings(system2("Rscript", shQuote(script), env = env,
                           stdout = TRUE, stderr = TRUE, wait = TRUE, timeout = 60))
}

# --- Run 1: no ZCTA rates file present -> comparison must be skipped, not error
res1 <- run_it(file.path(tmp, "does_not_exist.csv"))
status1 <- attr(res1, "status") %||% 0L
chk(identical(status1, 0L), sprintf("script exits 0 with no comparison file available (status=%s)", status1))
if (!identical(status1, 0L)) cat(paste(res1, collapse = "\n"), "\n")
chk(!file.exists(out_comparison), "no comparison file written when the ZCTA rates file doesn't exist")

if (file.exists(out_panel)) {
  p <- read.csv(out_panel)
  chk(p$provider_years == 7L, sprintf("7 provider-years (got %s)", p$provider_years))
  chk(p$pairs_total == 4L, sprintf("4 consecutive-year pairs (got %s) -- 2001 x2, 2002 x1, 2003 x1", p$pairs_total))
  chk(p$pairs_used == 3L, sprintf("3 pairs have a resolved county on both ends (got %s) -- 2003's unqueried address excluded", p$pairs_used))
}

if (file.exists(out_rates)) {
  r <- read.csv(out_rates)
  annual <- r[r$horizon == "year_to_year", ]
  # Resolved pairs: 2001's two (same county, fans out correctly) + 2002's one
  # (different county) = 3 resolved, 2 same -> 66.7%
  chk(near(annual$same_county_pct, 200 / 3),
      sprintf("annual same-county 66.7%% of 3 resolved pairs (got %s) -- confirms the fan-out: 2001's repeated address resolves to the SAME county every year", annual$same_county_pct))
}

# --- Run 2: a ZCTA rates file IS present -> comparison must be written
writeLines(c("horizon,n,same_county_pct,same_zip_pct,same_state_pct",
             "year_to_year,999,55.5,44.4,77.7"), file.path(tmp, "zcta_rates.csv"))
unlink(out_comparison)
res2 <- run_it(file.path(tmp, "zcta_rates.csv"))
status2 <- attr(res2, "status") %||% 0L
chk(identical(status2, 0L), sprintf("script exits 0 with a comparison file present (status=%s)", status2))
chk(file.exists(out_comparison), "comparison file written when the ZCTA rates file exists")
if (file.exists(out_comparison)) {
  cmp <- read.csv(out_comparison)
  chk(setequal(cmp$method, c("zcta_crosswalk", "canonical_cascade")),
      sprintf("comparison carries both methods (got %s)", paste(unique(cmp$method), collapse = ",")))
  zc <- cmp[cmp$method == "zcta_crosswalk" & cmp$horizon == "year_to_year", ]
  chk(nrow(zc) == 1L && near(zc$same_county_pct[1], 55.5),
      "the ZCTA row in the comparison carries the fixture's own 55.5%, not the canonical run's number")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAILED", fails))
if (fails > 0L) quit(status = 1L)
