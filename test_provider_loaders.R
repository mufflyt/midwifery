#!/usr/bin/env Rscript
# =============================================================================
# Contract tests for the obstetric provider loaders
# =============================================================================
# Run as: Rscript test_provider_loaders.R   (exit 1 on any failure)
#
# These lock in the two invariants that were violated before the general-OB
# geography correction, both of which produced wrong published numbers rather
# than errors -- which is exactly why they need tests instead of comments.
#
#   1. DENOMINATOR IS THE ROSTER, NOT THE GEOCODE FILE. The original loader
#      started from geocoded_general_obgyns_*.csv and so silently defined the
#      generalist population as "whoever happened to be geocoded" -- 28,512 of
#      50,556. Missingness became invisible because the missing were never in
#      the denominator. The loader must start from the full ABOG roster.
#
#   2. CITY CENTROIDS MUST FAIL CLOSED FOR TRAVEL TIME. A centroid is a valid
#      county/district locator and an invalid isochrone origin. Nothing stops a
#      future caller from passing the full generalist frame to a routing
#      function, so the guard has to be a function that refuses, not a note.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})

ISO <- path.expand("~/isochrones")
fails <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  PASS  %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); fails <<- fails + 1L }
}

source("load_obstetric_providers.R")

cat("--- 1. denominator is the full ABOG generalist roster ---\n")
roster_n <- read_csv(file.path(ISO, "canonical_abog_npi_LATEST.csv"),
                     show_col_types = FALSE) %>%
  filter(subspecialty == "Generalist") %>% distinct(npi) %>% nrow()
ok(roster_n == 50556,
   sprintf("roster is 50,556 generalists (found %s)", format(roster_n, big.mark = ",")))

g <- load_generalists(verbose = FALSE)
# The loader may legitimately return FEWER than the roster (missing coordinates,
# out-of-bbox, subspecialist overlap removed). What it must never do is return
# MORE, or return a count that tracks a geocode file rather than the roster.
ok(nrow(g) <= roster_n,
   sprintf("returns no more than the roster (%s <= %s)",
           format(nrow(g), big.mark = ","), format(roster_n, big.mark = ",")))
ok(nrow(g) > 0.95 * roster_n,
   sprintf("coverage exceeds 95%% of roster (%.1f%%)", 100 * nrow(g) / roster_n))
# Guards against silent regression to the old 28,512-row source.
ok(nrow(g) > 40000,
   sprintf("not the pre-correction geocode-file subset (%s rows)",
           format(nrow(g), big.mark = ",")))
ok(!any(duplicated(g$id)), "no duplicate NPIs")

cat("\n--- 2. generalists and subspecialists are disjoint ---\n")
s <- load_subspecialists()
ok(sum(g$id %in% s$id) == 0,
   sprintf("zero overlap with the subspecialist cohort (found %s)",
           sum(g$id %in% s$id)))

cat("\n--- 3. provenance survives ---\n")
ok("coord_source" %in% names(g), "coord_source column present")
ok(any(g$coord_source == "city_centroid"), "city_centroid rows are labelled")
ok(!any(is.na(g$coord_source)), "no NA coord_source")

cat("\n--- 4. city centroids fail closed for travel time ---\n")
# The guard itself. Any routing/isochrone caller must pass its input through
# this, and it must ERROR rather than filter, so a mistake is loud.
assert_travel_time_eligible <- function(df) {
  if ("usable_for_travel_time" %in% names(df) && any(!df$usable_for_travel_time))
    stop("travel-time analysis received rows flagged usable_for_travel_time = FALSE")
  if ("coord_source" %in% names(df) && any(grepl("centroid", df$coord_source)))
    stop("travel-time analysis received city-centroid coordinates: ",
         sum(grepl("centroid", df$coord_source)), " rows")
  invisible(TRUE)
}
threw <- inherits(try(assert_travel_time_eligible(g), silent = TRUE), "try-error")
ok(threw, "full generalist frame is REJECTED for travel time")

clean <- g %>% filter(!grepl("centroid", coord_source))
passed <- isTRUE(try(assert_travel_time_eligible(clean), silent = TRUE))
ok(passed, sprintf("centroid-free subset is accepted (%s rows)",
                   format(nrow(clean), big.mark = ",")))

cc <- read_csv("artifacts/generalist_residual_city_centroids.csv",
               show_col_types = FALSE)
ok(all(cc$usable_for_travel_time == FALSE),
   "residual centroid artifact is flagged usable_for_travel_time = FALSE")
ok(inherits(try(assert_travel_time_eligible(cc), silent = TRUE), "try-error"),
   "residual centroid artifact is REJECTED for travel time")

cat("\n--- 5. midwives unaffected ---\n")
mw <- load_midwives()
ok(nrow(mw) == 11792, sprintf("11,792 ACTIVE primary-linked midwives (found %s)",
                              format(nrow(mw), big.mark = ",")))

cat(sprintf("\n%s\n", strrep("=", 60)))
if (fails) {
  cat(sprintf("FAILED: %s assertion(s)\n", fails)); quit(status = 1)
}
cat("All provider-loader contracts hold.\n")
