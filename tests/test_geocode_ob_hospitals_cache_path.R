#!/usr/bin/env RScript
# =============================================================================
# R/13-geocode-ob-hospitals.R: the isochrones cache path is configurable and
# the missing-input failure is explicit
# =============================================================================
# Spec Part 5.3: no implicit access to a developer-specific home directory,
# a documented input contract, an explicit error when the input is absent,
# and path-independent tests via temporary directories.
#
# The script resolves the isochrones checkout through isochrones_home()
# (ISOCHRONES_HOME env var, else ~/isochrones) and derives the DuckDB cache
# path from it. Before this change the cache path was the literal string
# "/Users/tylermuffly/isochrones/...", which no other machine could satisfy.
#
# Run: Rscript tests/test_geocode_ob_hospitals_cache_path.R
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
setwd(root)

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(cli); library(jsonlite)
  library(DBI); library(duckdb)
})

# Source into a private environment so the script's top-level assignments do
# not leak into the test session, and so its bottom-of-file run_geocode()
# guard (globalenv check) cannot fire.
e <- new.env(parent = globalenv())
sys.source(file.path("R", "13-geocode-ob-hospitals.R"), envir = e)

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

cat("\n-- cache path resolution --\n")

td <- file.path(tempdir(), paste0("iso_home_", as.integer(stats::runif(1) * 1e9)))
dir.create(file.path(td, "data"), recursive = TRUE, showWarnings = FALSE)

old <- Sys.getenv("ISOCHRONES_HOME", unset = "")
on.exit({
  if (nzchar(old)) Sys.setenv(ISOCHRONES_HOME = old) else Sys.unsetenv("ISOCHRONES_HOME")
}, add = TRUE)

Sys.setenv(ISOCHRONES_HOME = td)
# Re-source under the override: CACHE is computed at source time.
e2 <- new.env(parent = globalenv())
sys.source(file.path("R", "13-geocode-ob-hospitals.R"), envir = e2)

chk(identical(e2$CACHE, file.path(td, "data", "geocoding_cache.duckdb")),
    "CACHE derives from ISOCHRONES_HOME, not a hardcoded home directory")
chk(!grepl("/Users/", e2$CACHE, fixed = TRUE),
    "no developer-home path survives in CACHE")

cat("\n-- missing input fails closed --\n")

err <- tryCatch({ e2$run_geocode(); NULL }, error = function(x) conditionMessage(x))
chk(!is.null(err) && grepl("ISOCHRONES_HOME", err),
    "run_geocode() with no cache file errors naming ISOCHRONES_HOME")
chk(!is.null(err) && grepl("geocoding_cache.duckdb", err),
    "the error names the missing input contract")

cat("\n-- present-but-empty cache reaches the next gate --\n")

file.create(file.path(td, "data", "geocoding_cache.duckdb"))
e3 <- new.env(parent = globalenv())
sys.source(file.path("R", "13-geocode-ob-hospitals.R"), envir = e3)
err2 <- tryCatch({ e3$run_geocode(); NULL }, error = function(x) conditionMessage(x))
# The cache check must PASS (file exists) and the failure must come from the
# NEXT gate -- the isochrones R stack, which a temp dir does not have. If the
# cache error fired instead, the check is in the wrong place.
chk(!is.null(err2) && grepl("Canonical geocoding functions", err2),
    "with the cache file present, the cache check passes and the isochrones-stack gate fires next")

cat(sprintf("\n%s (%d failure%s)\n", if (fails) "FAIL" else "PASS", fails,
            if (fails == 1L) "" else "s"))
quit(status = if (fails) 1L else 0L)
