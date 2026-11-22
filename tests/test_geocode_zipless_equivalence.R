#!/usr/bin/env Rscript
# =============================================================================
# The extracted zip-less collapse must match the pipelines it replaced
# =============================================================================
# WHY THIS EXISTS. drop_zip() and the deterministic collapse after it were
# written twice -- geocode_midwives.R and geocode_panel_addresses.R, in
# near-identical dplyr pipelines that differed only in which columns break a
# tie and what the outputs were called. They now call
# collapse_zipless_key() in R/lib/geocode_conflicts.R.
#
# Neither of those scripts can run in CI: both need a geocoding cache DuckDB
# that is gitignored by design. So the refactor cannot be verified by running
# the thing it changed, and "the tests still pass" would mean nothing, because
# no test covered those twenty lines in the first place.
#
# What CAN be verified is EQUIVALENCE: run the old pipeline and the new helper
# over the same synthetic cache and require identical output, including row
# order. That is what this file does, and it is the only evidence the
# extraction preserved behaviour.
#
# THE FIXTURE IS THE HARD PART. The first version of this check assigned a
# random coordinate to every row, so every key had disagreeing coordinates,
# resolve_geocode_key() refused all of them, and both sides returned ZERO rows
# -- "identical: TRUE" over nothing at all. A vacuous pass is worse than a
# failure because it looks like evidence. The fixture below gives each key ONE
# coordinate and several rows of DIFFERING METADATA, which is the real shape
# (the same address geocoded more than once), so the coordinate agrees and what
# is left to choose is the metadata row. Ten keys get a second, far-away
# coordinate so the refused path is exercised too, and the rows are shuffled
# because row order must not matter.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr)})
source(file.path(root, "R", "lib", "geocode_conflicts.R"))
SAB_PREFIX <- "Q"

set.seed(11)
keys <- sprintf("st%02d|city|CO", 1:60)
base <- data.frame(key_nozip = keys,
                   lat0 = round(39 + seq_along(keys) / 1000, 4),
                   lon0 = round(-105 + seq_along(keys) / 1000, 4),
                   stringsAsFactors = FALSE)
rows <- do.call(rbind, lapply(seq_len(nrow(base)), function(i) {
  reps <- sample(1:4, 1)
  data.frame(
    key_nozip = base$key_nozip[i],
    latitude = base$lat0[i], longitude = base$lon0[i],
    quality_score = sample(c(1, 5, 9, 9, NA), reps, replace = TRUE),
    geocoder_provenance = sample(c("census", "osm", NA), reps, replace = TRUE),
    census_tract = sample(c("08031001100", "08031001200", NA), reps, replace = TRUE),
    county_fips = sample(c("08031", "08005"), reps, replace = TRUE),
    stringsAsFactors = FALSE)
}))
far <- rows[rows$key_nozip %in% keys[1:10], ][1:10, ]
far$latitude <- far$latitude + 3; far$longitude <- far$longitude - 3
cache <- rbind(rows, far)
cache <- cache[sample(nrow(cache)), ]
rownames(cache) <- NULL
resolved <- resolve_geocode_key(cache$key_nozip, cache$latitude,
                                cache$longitude, cache$quality_score)

# The pipeline both scripts used to carry inline, parameterised only by the
# tiebreak columns each one happened to order by.
old_collapse <- function(cache_rows, res, tiebreak) {
  out <- cache_rows %>%
    inner_join(res %>% filter(!is.na(lat)) %>%
                 select(key_nozip = key, .lat = lat, .lon = lon),
               by = "key_nozip") %>%
    filter(latitude == .lat, longitude == .lon)
  out <- out %>%
    arrange(across(all_of(c("key_nozip"))), desc(quality_score),
            across(all_of(tiebreak))) %>%
    group_by(key_nozip) %>% slice(1) %>% ungroup() %>%
    select(all_of(c("key_nozip", "latitude", "longitude", "quality_score",
                    tiebreak)))
  as.data.frame(out)
}

# frames_equal, not same: tests/test_address_key_reduction_exact.R
# defines same() at top level and ci_hygiene H4 refuses one name in
# two tracked files.
frames_equal <- function(a, b) {
  a <- as.data.frame(a); b <- as.data.frame(b)
  rownames(a) <- NULL; rownames(b) <- NULL
  isTRUE(all.equal(a, b, check.attributes = FALSE))
}

sab(1, "the fixture is not vacuous")
{
  settled <- sum(!is.na(resolved$lat))
  chk(settled > 0L && settled < nrow(resolved),
      sprintf("some keys resolve and some are refused [%d of %d resolved]",
              settled, nrow(resolved)))
  kept <- collapse_zipless_key(cache, resolved, "geocoder_provenance")
  chk(nrow(kept) > 0L,
      sprintf("and the collapse returns rows to compare [%d]", nrow(kept)))
  chk(nrow(kept) == settled,
      sprintf("one row per resolved key, no more and no fewer [%d of %d]",
              nrow(kept), settled))
}

sab(2, "geocode_midwives.R's collapse is unchanged")
{
  chk(frames_equal(old_collapse(cache, resolved, "geocoder_provenance"),
           collapse_zipless_key(cache, resolved, "geocoder_provenance")),
      "identical output, row order included, breaking ties on provenance")
}

sab(3, "geocode_panel_addresses.R's collapse is unchanged")
{
  tb <- c("census_tract", "county_fips")
  chk(frames_equal(old_collapse(cache, resolved, tb),
           collapse_zipless_key(cache, resolved, tb)),
      "identical output breaking ties on tract then county")
}

sab(4, "a refused key contributes nothing, rather than its first row")
{
  refused_keys <- resolved$key[is.na(resolved$lat)]
  kept <- collapse_zipless_key(cache, resolved, "geocoder_provenance")
  chk(length(refused_keys) > 0L,
      sprintf("the fixture refuses some keys [%d]", length(refused_keys)))
  chk(!any(kept$key_nozip %in% refused_keys),
      "and none of them appears in the output")
}

sab(5, "the surviving row is the one the resolver settled on")
{
  # The defect this guards: a row filed under the key but carrying a DIFFERENT
  # coordinate must not supply the metadata. The ten far-away rows exist to
  # make that reachable.
  kept <- collapse_zipless_key(cache, resolved, "geocoder_provenance")
  at <- match(kept$key_nozip, resolved$key)
  chk(all(kept$latitude == resolved$lat[at] &
            kept$longitude == resolved$lon[at]),
      "every kept row carries the resolved coordinate, not merely some coordinate")
}

sab(6, "row order in the cache cannot change the answer")
{
  shuffled <- cache[sample(nrow(cache)), ]
  rownames(shuffled) <- NULL
  res2 <- resolve_geocode_key(shuffled$key_nozip, shuffled$latitude,
                              shuffled$longitude, shuffled$quality_score)
  a <- collapse_zipless_key(cache, resolved, "geocoder_provenance")
  b <- collapse_zipless_key(shuffled, res2, "geocoder_provenance")
  chk(frames_equal(a, b), "a reshuffled cache collapses to the same rows")
}

sab(7, "a partial tiebreak ordering is refused, not silently accepted")
{
  # Without every tiebreak column the ordering is partial and the surviving row
  # depends on row order -- the exact defect the original comment in both
  # scripts says this logic exists to prevent.
  missing_col <- tryCatch({
    collapse_zipless_key(cache[, setdiff(names(cache), "census_tract")],
                         resolved, c("census_tract", "county_fips"))
    "ACCEPTED"
  }, error = function(e) conditionMessage(e))
  chk(grepl("census_tract", missing_col, fixed = TRUE),
      "a cache missing a named tiebreak column is an error")
  empty_tb <- tryCatch({
    collapse_zipless_key(cache, resolved, character(0))
    "ACCEPTED"
  }, error = function(e) conditionMessage(e))
  chk(grepl("row order", empty_tb, fixed = TRUE),
      "and an empty tiebreak is refused, naming what would decide instead")
}

sab(8, "INVERTED: drop_zip strips exactly one trailing field")
{
  chk(identical(drop_zip("123 MAIN|DENVER|CO|80202"), "123 MAIN|DENVER|CO"),
      "the ZIP field comes off")
  chk(identical(drop_zip("123 MAIN|DENVER|CO|80202-1234"),
                "123 MAIN|DENVER|CO"),
      "including a 9-digit ZIP, which is why both sides must strip identically")
  chk(identical(drop_zip("nopipe"), "nopipe"),
      "a key with no pipe is returned unchanged rather than emptied")
}

saboteur_report(8)
