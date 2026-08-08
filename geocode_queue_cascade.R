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

suppressPackageStartupMessages({library(dplyr); library(readr)})

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

write_csv(res, OUT, na = "")
cat(sprintf("\nwrote %s rows -> %s\n", format(nrow(res), big.mark = ","), OUT))
if ("lat" %in% names(res)) {
  cat(sprintf("resolved: %s (%.1f%%)\n", format(sum(!is.na(res$lat)), big.mark = ","),
              100 * mean(!is.na(res$lat))))
}
if ("geocoder_provenance" %in% names(res)) {
  cat("\nby provenance:\n"); print(as.data.frame(table(res$geocoder_provenance, useNA = "ifany")))
}
