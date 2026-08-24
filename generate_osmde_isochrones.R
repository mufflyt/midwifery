#!/usr/bin/env Rscript
# =============================================================================
# Generate 30/60-minute isochrones on the PUBLIC osm.de Valhalla server
# =============================================================================
# Run as: Rscript generate_osmde_isochrones.R [--queue=FILE] [--limit=N]
#                                             [--assemble-only]
#
# Default queue is artifacts/route_queue_osmde_all_midwives.csv -- EVERY
# distinct geocoded midwife location. Pass --queue= to route a different list.
#
# THIS IS A DIFFERENT ROUTING ENGINE FROM THE CANONICAL LIBRARY, ON PURPOSE AND
# BY EXPLICIT INSTRUCTION. The canonical 3,909 origins were generated on EC2
# Valhalla (localhost:8002) against a pinned OSM extract. These are generated on
# valhalla1.openstreetmap.de, whose graph vintage and build settings we do not
# control and cannot pin.
#
# WHY ROUTING **ALL** MIDWIVES IMPROVES THIS RATHER THAN COMPOUNDING IT. When
# only the canonical library's misses were routed here, "engine" and "rurality"
# were confounded by construction: the newly routed set was the rural-selective
# residual, so any engine difference imitated a rural access effect, and
# calibrate_osmde_vs_ec2.R measured that difference as real (median IoU
# 0.78-0.86). Routing every location on osm.de removes the confound instead of
# caveating it -- the whole 30/60-minute surface then comes from ONE engine, and
# rural-urban contrasts within it are no longer partly an artifact of which
# engine drew the polygon.
#
# The project config marks this server enabled: false and DEPRECATED 2026-06-28
# (CLAUDE.md Non-Negotiable #12 puts all bands on EC2). It is used here because
# the owner directed it after being shown that policy.
#
# NOTHING IS WRITTEN TO artifacts/isochrones/. The canonical library stays at
# exactly 3,909 origins. Output is a separate, clearly-named artifact.
#
# DURABILITY. Each retrieval is written to its own file under _cache/ the moment
# it arrives (R/lib/osmde_cache.R). Resume is a directory listing, so an
# interrupted eight-hour run re-requests nothing it already has -- which on a
# volunteer-operated server is a courtesy, not just a convenience.
#
# Input : artifacts/route_queue_osmde_all_midwives.csv
# Output: artifacts/isochrones_osmde/osmde_isochrones_30_60.rds   (sf)
#         artifacts/isochrones_osmde/_cache/<location_key>.rds    (resumable)
#         artifacts/isochrones_osmde/_failures.csv                (appended)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(httr); library(jsonlite)
})
source(file.path("R", "lib", "resume_state.R"))   # atomic_saveRDS
source(file.path("R", "lib", "osmde_cache.R"))

SERVER    <- "https://valhalla1.openstreetmap.de"
BANDS     <- c(30, 60)
SLEEP_S   <- 3.0     # 2x the documented 1.5s minimum for this host
MAX_RETRY <- 3
LOG_EVERY <- 25
# A public server that has stopped answering must not be hammered for eight
# hours. Twenty-five consecutive failures is far beyond any transient blip, and
# the cache means an aborted run resumes for free.
MAX_CONSEC_FAIL <- 25

OUTDIR    <- "artifacts/isochrones_osmde"
CACHE_DIR <- file.path(OUTDIR, "_cache")
CKPT      <- file.path(OUTDIR, "_checkpoint.rds")   # legacy, migrated below
FAILCSV   <- file.path(OUTDIR, "_failures.csv")
OUTRDS    <- file.path(OUTDIR, "osmde_isochrones_30_60.rds")
dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)

# --- arguments ---------------------------------------------------------------
args     <- commandArgs(trailingOnly = TRUE)
arg_val  <- function(flag, default = NA_character_) {
  hit <- grep(paste0("^", flag, "="), args, value = TRUE)
  if (!length(hit)) default else sub(paste0("^", flag, "="), "", hit[1])
}
QUEUE    <- arg_val("--queue", "artifacts/route_queue_osmde_all_midwives.csv")
# A bare integer is still accepted as the limit: the first batch was launched
# that way and the invocation is in the run logs.
bare     <- suppressWarnings(as.integer(args[!grepl("^--", args)]))
n_limit  <- suppressWarnings(as.integer(arg_val("--limit")))
if (is.na(n_limit) && length(bare) && !is.na(bare[1])) n_limit <- bare[1]
assemble_only <- any(args == "--assemble-only")

# --- migrate the legacy monolithic checkpoint --------------------------------
# The first batch stored all 1,471 retrievals in one 87 MB list. Those requests
# were already made; re-issuing them would be waste, so they are moved into the
# cache rather than discarded. Idempotent, and the original file is left in
# place until the cache has proven itself.
migrated <- osmde_migrate_checkpoint(CACHE_DIR, CKPT)
if (migrated)
  cat(sprintf("migrated %s locations from the legacy checkpoint into _cache/\n",
              format(migrated, big.mark = ",")))

fetch_one <- function(lat, lon) {
  # Both contours in ONE request -- halves the load on a volunteer-run server
  # relative to one request per band, and guarantees the two bands come from the
  # same graph state.
  body <- list(
    locations = list(list(lat = lat, lon = lon)),
    costing   = "auto",
    contours  = lapply(BANDS, function(b) list(time = b)),
    polygons  = TRUE,
    denoise   = 0.3,        # matches the EC2 generator
    generalize = 50,        # matches the EC2 generator
    min_road_class = "residential",
    minimum_reachability = 500
  )
  for (attempt in seq_len(MAX_RETRY)) {
    r <- tryCatch(
      httr::POST(paste0(SERVER, "/isochrone"), body = body, encode = "json",
                 httr::timeout(120),
                 httr::add_headers("Content-Type" = "application/json",
                                   "User-Agent" = "midwifery-access-study/1.0")),
      error = function(e) e)
    if (inherits(r, "error")) {
      Sys.sleep(SLEEP_S * attempt * 2); next
    }
    sc <- httr::status_code(r)
    # 429/503 mean we are being told to slow down. Back off hard and honour
    # Retry-After if the server sent one -- ignoring it is how a shared public
    # service gets abused.
    if (sc %in% c(429, 503)) {
      ra <- suppressWarnings(as.numeric(httr::headers(r)[["retry-after"]]))
      wait <- if (!is.na(ra)) ra else SLEEP_S * 10 * attempt
      cat(sprintf("  [%s] rate-limited, backing off %.0f s\n", sc, wait))
      Sys.sleep(wait); next
    }
    if (httr::http_error(r)) {
      if (attempt == MAX_RETRY)
        return(list(ok = FALSE, msg = sprintf("HTTP %s", sc)))
      Sys.sleep(SLEEP_S * attempt); next
    }
    txt <- httr::content(r, as = "text", encoding = "UTF-8")
    g <- tryCatch(sf::st_read(txt, quiet = TRUE), error = function(e) e)
    if (inherits(g, "error")) return(list(ok = FALSE, msg = "unparseable GeoJSON"))
    # A response missing a contour is a silent half-measurement: the location
    # would land in the artifact with a 30 and no 60, and every downstream count
    # of 60-minute coverage would be quietly short. Reject it so the location
    # stays in the queue.
    bcol <- intersect(c("contour", "time"), names(g))[1]
    if (is.na(bcol) || !all(BANDS %in% as.numeric(g[[bcol]])))
      return(list(ok = FALSE, msg = "incomplete contour set"))
    return(list(ok = TRUE, sf = g))
  }
  list(ok = FALSE, msg = "exhausted retries")
}

# --- fetch -------------------------------------------------------------------
if (!assemble_only) {
  q <- read_csv(QUEUE, show_col_types = FALSE)
  have <- osmde_cache_keys(CACHE_DIR)
  cat(sprintf("queue    : %s (%s locations)\n", QUEUE,
              format(nrow(q), big.mark = ",")))
  cat(sprintf("cached   : %s already retrieved\n",
              format(length(have), big.mark = ",")))
  q <- q %>% filter(!location_key %in% have)
  if (!is.na(n_limit)) q <- head(q, n_limit)
  cat(sprintf("server   : %s\nbands    : %s\npacing   : %.1f s between requests\nto route : %s locations (~%.1f h)\n\n",
              SERVER, paste(BANDS, collapse = "/"), SLEEP_S,
              format(nrow(q), big.mark = ","), nrow(q) * (SLEEP_S + 1.2) / 3600))

  n_ok <- 0L; n_fail <- 0L; consec <- 0L; t0 <- Sys.time()
  for (i in seq_len(nrow(q))) {
    row <- q[i, ]
    res <- fetch_one(row$latitude, row$longitude)
    if (res$ok) {
      osmde_cache_put(CACHE_DIR, row$location_key, res$sf,
                      format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
      n_ok <- n_ok + 1L; consec <- 0L
    } else {
      n_fail <- n_fail + 1L; consec <- consec + 1L
      # Appended per failure, not accumulated and written at the end: a run
      # killed at hour seven must still leave a record of what it could not get.
      readr::write_csv(
        tibble(location_key = row$location_key, latitude = row$latitude,
               longitude = row$longitude, reason = res$msg,
               attempted_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
        FAILCSV, append = file.exists(FAILCSV))
      cat(sprintf("  FAIL %s: %s\n", row$location_key, res$msg))
      if (consec >= MAX_CONSEC_FAIL) {
        cat(sprintf("\nABORTING: %s consecutive failures. The server is not answering;\n",
                    consec))
        cat("continuing would be pointless load on a volunteer service.\n")
        cat("Re-run to resume -- nothing already retrieved is re-requested.\n")
        break
      }
    }
    if (i %% LOG_EVERY == 0 || i == nrow(q)) {
      el <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
      cat(sprintf("[%s/%s] ok %s | fail %s | %.1f min elapsed | ~%.1f h left\n",
                  format(i, big.mark = ","), format(nrow(q), big.mark = ","),
                  format(n_ok, big.mark = ","), n_fail, el,
                  el / i * (nrow(q) - i) / 60))
    }
    Sys.sleep(SLEEP_S)
  }
  cat(sprintf("\nretrieved this run : %s\nfailed this run    : %s\n", n_ok, n_fail))
}

# --- assemble ----------------------------------------------------------------
cat("\nassembling cache into one sf ...\n")
out <- osmde_assemble(CACHE_DIR)
atomic_saveRDS(out, OUTRDS)

cat(sprintf("\nlocations in artifact : %s\n",
            format(dplyr::n_distinct(out$location_key), big.mark = ",")))
cat(sprintf("polygons written      : %s (bands %s)\n", nrow(out),
            paste(sort(unique(out$drive_time_minutes)), collapse = "/")))
cat(sprintf("output                : %s\n", OUTRDS))
if (file.exists(FAILCSV)) {
  f <- suppressWarnings(read_csv(FAILCSV, show_col_types = FALSE))
  f <- f[!f$location_key %in% out$location_key, , drop = FALSE]
  cat(sprintf("still unrouted        : %s (see %s)\n",
              dplyr::n_distinct(f$location_key), FAILCSV))
}
cat("\nCanonical library untouched. These polygons are a SEPARATE artifact\n")
cat("generated on the public osm.de graph, and are NOT interchangeable with\n")
cat("the EC2-generated canonical set.\n")
