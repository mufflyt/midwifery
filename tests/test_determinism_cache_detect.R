#!/usr/bin/env Rscript
# =============================================================================
# Do L8 and L9 detect the ways determinism and caching actually break?
# =============================================================================
# Six mutations, each planted in production code and each attributable to ONE
# law. A mutation that merely crashes some unrelated test is not evidence the
# law works, so every case asserts the defect is caught AND that the right law
# caught it.
#
#   L8  a tie resolved by row order
#   L8  an aggregation decided by chunk boundary
#   L8  an answer that depends on filesystem enumeration order
#   L9  stale cache content overriding a fresh computation
#   L9  a cache key that omits a scientifically relevant input
#   L9  a partial record counted as complete
# =============================================================================

EVIDENCE_SOURCE <- "tests/test_determinism_cache_detect.R"

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

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)

L8 <- file.path(root, "tests", "test_deterministic_rebuild.R")
L9 <- file.path(root, "tests", "test_cache_isolation.R")
stopifnot(file.exists(L8), file.exists(L9))
# osmde_cache.R sources resume_state.R at load time. Copied rather than stubbed:
# a stub would be a second top-level definition of a canonical helper, which is
# exactly what H4 exists to prevent, and it would mean the scaffold tested the
# stub instead of the code.
NEEDED <- c("R/lib/common_helpers.R", "R/lib/zip_county_crosswalk.R",
            "R/lib/osmde_cache.R", "R/lib/resume_state.R",
            "data/zcta_county_2020.txt")

caught <- 0L; planted <- 0L; problems <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) cat(sprintf("  ok   %s\n", m))
  else { problems <<- c(problems, m); cat(sprintf("  FAIL %s\n", m)) } }

dc_scaffold <- function(dir) {
  for (d in c("tests", "R/lib", "data")) dir.create(file.path(dir, d), recursive = TRUE, showWarnings = FALSE)
  file.copy(L8, file.path(dir, "tests", "test_deterministic_rebuild.R"))
  file.copy(L9, file.path(dir, "tests", "test_cache_isolation.R"))
  for (f in NEEDED) file.copy(file.path(root, f), file.path(dir, f))
  dir.create(file.path(dir, ".git"), showWarnings = FALSE)
}

dc_run <- function(which_law, edits = list()) {
  dir <- file.path(tempdir(), paste0("dc_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  dc_scaffold(dir)
  for (nm in names(edits)) writeLines(edits[[nm]], file.path(dir, nm))
  target <- if (which_law == "L8") "tests/test_deterministic_rebuild.R" else "tests/test_cache_isolation.R"
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript %s 2>&1", shQuote(dir), shQuote(target)))),
    stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

kills <- function(law, id, label, edits) {
  planted <<- planted + 1L
  r <- dc_run(law, edits)
  if (r$failed) caught <<- caught + 1L
  cat(sprintf("[MUTATION] %s %s %s\n", law, id, if (r$failed) "DETECTED" else "SURVIVED"))
  chk(r$failed, sprintf("%s  %s", law, label))
  if (!r$failed) cat("       the law passed; the mutation survived\n")
}

cat("\n-- both laws pass unmutated --\n")
r8 <- dc_run("L8"); chk(!r8$failed, "L8 clean scaffold")
if (r8$failed) cat(substr(r8$text, 1, 900), "\n")
r9 <- dc_run("L9"); chk(!r9$failed, "L9 clean scaffold")
if (r9$failed) cat(substr(r9$text, 1, 900), "\n")

cat("\n-- L8: determinism --\n")

# A tie -- and any near-tie -- resolved by whichever row arrived first.
kills("L8", "tie-broken-by-row-order", "a tie resolved by input row order",
  list("R/lib/zip_county_crosswalk.R" = c(
    "assert_no_na_key <- function(d, key, what) invisible(d)",
    "zcta_county_parts <- function(path) {",
    "  d <- readr::read_delim(path, delim = '|', show_col_types = FALSE, progress = FALSE)",
    "  d <- d[!is.na(d$GEOID_ZCTA5_20) & !is.na(d$GEOID_COUNTY_20), ]",
    "  data.frame(zip5 = pad5(d$GEOID_ZCTA5_20), GEOID = pad5(d$GEOID_COUNTY_20),",
    "             land = suppressWarnings(as.numeric(d$AREALAND_PART)))",
    "}",
    "zip_county_dominant <- function(path) {",
    "  p <- zcta_county_parts(path)",
    "  p[!duplicated(p$zip5), c('zip5','GEOID')]",   # first row wins, not largest land
    "}")))

# The band a location is assigned depends on which chunk it landed in.
kills("L8", "chunk-boundary-decides-aggregation", "a chunk boundary changing the answer",
  list("R/lib/osmde_cache.R" = c(
    readLines(file.path(root, "R/lib/osmde_cache.R"))[
      1:(grep("^osmde_assemble <- function", readLines(file.path(root, "R/lib/osmde_cache.R"))) - 1)],
    "osmde_assemble <- function(cache_dir, chunk = 500L, verbose = TRUE) {",
    "  keys <- osmde_cache_keys(cache_dir)",
    "  if (!length(keys)) stop('cache is empty: ', cache_dir)",
    "  out <- lapply(seq_along(keys), function(i) {",
    "    e <- osmde_cache_get(cache_dir, keys[i]); if (is.null(e)) return(NULL)",
    "    g <- e$sf; bcol <- intersect(c('contour','time'), names(g))[1]",
    "    if (is.na(bcol)) return(NULL)",
    "    cc <- as.numeric(strsplit(keys[i], '_', fixed = TRUE)[[1]])",
    "    sf::st_sf(location_key = keys[i], center_lat = cc[1], center_lng = cc[2],",
    "      drive_time_minutes = as.numeric(g[[bcol]]) + (i %% chunk == 0),",
    "      routing_engine = 'x', routing_scope = 'x', osm_vintage = NA_character_,",
    "      costing = 'auto', generated_utc = e$fetched_utc, geometry = sf::st_geometry(g))",
    "  })",
    "  do.call(rbind, out[!vapply(out, is.null, logical(1))])",
    "}")))

# The answer follows whatever order the filesystem hands back.
kills("L8", "enumeration-order-decides-answer", "an answer that follows filesystem order",
  list("R/lib/osmde_cache.R" = c(
    readLines(file.path(root, "R/lib/osmde_cache.R")),
    "osmde_cache_keys <- function(cache_dir) {",
    "  if (!dir.exists(cache_dir)) return(character(0))",
    "  k <- sub('\\\\.rds$', '', list.files(cache_dir, pattern = '\\\\.rds$'))",
    "  k[-1]",   # silently drops whichever key enumerated first
    "}")))

cat("\n-- L9: cache isolation --\n")

# A cached value that cannot be validated is used anyway.
kills("L9", "stale-content-overrides-computation", "an unvalidated cached value used anyway",
  list("R/lib/osmde_cache.R" = c(
    readLines(file.path(root, "R/lib/osmde_cache.R")),
    "osmde_cache_get <- function(cache_dir, key) {",
    "  p <- osmde_cache_path(cache_dir, key)",
    "  if (!file.exists(p)) return(NULL)",
    "  x <- tryCatch(readRDS(p), error = function(e) NULL)",
    "  if (is.null(x)) return(NULL)",
    "  if (inherits(x, 'sf')) return(list(sf = x, fetched_utc = NA_character_))",
    "  if (is.list(x) && inherits(x$sf, 'sf')) return(x)",
    "  list(sf = sf::st_sf(contour = 30, geometry = sf::st_sfc(sf::st_polygon(",
    "    list(rbind(c(0,0), c(1,0), c(1,1), c(0,1), c(0,0)))), crs = 4326)),",
    "    fetched_utc = NA_character_)",   # a fabricated answer for a bad entry
    "}")))

# A partial record counted as complete.
kills("L9", "partial-record-counted-complete", "a truncated entry treated as usable",
  list("R/lib/osmde_cache.R" = c(
    readLines(file.path(root, "R/lib/osmde_cache.R")),
    "osmde_cache_get <- function(cache_dir, key) {",
    "  p <- osmde_cache_path(cache_dir, key)",
    "  if (!file.exists(p)) return(NULL)",
    "  x <- tryCatch(readRDS(p), error = function(e)",
    "    sf::st_sf(contour = 30, geometry = sf::st_sfc(sf::st_polygon(",
    "      list(rbind(c(0,0), c(1,0), c(1,1), c(0,1), c(0,0)))), crs = 4326)))",
    "  if (inherits(x, 'sf')) return(list(sf = x, fetched_utc = NA_character_))",
    "  if (is.list(x) && inherits(x$sf, 'sf')) return(x)",
    "  NULL",
    "}")))

# A key that ignores part of what determines the answer: every location
# collapses onto one cache slot.
kills("L9", "cache-key-omits-relevant-input", "a cache key that omits a relevant input",
  list("R/lib/osmde_cache.R" = c(
    readLines(file.path(root, "R/lib/osmde_cache.R")),
    "osmde_cache_path <- function(cache_dir, key) file.path(cache_dir, 'shared.rds')")))

cat(sprintf("\n%d/%d determinism and cache mutations detected\n", caught, planted))
if (length(problems)) {
  cat(sprintf("\nFAILED (%d)\n", length(problems)))
  for (f in problems) cat(sprintf("  - %s\n", f)); quit(status = 1)
}
cat("PASS (0 failures)\n")
