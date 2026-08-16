#' @title Per-location cache and assembly for osm.de Valhalla isochrones
#'
#' @description
#' The first osm.de run held every retrieved polygon in one in-memory list and
#' re-wrote the whole list to `_checkpoint.rds` every 25 requests. At 1,471
#' locations that checkpoint is 87 MB, so a full-cohort run of 8,359 locations
#' would rewrite roughly half a gigabyte every 25 requests -- the checkpoint
#' write would take longer than the 25 requests it protects, and a run
#' interrupted mid-write loses the single file that holds everything.
#'
#' So the unit of durability here is ONE LOCATION. Each retrieval is written to
#' its own file under `_cache/`, atomically, and never rewritten. Resume is a
#' directory listing. Nothing accumulates in memory during the fetch loop.
#'
#' @section Why provenance is stamped per location, not per run:
#' A full-cohort run takes about eight hours and will be resumed across days,
#' possibly against a public graph that is rebuilt in between. One
#' `generated_utc` for the whole artifact would assert a single graph vintage
#' that the run does not actually have. Each cache entry carries its own fetch
#' time, and assembly propagates it.
#'
#' @family isochrone-provenance

if (!exists("atomic_saveRDS", mode = "function")) {
  source(file.path("R", "lib", "resume_state.R"))
}

#' Cache file for one location key
#'
#' @param cache_dir [character(1)]: the `_cache/` directory.
#' @param key [character]: `"<lat6dp>_<lon6dp>"` location keys. Digits, `.`,
#'   `-` and `_` only, so the key is used verbatim as a filename.
#' @return [character] paths, parallel to `key`.
osmde_cache_path <- function(cache_dir, key) {
  file.path(cache_dir, paste0(key, ".rds"))
}

#' Location keys already retrieved
#'
#' @param cache_dir [character(1)].
#' @return [character] keys present in the cache, possibly empty.
osmde_cache_keys <- function(cache_dir) {
  if (!dir.exists(cache_dir)) return(character(0))
  sub("\\.rds$", "", list.files(cache_dir, pattern = "\\.rds$"))
}

#' Store one retrieved location
#'
#' Written through a temporary file and renamed, so a run killed mid-write
#' leaves either the previous state or the complete new file, never a truncated
#' one that resume would count as done.
#'
#' @param cache_dir [character(1)].
#' @param key [character(1)] location key.
#' @param geom `sf`: the Valhalla response, one feature per contour.
#' @param fetched_utc [character(1)]: ISO-8601 UTC fetch time.
#' @return `key`, invisibly.
osmde_cache_put <- function(cache_dir, key, geom, fetched_utc) {
  atomic_saveRDS(list(sf = geom, fetched_utc = fetched_utc),
                 osmde_cache_path(cache_dir, key))
  invisible(key)
}

#' Read one cached location
#'
#' Tolerates both the current `list(sf=, fetched_utc=)` layout and a bare `sf`
#' object, which is what entries migrated from the old monolithic checkpoint
#' look like before they are rewritten.
#'
#' @param cache_dir [character(1)].
#' @param key [character(1)].
#' @return `list(sf, fetched_utc)`, or NULL when the file is unreadable.
osmde_cache_get <- function(cache_dir, key) {
  p <- osmde_cache_path(cache_dir, key)
  if (!file.exists(p)) return(NULL)
  x <- tryCatch(readRDS(p), error = function(e) NULL)
  if (is.null(x)) return(NULL)
  if (inherits(x, "sf")) return(list(sf = x, fetched_utc = NA_character_))
  if (is.list(x) && inherits(x$sf, "sf")) return(x)
  NULL
}

#' Migrate a monolithic `_checkpoint.rds` into the per-location cache
#'
#' Idempotent: keys already in the cache are left alone, so this is safe to call
#' at the top of every run. The checkpoint file is NOT deleted -- it is the only
#' copy of 1,471 retrievals until the cache is proven good, and removing it here
#' would make an interrupted migration unrecoverable.
#'
#' Migrated entries inherit the checkpoint file's mtime as their fetch time,
#' flagged as file-level rather than request-level, because the original run
#' recorded only one timestamp for the whole batch.
#'
#' @param cache_dir [character(1)].
#' @param ckpt_path [character(1)]: legacy checkpoint, may be absent.
#' @return [integer(1)] number of entries newly written to the cache.
osmde_migrate_checkpoint <- function(cache_dir, ckpt_path) {
  if (!file.exists(ckpt_path)) return(0L)
  have <- osmde_cache_keys(cache_dir)
  done <- readRDS(ckpt_path)
  todo <- setdiff(names(done), have)
  if (!length(todo)) return(0L)
  stamp <- format(file.info(ckpt_path)$mtime, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  for (k in todo) {
    if (!inherits(done[[k]], "sf")) next
    osmde_cache_put(cache_dir, k, done[[k]],
                    fetched_utc = paste0(stamp, " (checkpoint mtime)"))
  }
  length(todo)
}

#' Assemble the cache into one sf of 30/60-minute polygons
#'
#' Read in chunks and bound per chunk. Holding 8,359 individual `sf` objects and
#' binding them in one call peaks at several gigabytes; chunking keeps the peak
#' to one chunk plus the accumulating result.
#'
#' Geometries are cast to MULTIPOLYGON. Valhalla returns POLYGON for most
#' origins but MULTIPOLYGON where the reachable area is disconnected -- islands,
#' ferry-served coastline. `rbind` of mixed geometry types fails, and casting UP
#' is lossless where casting down is not.
#'
#' @param cache_dir [character(1)].
#' @param chunk [integer(1)]: locations per bind.
#' @param verbose [logical(1)].
#' @return `sf` with one row per (location, band).
osmde_assemble <- function(cache_dir, chunk = 500L, verbose = TRUE) {
  keys <- osmde_cache_keys(cache_dir)
  if (!length(keys)) stop("cache is empty: ", cache_dir)

  one <- function(k) {
    e <- osmde_cache_get(cache_dir, k)
    if (is.null(e)) return(NULL)
    g <- e$sf
    # Valhalla labels the contour `contour` in current builds and `time` in
    # older ones. Neither present means the response shape changed and the band
    # cannot be identified -- drop it rather than guess.
    bcol <- intersect(c("contour", "time"), names(g))[1]
    if (is.na(bcol)) return(NULL)
    cc <- as.numeric(strsplit(k, "_", fixed = TRUE)[[1]])
    sf::st_sf(
      location_key       = k,
      center_lat         = cc[1],
      center_lng         = cc[2],
      drive_time_minutes = as.numeric(g[[bcol]]),
      # Provenance travels WITH the geometry. A downstream join that dropped
      # these columns would make the two routing engines indistinguishable,
      # which is the entire hazard this artifact carries.
      routing_engine     = "valhalla1.openstreetmap.de",
      routing_scope      = "public_demo_server",
      osm_vintage        = NA_character_,   # not pinnable on the public server
      costing            = "auto",
      generated_utc      = e$fetched_utc,
      geometry           = sf::st_geometry(g))
  }

  out <- NULL
  grp <- split(keys, ceiling(seq_along(keys) / chunk))
  for (i in seq_along(grp)) {
    part <- lapply(grp[[i]], one)
    part <- part[!vapply(part, is.null, logical(1))]
    if (!length(part)) next
    part <- do.call(rbind, part)
    part <- sf::st_cast(part, "MULTIPOLYGON", warn = FALSE)
    out <- if (is.null(out)) part else rbind(out, part)
    if (verbose)
      cat(sprintf("  assembled %s/%s locations\n",
                  format(min(i * chunk, length(keys)), big.mark = ","),
                  format(length(keys), big.mark = ",")))
    invisible(gc())
  }
  sf::st_transform(out, 4326)
}
