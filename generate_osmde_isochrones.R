#!/usr/bin/env Rscript
# =============================================================================
# Generate 30/60-minute isochrones on the PUBLIC osm.de Valhalla server
# =============================================================================
# Run as: Rscript generate_osmde_isochrones.R [n_limit]
#
# THIS IS A DIFFERENT ROUTING ENGINE FROM THE CANONICAL LIBRARY, ON PURPOSE AND
# BY EXPLICIT INSTRUCTION. The canonical 3,909 origins were generated on EC2
# Valhalla (localhost:8002) against a pinned OSM extract. These are generated on
# valhalla1.openstreetmap.de, whose graph vintage and build settings we do not
# control and cannot pin.
#
# WHY THAT MATTERS SCIENTIFICALLY. The locations routed here are the ones the
# canonical library failed to cover, and that failure is rural-selective. So the
# engine boundary falls almost exactly along the urban/rural axis -- the same
# axis the study measures. Any difference between the two engines' network
# assumptions will therefore masquerade as a rural access effect. Every polygon
# is stamped with `routing_engine` so this can never be silently lost, and any
# analysis mixing the two sets must report it as a limitation.
#
# The project config marks this server enabled: false and DEPRECATED 2026-06-28
# (CLAUDE.md Non-Negotiable #12 puts all bands on EC2). It is used here because
# the owner directed it after being shown that policy.
#
# NOTHING IS WRITTEN TO artifacts/isochrones/. The canonical library stays at
# exactly 3,909 origins. Output is a separate, clearly-named artifact.
#
# Input : artifacts/route_queue_osmde.csv   (deduplicated distinct locations)
# Output: artifacts/isochrones_osmde/osmde_isochrones_30_60.rds   (sf)
#         artifacts/isochrones_osmde/_checkpoint.rds              (resumable)
#         artifacts/isochrones_osmde/_failures.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(httr); library(jsonlite)
})

SERVER    <- "https://valhalla1.openstreetmap.de"
BANDS     <- c(30, 60)
SLEEP_S   <- 3.0     # 2x the documented 1.5s minimum for this host
MAX_RETRY <- 3
CKPT_EVERY<- 25
OUTDIR    <- "artifacts/isochrones_osmde"
CKPT      <- file.path(OUTDIR, "_checkpoint.rds")
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

args    <- commandArgs(trailingOnly = TRUE)
n_limit <- if (length(args)) as.integer(args[1]) else NA_integer_

q <- read_csv("artifacts/route_queue_osmde.csv", show_col_types = FALSE)

# Resume: a run interrupted at request 900 must not re-hit the public server for
# the 900 it already has.
done <- if (file.exists(CKPT)) readRDS(CKPT) else list()
if (length(done)) cat(sprintf("resuming: %s locations already retrieved\n", length(done)))
q <- q %>% filter(!location_key %in% names(done))
if (!is.na(n_limit)) q <- head(q, n_limit)
cat(sprintf("server   : %s\nbands    : %s\npacing   : %.1f s between requests\nto route : %s locations (~%.0f min)\n\n",
            SERVER, paste(BANDS, collapse = "/"), SLEEP_S, nrow(q),
            nrow(q) * (SLEEP_S + 1.2) / 60))

# Both contours in ONE request -- halves the load on a volunteer-run server
# relative to one request per band, and guarantees the two bands come from the
# same graph state.
fetch_one <- function(lat, lon) {
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
    return(list(ok = TRUE, sf = g))
  }
  list(ok = FALSE, msg = "exhausted retries")
}

fails <- list(); t0 <- Sys.time()
for (i in seq_len(nrow(q))) {
  row <- q[i, ]
  res <- fetch_one(row$latitude, row$longitude)
  if (res$ok) {
    done[[row$location_key]] <- res$sf
  } else {
    fails[[length(fails) + 1]] <- tibble(location_key = row$location_key,
                                         latitude = row$latitude,
                                         longitude = row$longitude,
                                         reason = res$msg)
    cat(sprintf("  FAIL %s: %s\n", row$location_key, res$msg))
  }
  if (i %% CKPT_EVERY == 0 || i == nrow(q)) {
    saveRDS(done, CKPT)
    el <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
    cat(sprintf("[%s/%s] retrieved %s | %.1f min elapsed | ~%.0f min left\n",
                i, nrow(q), length(done), el, el / i * (nrow(q) - i)))
  }
  Sys.sleep(SLEEP_S)
}

if (length(fails))
  write_csv(bind_rows(fails), file.path(OUTDIR, "_failures.csv"))

# --- assemble -----------------------------------------------------------------
# Valhalla returns one feature per contour, tagged with `contour` in minutes.
stamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
out <- bind_rows(lapply(names(done), function(k) {
  g <- done[[k]]
  cc <- as.numeric(strsplit(k, "_", fixed = TRUE)[[1]])
  bcol <- intersect(c("contour", "time"), names(g))[1]
  sf::st_sf(
    location_key       = k,
    center_lat         = cc[1],
    center_lng         = cc[2],
    drive_time_minutes = as.numeric(g[[bcol]]),
    # Provenance travels WITH the geometry. A downstream join that loses these
    # columns would make the two engines indistinguishable.
    routing_engine     = "valhalla1.openstreetmap.de",
    routing_scope      = "public_demo_server",
    osm_vintage        = NA_character_,   # not pinnable on the public server
    costing            = "auto",
    generated_utc      = stamp,
    geometry           = sf::st_geometry(g))
}))
out <- sf::st_transform(out, 4326)

saveRDS(out, file.path(OUTDIR, "osmde_isochrones_30_60.rds"))
cat(sprintf("\nlocations retrieved : %s of %s\n", length(done), nrow(q) + length(done)))
cat(sprintf("failures            : %s\n", length(fails)))
cat(sprintf("polygons written    : %s (bands %s)\n", nrow(out),
            paste(sort(unique(out$drive_time_minutes)), collapse = "/")))
cat(sprintf("output              : %s\n", file.path(OUTDIR, "osmde_isochrones_30_60.rds")))
cat("\nCanonical library untouched. These polygons are a SEPARATE, mixed-engine\n")
cat("artifact and are NOT interchangeable with the EC2-generated canonical set.\n")
