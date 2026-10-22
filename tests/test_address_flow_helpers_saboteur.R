#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests for R/lib/address_flow_helpers.R
# =============================================================================
# Pairs with the 10 entries this cycle adds to tests/mutation_catalogue.R.
# Each test below is written to go RED under one specific, plausible bug a
# competent person could introduce into address_flow_helpers.R -- not just
# to confirm the happy path. Run standalone:
#
#   Rscript tests/test_address_flow_helpers_saboteur.R
#
# Exercised against the catalogue:
#
#   Rscript tests/ci_mutation_testing.R
#   MUTATION_ID=flowhelper-classify-distance-check-removed Rscript tests/ci_mutation_testing.R
#   (... one per id below)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

suppressPackageStartupMessages({library(dplyr)})
source(file.path("R", "lib", "address_flow_helpers.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
errors <- function(expr) inherits(tryCatch(expr, error = function(e) e), "error")

# -----------------------------------------------------------------------------
# classify_mismatch(): distance-corrected city classification
# -----------------------------------------------------------------------------
# ~0.11 km apart (well under the 1km same-place tolerance)
NEAR <- list(lat1 = 0, lon1 = 0, lat2 = 0.001, lon2 = 0)
# ~1,110 km apart (well over it)
FAR  <- list(lat1 = 0, lon1 = 0, lat2 = 10,    lon2 = 0)

# flowhelper-classify-distance-check-removed
chk(classify_mismatch(NEAR$lat1, NEAR$lon1, "SAINT PAUL", "MN", NEAR$lat2, NEAR$lon2, "ST PAUL", "MN") == "Same city",
    "A1 two points 0.11km apart with DIFFERENT city strings (spelling variant) classify as Same city, not a string mismatch")

# flowhelper-classify-operator-flipped
chk(classify_mismatch(FAR$lat1, FAR$lon1, "MINNEAPOLIS", "MN", FAR$lat2, FAR$lon2, "DULUTH", "MN") == "Different city, same state",
    "A2 two points 1,110km apart with different city strings, same state classify as a real mismatch, not Same city")

# flowhelper-classify-priority-inverted
chk(classify_mismatch(FAR$lat1, FAR$lon1, "AUSTIN", "TX", FAR$lat2, FAR$lon2, "DENVER", "CO") == "Different state",
    "A3 far apart, different city AND different state: state mismatch wins (not relabeled as same-state city mismatch)")

# flowhelper-classify-state-check-skippable
chk(classify_mismatch(FAR$lat1, FAR$lon1, "SPRINGFIELD", "IL", FAR$lat2, FAR$lon2, "SPRINGFIELD", "MA") == "Different state",
    "A4 far apart, IDENTICAL city string but different state still classifies as Different state")

# -----------------------------------------------------------------------------
# aggregate_flows(): the min_flow_n disclosure control, and median robustness
# -----------------------------------------------------------------------------
mismatches <- tibble::tibble(
  npi = as.character(c(1:6, 101:103, 201)),
  source = "DAC",
  nppes_state = "CO", comparison_state = "CO",
  nppes_city = "DENVER",
  comparison_city = c(rep("AURORA", 6), rep("BOULDER", 3), "LITTLETON"),
  mismatch_type = "Different city, same state",
  nppes_lon = c(rep(-0.001, 5), 100, -0.0005, 0, 0.0005, 0.001),
  nppes_lat = 0,
  comparison_lon = 0, comparison_lat = 0
)
agg <- aggregate_flows(mismatches, min_flow_n = 5L)

# flowhelper-aggregate-disclosure-filter-removed
chk(nrow(agg$displayed) == 1L && agg$displayed$comparison_city[1] == "AURORA",
    "B1 only the 6-midwife AURORA flow survives min_flow_n=5; the 3- and 1-midwife flows are withheld (disclosure control)")
chk(all(agg$displayed$n_midwives >= 5L),
    "B2 every displayed flow meets min_flow_n -- no flow with fewer midwives than the threshold leaks through")

# flowhelper-aggregate-median-to-mean
# AURORA flow's 6 origin_lon values: five near 0, one wild outlier at 100.
# True median stays near 0; a mean would be dragged toward ~16.5.
chk(abs(agg$displayed$origin_lon[1]) < 1,
    "B3 a flow's displayed origin uses the MEDIAN coordinate, not the mean -- one wild outlier geocode does not drag it off-cluster")

# -----------------------------------------------------------------------------
# check_no_duplicate_rows(): the duplicate-key guard
# -----------------------------------------------------------------------------
clean_rows <- tibble::tibble(npi = c("1", "2"), year = 2026L, source = "DAC")
dup_rows <- tibble::tibble(npi = c("1", "1"), year = 2026L, source = "DAC")

chk(!errors(check_no_duplicate_rows(clean_rows)),
    "C1 (control) rows with no repeated npi/year/source pass silently")
# flowhelper-duplicate-guard-removed
chk(errors(check_no_duplicate_rows(dup_rows)),
    "C2 two rows sharing the same npi/year/source stop loudly instead of silently proceeding")

# -----------------------------------------------------------------------------
# validate_address_pairs_columns(): the required-columns guard
# -----------------------------------------------------------------------------
complete_pairs <- as.data.frame(matrix(ncol = length(ADDRESS_PAIRS_REQUIRED_COLS), nrow = 0,
                                       dimnames = list(NULL, ADDRESS_PAIRS_REQUIRED_COLS)))
missing_one <- complete_pairs[, setdiff(names(complete_pairs), "nppes_lat"), drop = FALSE]

chk(!errors(validate_address_pairs_columns(complete_pairs)),
    "D1 (control) a table with every required column passes silently")
# flowhelper-required-columns-no-op
chk(errors(validate_address_pairs_columns(missing_one)),
    "D2 a table missing one required column (nppes_lat) stops loudly instead of failing confusingly downstream")

# -----------------------------------------------------------------------------
# valid_coordinate_rows(): the lon/lat plausibility bounds
# -----------------------------------------------------------------------------
coord_rows <- tibble::tibble(
  npi = c("1", "2"),
  nppes_lon = c(-104.9, 200), nppes_lat = c(39.7, 39.7),          # row 2's lon is out of range
  comparison_lon = c(-104.9, -104.9), comparison_lat = c(39.7, 39.7),
  nppes_city = "DENVER", comparison_city = "DENVER", nppes_state = "CO", comparison_state = "CO"
)
# flowhelper-coordinate-bounds-removed
chk(nrow(valid_coordinate_rows(coord_rows)) == 1L && valid_coordinate_rows(coord_rows)$npi == "1",
    "E1 a row with an out-of-range longitude (200) is dropped, not passed through to the map")

# -----------------------------------------------------------------------------
# read_census_batch_result(): No_Match filtering and lon/lat field order
# -----------------------------------------------------------------------------
# Real Census batch geocoder format, no header:
#   ID,input_address,match_status,match_type,matched_address,"lon,lat",tiger_line_id,side
fixture <- tempfile(fileext = ".csv")
writeLines(c(
  '"1111111111","100 MAIN ST, DENVER, CO, 80202","Match","Exact","100 MAIN ST, DENVER, CO, 80202","-104.991,39.742","12345","L"',
  '"2222222222","NOWHERE, XX","No_Match"'
), fixture)
parsed <- read_census_batch_result(fixture)
unlink(fixture)

# flowhelper-census-match-filter-removed
chk(nrow(parsed) == 1L && parsed$npi[1] == "1111111111",
    "F1 a No_Match row is excluded, not carried through with a phantom or NA coordinate")
# flowhelper-census-lonlat-swapped
chk(parsed$lon[1] < -100 && parsed$lat[1] > 30,
    "F2 lon/lat are unpacked in the order the Census API returns them (lon first, negative for CONUS), not swapped")

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
