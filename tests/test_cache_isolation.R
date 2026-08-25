#!/usr/bin/env Rscript
# =============================================================================
# L9: a cache may change how long an answer takes, never what the answer is
# =============================================================================
# THE LAW
#
#   f(X, C) = f(X) for every cache state C -- empty, warm, reordered, polluted
#   with irrelevant entries, or holding something stale or corrupt.
#
#   And it is FAIL-CLOSED: a cached value that cannot be validated must be
#   rejected and recomputed, or reported unavailable. It may never be
#   substituted silently for the right answer.
#
# The subject is R/lib/osmde_cache.R, this repository's own file-backed cache
# for routed isochrones -- production code, publicly testable, no person-level
# data. Entries are synthetic sf polygons built here.
#
# BOTH CONTROLS, and the positive one is the load-bearing half. A pipeline that
# ignored its cache entirely would satisfy every invariance assertion below
# while being completely broken. So this also proves the cache IS consulted:
# remove an entry and the answer must change.
#
# WHAT THIS DOES NOT COVER, stated rather than implied. The geocoding cache that
# feeds practice coordinates is a 49.5 MB DuckDB owned by the isochrones project
# (R/13-geocode-ob-hospitals.R line 67), opened read-only here. It is not
# reachable from a public runner, and -- separately and more seriously -- it is
# declared in no artifact's provenance: across every sidecar in artifacts/ there
# are 105 distinct declared inputs and not one is a cache.
#
# So for the geocoding path the pipeline computes Y = f(X, whatever the cache
# holds now) while its provenance records only X. A rerun against a grown cache
# yields different geography with identical declared inputs. That is not
# nondeterminism to be tested away; it is an undeclared scientific input, and
# the fix is to record the cache's identity alongside the others. No such law is
# registered yet -- deliberately, rather than referring to one that does not
# exist. This law governs the cache this repository owns.
# =============================================================================

EVIDENCE_SOURCE <- "tests/test_cache_isolation.R"

# EVIDENCE CUSTODY. Stamps this run with what it is evidence FOR -- the file's
# own content hash, the registry's, and the commit -- so tests/ci_law_coverage.R
# can prove a replayed log belongs to the evaluation it is being used for
# instead of trusting its filename. The helper is sourced, never re-declared:
# two copies of a custody check are two things that can disagree.
local({
  r <- file.path(getwd(), "tests", "ci_report.R")
  if (file.exists(r)) {
    e <- new.env(); sys.source(r, envir = e)
    e$ci_law_evidence_header(EVIDENCE_SOURCE)
  }
})

suppressPackageStartupMessages({ library(dplyr); library(sf) })
sf::sf_use_s2(FALSE)

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "osmde_cache.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
n_pos <- 0L; n_neg <- 0L

band_poly <- function(lat, lng, band) sf::st_sf(
  contour = band,
  geometry = sf::st_sfc(sf::st_polygon(list(rbind(
    c(lng, lat), c(lng + .01, lat), c(lng + .01, lat + .01),
    c(lng, lat + .01), c(lng, lat)))), crs = 4326))

fresh_cache <- function(n = 12L) {
  d <- file.path(tempdir(), paste0("iso_", as.integer(stats::runif(1) * 1e9)))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(n))
    osmde_cache_put(d, sprintf("%.6f_%.6f", 39 + i / 100, -104 - i / 100),
                    band_poly(39 + i / 100, -104 - i / 100, if (i %% 2) 30 else 60),
                    "2026-01-01T00:00:00")
  d
}
answer <- function(d) {
  x <- suppressMessages(osmde_assemble(d, chunk = 500L, verbose = FALSE))
  x <- sf::st_drop_geometry(x)
  x <- x[order(x$location_key, x$drive_time_minutes), , drop = FALSE]
  rownames(x) <- NULL
  x
}

base_dir <- fresh_cache(); base <- answer(base_dir)

# --- 1. an empty cache -------------------------------------------------------
cat("\n-- an empty cache is reported, not silently answered --\n")
empty <- file.path(tempdir(), "iso_empty"); unlink(empty, recursive = TRUE); dir.create(empty)
n_neg <- n_neg + 1L
chk(inherits(try(osmde_assemble(empty, verbose = FALSE), silent = TRUE), "try-error"),
    "assembling an empty cache raises rather than returning an empty answer")
n_neg <- n_neg + 1L
chk(length(osmde_cache_keys(empty)) == 0L, "and it reports zero keys")
n_neg <- n_neg + 1L
chk(is.null(osmde_cache_get(empty, "39.010000_-104.010000")),
    "a miss returns NULL rather than a fabricated entry")

# --- 2. a warm cache, and the same entries written in another order ----------
cat("\n-- the answer does not depend on the cache's write order --\n")
reordered <- file.path(tempdir(), "iso_rev"); unlink(reordered, recursive = TRUE); dir.create(reordered)
for (k in rev(osmde_cache_keys(base_dir)))
  file.copy(osmde_cache_path(base_dir, k), osmde_cache_path(reordered, k))
n_neg <- n_neg + 1L
chk(identical(answer(reordered), base), "entries written in reverse order give the same answer")

# --- 3. irrelevant entries -----------------------------------------------
cat("\n-- irrelevant cache entries do not change the answer for real keys --\n")
polluted <- file.path(tempdir(), "iso_poll"); unlink(polluted, recursive = TRUE); dir.create(polluted)
for (k in osmde_cache_keys(base_dir))
  file.copy(osmde_cache_path(base_dir, k), osmde_cache_path(polluted, k))
for (i in 1:5)  # entries for locations nothing asks about
  osmde_cache_put(polluted, sprintf("%.6f_%.6f", 10 + i, 20 + i),
                  band_poly(10 + i, 20 + i, 30), "2026-01-01T00:00:00")
pol <- answer(polluted)
# Rownames are reset after subsetting. The first version compared the subset
# directly and failed on rownames alone -- a difference in row LABELS, which is
# metadata, not science. Canonicalising that away is legitimate here for exactly
# the reason canonicalising a coordinate would not be.
pol_sub <- pol[pol$location_key %in% base$location_key, , drop = FALSE]
rownames(pol_sub) <- NULL
n_neg <- n_neg + 1L
chk(all(base$location_key %in% pol$location_key) && identical(pol_sub, base),
    "five unrelated entries leave every original row untouched")

# --- 4. corrupt, partial and incompatible entries: FAIL CLOSED ---------------
cat("\n-- an unusable cached value is rejected, never substituted --\n")
corrupt <- file.path(tempdir(), "iso_corrupt"); unlink(corrupt, recursive = TRUE); dir.create(corrupt)
for (k in osmde_cache_keys(base_dir))
  file.copy(osmde_cache_path(base_dir, k), osmde_cache_path(corrupt, k))
victim <- osmde_cache_keys(corrupt)[1]

writeLines("this is not an RDS file", osmde_cache_path(corrupt, victim))
n_neg <- n_neg + 1L
chk(is.null(osmde_cache_get(corrupt, victim)), "a corrupt entry reads as NULL, not as garbage")

con <- file(osmde_cache_path(corrupt, victim), "wb")
writeBin(head(readBin(osmde_cache_path(base_dir, victim), "raw", 4000), 40), con); close(con)
n_neg <- n_neg + 1L
chk(is.null(osmde_cache_get(corrupt, victim)), "a truncated entry reads as NULL, not as partial")

saveRDS(data.frame(nothing = 1), osmde_cache_path(corrupt, victim))
n_neg <- n_neg + 1L
chk(is.null(osmde_cache_get(corrupt, victim)),
    "an entry of the wrong shape reads as NULL, not as an answer")

saveRDS(sf::st_sf(unexpected = 1,
                  geometry = sf::st_sfc(sf::st_point(c(0, 0)), crs = 4326)),
        osmde_cache_path(corrupt, victim))
res <- suppressMessages(osmde_assemble(corrupt, chunk = 500L, verbose = FALSE))
n_neg <- n_neg + 1L
chk(!(victim %in% res$location_key),
    "an entry with no recognisable band column is dropped, not guessed at")

# --- 5. POSITIVE CONTROL: the cache is genuinely consulted -------------------
cat("\n-- positive control: the cache is actually being read --\n")
short <- file.path(tempdir(), "iso_short"); unlink(short, recursive = TRUE); dir.create(short)
ks <- osmde_cache_keys(base_dir)
for (k in ks[-1]) file.copy(osmde_cache_path(base_dir, k), osmde_cache_path(short, k))
n_pos <- n_pos + 1L
chk(!identical(answer(short), base) && !(ks[1] %in% answer(short)$location_key),
    "removing one entry removes exactly that location from the answer")

n_pos <- n_pos + 1L
chk(nrow(base) > 0L && all(c("location_key", "drive_time_minutes") %in% names(base)),
    "and the warm answer is non-empty and carries the scientific columns")

changed <- file.path(tempdir(), "iso_changed"); unlink(changed, recursive = TRUE); dir.create(changed)
for (k in ks) file.copy(osmde_cache_path(base_dir, k), osmde_cache_path(changed, k))
kk <- ks[2]; cc <- as.numeric(strsplit(kk, "_", fixed = TRUE)[[1]])
osmde_cache_put(changed, kk, band_poly(cc[1], cc[2], 120), "2026-01-01T00:00:00")
n_pos <- n_pos + 1L
chk(!identical(answer(changed), base),
    "changing an entry's band changes the answer (the value is read, not the key alone)")

cat("\n")
cat("[LAW] L9 EXERCISED\n")
cat(sprintf("[CONTROL] L9 negative n=%d\n", n_neg))
cat(sprintf("[CONTROL] L9 positive n=%d\n", n_pos))
if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
