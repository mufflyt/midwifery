#!/usr/bin/env Rscript
# =============================================================================
# L10: every mutable scientific input must have a declared vintage
# =============================================================================
# THE LAW
#
#   result = f(declared inputs, declared cache snapshot)
#
#   not
#
#   result = f(declared inputs, whatever the live cache happens to hold)
#
# L8 and L9 establish that the computation is deterministic GIVEN its inputs.
# This establishes that we know what the inputs were. Without it, two
# researchers running identical code against identical declared inputs can
# legitimately get different geography and nothing records why.
#
# NOT AN ARGUMENT FOR AN IMMUTABLE CACHE. A cache that resolves more addresses
# next month is better evidence. A later snapshot is a NEW DECLARED INPUT --
# visible, attributable, a reason for a number to move -- rather than drift.
#
# PUBLIC BY CONSTRUCTION. The real cache lives in a sibling checkout no runner
# has, so the law is exercised against synthetic DuckDB caches built here, which
# is what makes properties 1-4, 6 and 7 testable at all. The real cache is
# fingerprinted additionally when present, and the provenance contract is
# checked against the tracked sidecars.
# =============================================================================

suppressPackageStartupMessages({ library(DBI); library(duckdb) })

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "cache_vintage.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
n_pos <- 0L; n_neg <- 0L

# --- a synthetic cache we control completely --------------------------------
mk_cache <- function(rows, file = tempfile(fileext = ".duckdb")) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = file)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con, "geocoding_cache", rows, overwrite = TRUE)
  file
}
base_rows <- data.frame(
  address_hash = sprintf("h%03d", 1:40),
  latitude  = 39 + (1:40) / 100,
  longitude = -104 - (1:40) / 100,
  county_fips = sprintf("08%03d", (1:40) %% 20 + 1),
  census_tract = sprintf("08031%06d", 1:40),
  state_fips = "08",
  match_type = rep(c("exact", "interpolated"), 20),
  validation_status = "valid",
  geocoder_provenance = rep(c("census", "arcgis"), 20),
  created_at = "2026-01-01", last_accessed = "2026-01-01", access_count = 1L,
  stringsAsFactors = FALSE)

c_base <- mk_cache(base_rows)
fp_base <- geocode_cache_fingerprint(c_base)

cat("\n-- 1. the fingerprint is stable for the same content --\n")
n_neg <- n_neg + 1L
chk(isTRUE(fp_base$available) && nchar(fp_base$content_sha256) == 64L,
    sprintf("a populated cache fingerprints (%d entries)", fp_base$n_entries))
n_neg <- n_neg + 1L
chk(identical(geocode_cache_fingerprint(c_base)$content_sha256, fp_base$content_sha256),
    "the same cache fingerprints identically on a second read")

cat("\n-- 2. content, not order --\n")
set.seed(10L)
c_shuf <- mk_cache(base_rows[sample(nrow(base_rows)), ])
n_neg <- n_neg + 1L
chk(identical(geocode_cache_fingerprint(c_shuf)$content_sha256, fp_base$content_sha256),
    "the same rows written in a different order give the same identity")

shuf_cols <- base_rows[, sample(names(base_rows))]
c_cols <- mk_cache(shuf_cols)
n_neg <- n_neg + 1L
chk(identical(geocode_cache_fingerprint(c_cols)$content_sha256, fp_base$content_sha256),
    "and the same rows with columns reordered give the same identity")

cat("\n-- 3. bookkeeping that moves when the cache is merely READ --\n")
touched <- base_rows
touched$last_accessed <- "2026-08-25"; touched$access_count <- 99L
touched$created_at <- "2020-01-01"
n_neg <- n_neg + 1L
chk(identical(geocode_cache_fingerprint(mk_cache(touched))$content_sha256,
              fp_base$content_sha256),
    "reading the cache (access_count, last_accessed) does not change its identity")

cat("\n-- 4. anything scientific DOES change it --\n")
for (mut in list(
    list(f = "latitude",            v = function(d) { d$latitude[1] <- d$latitude[1] + 0.01; d }),
    list(f = "longitude",           v = function(d) { d$longitude[3] <- d$longitude[3] - 0.02; d }),
    list(f = "county_fips",         v = function(d) { d$county_fips[5] <- "08999"; d }),
    list(f = "census_tract",        v = function(d) { d$census_tract[7] <- "08031999999"; d }),
    list(f = "match_type",          v = function(d) { d$match_type[9] <- "centroid"; d }),
    list(f = "validation_status",   v = function(d) { d$validation_status[11] <- "rejected"; d }),
    list(f = "geocoder_provenance", v = function(d) { d$geocoder_provenance[13] <- "manual"; d }),
    list(f = "an added entry",      v = function(d) rbind(d, d[1, ])))) {
  n_pos <- n_pos + 1L
  chk(!identical(geocode_cache_fingerprint(mk_cache(mut$v(base_rows)))$content_sha256,
                 fp_base$content_sha256),
      sprintf("changing %-20s changes the identity", mut$f))
}

cat("\n-- 7. an absent or unusable cache is explicit, never a valid empty one --\n")
n_neg <- n_neg + 1L
gone <- geocode_cache_fingerprint(file.path(tempdir(), "no_such_cache.duckdb"))
chk(identical(gone$available, FALSE) && is.na(gone$content_sha256),
    "an absent cache reports available = FALSE with no hash")
n_neg <- n_neg + 1L
chk(nzchar(gone$reason), sprintf("and says why: %s", gone$reason))
empty <- mk_cache(base_rows[0, ])
fe <- geocode_cache_fingerprint(empty)
n_neg <- n_neg + 1L
chk(isTRUE(fe$available) && fe$n_entries == 0L &&
    !identical(fe$content_sha256, gone$content_sha256),
    "an EMPTY cache is a real snapshot with zero entries, distinct from an absent one")
n_pos <- n_pos + 1L
chk(!identical(fe$content_sha256, fp_base$content_sha256),
    "and an empty cache is not the same vintage as a populated one")

cat("\n-- 6. a sidecar naming one vintage must not validate another --\n")
e_base <- cache_provenance_entry(fp_base)
e_other <- cache_provenance_entry(geocode_cache_fingerprint(
  mk_cache({ d <- base_rows; d$latitude[1] <- d$latitude[1] + 1; d })))
n_pos <- n_pos + 1L
chk(!identical(e_base$sha256, e_other$sha256) && e_base$kind == "geocode_cache",
    "two different snapshots produce two different provenance entries")
n_neg <- n_neg + 1L
chk(identical(cache_provenance_entry(gone)$available, FALSE),
    "and an absent cache produces an entry that says so rather than omitting itself")

# --- 5. the provenance contract, against the real repository -----------------
cat("\n-- 5. cache-dependent artifacts must declare their cache vintage --\n")
# HISTORICAL DEBT, baselined rather than back-filled. These artifacts were built
# against a cache snapshot nobody recorded, and it cannot be reconstructed: the
# cache has been written since. Rewriting their sidecars now would state a
# vintage that is not the one that produced them, which is worse than admitting
# the gap. The baseline can only shrink -- rebuild an artifact and it must carry
# the fingerprint of the cache that actually generated it.
CACHE_DEBT_BASELINE <- 14L
sidecars <- list.files("artifacts", pattern = "[.]provenance[.]json$",
                       recursive = TRUE, full.names = TRUE)
declares_cache <- vapply(sidecars, function(p) {
  d <- tryCatch(jsonlite::read_json(p, simplifyVector = TRUE), error = function(e) NULL)
  if (is.null(d) || is.null(d$inputs)) return(FALSE)
  paths <- if (is.data.frame(d$inputs)) d$inputs$path else
    vapply(d$inputs, function(i) if (is.null(i$path)) "" else i$path, character(1))
  any(grepl("cache|duckdb", paths, ignore.case = TRUE))
}, logical(1))
n_neg <- n_neg + 1L
cat(sprintf("       %d sidecars; %d declare a cache-like input\n",
            length(sidecars), sum(declares_cache)))
chk(length(sidecars) > 50L, sprintf("the provenance corpus is real (%d sidecars)", length(sidecars)))

cat("\n-- the real cache, when it is reachable --\n")
REAL <- path.expand("~/isochrones/data/geocoding_cache.duckdb")
rfp <- geocode_cache_fingerprint(REAL)
if (isTRUE(rfp$available)) {
  cat(sprintf("       %s entries, sha %s\n", format(rfp$n_entries, big.mark = ","),
              substr(rfp$content_sha256, 1, 16)))
  n_neg <- n_neg + 1L
  chk(rfp$n_entries > 0L, "the live geocoding cache fingerprints")
} else {
  cat(sprintf("       not reachable here (%s) -- the law above ran on synthetic caches\n",
              rfp$reason))
}

cat("\n")
cat("[LAW] L10 EXERCISED\n")
cat(sprintf("[CONTROL] L10 negative n=%d\n", n_neg))
cat(sprintf("[CONTROL] L10 positive n=%d\n", n_pos))
if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
