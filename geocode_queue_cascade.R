#!/usr/bin/env Rscript
# =============================================================================
# Geocode the outstanding practice addresses with the isochrones 3-tier cascade
# =============================================================================
#
# 6,793 distinct practice addresses from the linked roster miss the shared
# geocoding cache, so their county can only come from the ZIP fallback. That
# shortfall is not evenly spread: completeness runs 32.7% metro, 27.6% nonmetro
# adjacent, 22.0% nonmetro remote -- a 10.8 pp monotonic gradient. Closing it
# is a bias correction, not merely a coverage gain, because rural counties are
# exactly where midwifery access questions are asked.
#
# Uses geocode_batch_with_3tier_cascade() from isochrones
# (R/geocode_with_3tier_cascade.R): Census -> ArcGIS -> city centroid, with
# every attempt logged to DuckDB and results written back to the shared
# persistent cache, so this work is not repeated by any later run.
#
# Input : artifacts/panel_geocode_queue.csv
# Output: artifacts/panel_geocode_results.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(sf)})

# dplyr exports %||% in recent versions; define only if absent.
if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a

ISO <- Sys.getenv("ISOCHRONES_DIR", path.expand("~/isochrones"))
QUEUE <- Sys.getenv("GEOCODE_QUEUE", "artifacts/panel_geocode_queue.csv")
OUT   <- Sys.getenv("GEOCODE_OUT", "artifacts/panel_geocode_results.csv")
CKPT  <- "artifacts/geocode_checkpoints"
LIMIT <- suppressWarnings(as.integer(Sys.getenv("GEOCODE_LIMIT", "")))
stopifnot(file.exists(QUEUE))
dir.create(CKPT, showWarnings = FALSE, recursive = TRUE)

q <- read_csv(QUEUE, show_col_types = FALSE) %>%
  transmute(geocode_address_1 = nppes_practice_address,
            geocode_city      = nppes_city,
            geocode_state     = nppes_state,
            geocode_zip       = nppes_zip) %>%
  filter(nzchar(coalesce(geocode_city, "")) | nzchar(coalesce(geocode_zip, "")))
if (!is.na(LIMIT)) {
  q <- head(q, LIMIT)
  cat(sprintf("LIMIT set: geocoding first %d addresses only\n", LIMIT))
}
cat(sprintf("addresses to geocode: %s\n", format(nrow(q), big.mark = ",")))

# The cascade sources its dependencies via here::here(), which must resolve to
# the isochrones root -- same constraint as the matching pipeline.
# run_id must be globally unique. A date-only id collided with an earlier
# smoke test on the same day, and the attempt log's
# UNIQUE(run_id, address_hash, attempt_order) rejected 147 rows -- coordinates
# survived, provenance did not. Timestamp to the second plus a random suffix,
# and refuse to start if the id already exists in the log.
RUN_ID <- Sys.getenv("GEOCODE_RUN_ID", sprintf(
  "amcb_midwifery_%s_%s", format(Sys.time(), "%Y%m%dT%H%M%S"),
  paste(sample(c(letters, 0:9), 6, replace = TRUE), collapse = "")))

local({
  cache_db <- Sys.getenv("GEOCODING_CACHE_PATH",
                         path.expand("~/isochrones/data/geocoding_cache.duckdb"))
  if (!file.exists(cache_db)) return(invisible(NULL))
  suppressPackageStartupMessages({library(DBI); library(duckdb)})
  con <- dbConnect(duckdb::duckdb(), cache_db, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  tbls <- dbGetQuery(con, "SHOW TABLES")$name
  if (!"geocoding_attempt_log" %in% tbls) return(invisible(NULL))
  n <- dbGetQuery(con, sprintf(
    "SELECT COUNT(*) AS n FROM geocoding_attempt_log WHERE run_id = '%s'", RUN_ID))$n
  if (n > 0) {
    stop(sprintf(paste("run_id '%s' already has %s rows in geocoding_attempt_log.",
                       "Reusing it would silently drop this run's provenance.",
                       "Set GEOCODE_RUN_ID to a new value."),
                 RUN_ID, format(n, big.mark = ",")), call. = FALSE)
  }
})
cat(sprintf("run_id: %s\n", RUN_ID))

res <- local({
  owd <- setwd(ISO)
  on.exit(setwd(owd), add = TRUE)
  # The cascade calls is_test_mode() at the end of a run but does not source
  # its definition; it lives in R/test_mode_contracts.R.
  suppressWarnings(suppressMessages(source(file.path("R", "test_mode_contracts.R"))))
  suppressWarnings(suppressMessages(source(file.path("R", "geocode_with_3tier_cascade.R"))))
  stopifnot(exists("geocode_batch_with_3tier_cascade"), exists("is_test_mode"))
  geocode_batch_with_3tier_cascade(
    q, run_id = RUN_ID,
    deduplicate = TRUE, show_progress = TRUE,
    checkpoint_dir = file.path(owd, CKPT))
})

# =============================================================================
# Tract and county enrichment
# =============================================================================
# The cascade returns COORDINATES. It carries census_tract, county_fips and
# state_fips columns in its schema and leaves them empty, because assigning them
# is a separate step -- and a run that skips it writes an artifact that looks
# complete and joins to nothing.
#
# That is not hypothetical. A 12,722-address run on 2026-08-14 reported "98.1%
# resolved" with county_fips empty on every row; the analysis that consumed it
# silently fell back to the few cached rows that did carry a county and produced
# 98.8% annual persistence on a third of the data. Plausible, and wrong.
#
# So enrichment is now part of this script, it uses on_missing = "error", and it
# refuses to write an artifact whose geography columns are empty.
res <- local({
  tract_rds <- Sys.getenv("TRACT_BOUNDARY_RDS", "")
  if (!nzchar(tract_rds)) {
    tract_rds <- file.path(ISO, "data", "cache", "tract_boundaries",
                           "tracts_y2020_production.rds")
  }
  if (!file.exists(tract_rds)) {
    stop(sprintf(paste0(
      "Tract boundaries not found at %s.\n",
      "  The cascade would still resolve coordinates, and every geography column\n",
      "  would be empty -- which is the failure this check exists to prevent.\n",
      "  Fetch the artifact listed in isochrones config/tract_boundary_artifacts.yaml:\n",
      "    curl -L -o '%s' \\\n",
      "      'https://www.dropbox.com/scl/fi/1131xcq1el49hrgw5s1ix/tracts_y2020_production.rds?rlkey=ww00msz4tizbsjuo9by0zcmgb&dl=1'\n",
      "  then verify it against TRACT_BOUNDARY_SHA256SUMS.txt in the same folder,\n",
      "  or point TRACT_BOUNDARY_RDS at a copy you already have."),
      tract_rds, tract_rds), call. = FALSE)
  }

  # UPSTREAM DEFECT, compensated here. tracts_y2020_production.rds deserialises
  # with its geometry column as a plain list of sfg rather than an sfc: the class
  # and the CRS are lost in serialisation, and st_crs() then fails with
  # "attr(obj, 'sf_column') does not point to a geometry column". Rebuilding the
  # sfc is cheap and lossless. TIGER/Line is NAD83 (EPSG:4269), which is what
  # tigris returns; at tract scale the difference from WGS84 is sub-metre.
  # The real fix belongs in isochrones' export_tract_boundary_artifacts.R.
  tr <- readRDS(tract_rds)
  if (!inherits(tr[[attr(tr, "sf_column") %||% "geometry"]], "sfc")) {
    gcol <- attr(tr, "sf_column"); if (is.null(gcol)) gcol <- "geometry"
    cat(sprintf("[tracts] repairing stripped sfc on '%s' (upstream artifact defect)\n", gcol))
    tr[[gcol]] <- sf::st_sfc(tr[[gcol]], crs = 4269)
    tr <- sf::st_as_sf(tr, sf_column_name = gcol)
    tract_rds <- file.path(tempdir(), "tracts_repaired.rds")
    saveRDS(tr, tract_rds)
  }
  rm(tr); invisible(gc(FALSE))

  owd2 <- setwd(ISO)
  on.exit(setwd(owd2), add = TRUE)
  suppressWarnings(suppressMessages(source(file.path("R", "enrich_geocode_tracts.R"))))
  stopifnot(exists("enrich_with_census_tracts", mode = "function"))
  d <- as.data.frame(res)
  d$latitude <- suppressWarnings(as.numeric(d$lat))
  d$longitude <- suppressWarnings(as.numeric(d$lon))
  # on_missing = "error": the function has nine warn-and-return paths that hand
  # back the input unchanged, and every one of them produces the empty-column
  # artifact described above.
  enrich_with_census_tracts(d, lat_col = "latitude", lon_col = "longitude",
                            tract_rds = tract_rds, on_missing = "error")
})

# The enrichment can succeed and still populate nothing if the join misses.
# Assert on the rows that HAVE coordinates -- rows the geocoder failed on are
# legitimately empty and must not count against the check.
local({
  has_xy <- !is.na(suppressWarnings(as.numeric(res$lat)))
  n_xy <- sum(has_xy)
  if (n_xy == 0L) return(invisible(NULL))
  for (col in c("census_tract", "county_fips")) {
    if (!col %in% names(res)) {
      stop(sprintf("Enrichment returned no '%s' column.", col), call. = FALSE)
    }
    v <- as.character(res[[col]])[has_xy]
    filled <- sum(!is.na(v) & nzchar(v))
    pct <- 100 * filled / n_xy
    cat(sprintf("[tracts] %-13s %s / %s geocoded rows (%.1f%%)\n",
                col, format(filled, big.mark = ","), format(n_xy, big.mark = ","), pct))
    if (pct < 95) {
      stop(sprintf(paste0(
        "Only %.1f%% of geocoded rows carry %s. Refusing to write an artifact ",
        "whose geography is mostly empty."), pct, col), call. = FALSE)
    }
  }
})

write_csv(res, OUT, na = "")
cat(sprintf("\nwrote %s rows -> %s\n", format(nrow(res), big.mark = ","), OUT))
if ("lat" %in% names(res)) {
  cat(sprintf("resolved: %s (%.1f%%)\n", format(sum(!is.na(res$lat)), big.mark = ","),
              100 * mean(!is.na(res$lat))))
}
if ("geocoder_provenance" %in% names(res)) {
  cat("\nby provenance:\n"); print(as.data.frame(table(res$geocoder_provenance, useNA = "ifany")))
}
