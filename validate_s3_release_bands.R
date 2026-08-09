#!/usr/bin/env Rscript
# =============================================================================
# Assemble a per-band S3 release into ONE multi-band sf for the wanted origins,
# then hand it to the same validation gate the single-file archives get.
# =============================================================================
# Run as: Rscript validate_s3_release_bands.R <s3_prefix> <keys.csv> \
#                                             <out.rds> <label> <band...>
#
# The consolidated releases store one band per object, so band completeness and
# Russian-doll nesting are simply unknowable from any single file. Each band is
# downloaded, immediately subset to the wanted origins (a few hundred rows out
# of thousands), and deleted before the next one -- this box has 21 GB free and
# the 180-minute object alone is 798 MB.
#
# Read-only. No routing, no generation.
# =============================================================================
suppressPackageStartupMessages({library(sf); library(dplyr); library(readr)})

a <- commandArgs(trailingOnly = TRUE); stopifnot(length(a) >= 5)
PREFIX <- a[1]; KEYS <- a[2]; OUT <- a[3]; LABEL <- a[4]; BANDS <- a[-(1:4)]
TMP <- file.path(tempdir(), "band.rds")

want <- read_csv(KEYS, show_col_types = FALSE)$location_key

parts <- lapply(BANDS, function(b) {
  url <- sprintf("%s/isochrones_%smin_consolidated.rds", PREFIX, b)
  st <- system2("aws", c("s3", "cp", url, TMP, "--quiet"))
  if (st != 0) { cat(sprintf("[%s] %smin: download failed\n", LABEL, b)); return(NULL) }
  x <- readRDS(TMP); on.exit(unlink(TMP), add = TRUE)
  # ALWAYS derive the key from the coordinates, never trust the file's own
  # location_key column: releases differ in the precision they wrote it at
  # (5dp vs 6dp), so joining on it silently matched zero rows for the archive
  # releases while the coordinates matched fine.
  k <- sprintf("%.6f_%.6f", as.numeric(x$center_lat), as.numeric(x$center_lng))
  sel <- which(k %in% want)
  cat(sprintf("[%s] %smin: %s rows kept\n", LABEL, b, length(sel)))
  if (!length(sel)) return(NULL)

  # Rebuild a minimal sf from the geometry list-column BY NAME rather than
  # subsetting the object in place. Several releases carry a stale `sf_column`
  # attribute that survives dplyr::select() but makes st_transform() fail with
  # "attr(obj, 'sf_column') does not point to a geometry column".
  gcol <- attr(x, "sf_column")
  if (is.null(gcol) || !gcol %in% names(x))
    gcol <- names(x)[vapply(x, function(z) inherits(z, "sfc"), logical(1))][1]
  # A missing CRS is assumed to be EPSG:4326 -- these are lon/lat contours from
  # Valhalla and the coordinate ranges confirm it -- because st_transform()
  # errors outright on an NA crs. The assumption is asserted, not silent.
  crs <- sf::st_crs(x[[gcol]])
  if (is.na(crs)) {
    bb <- sf::st_bbox(sf::st_sfc(x[[gcol]][sel]))
    stopifnot(bb["xmin"] >= -180, bb["xmax"] <= 180,
              bb["ymin"] >= -90,  bb["ymax"] <= 90)
    cat(sprintf("[%s] %smin: CRS missing, assuming EPSG:4326\n", LABEL, b))
    crs <- sf::st_crs(4326)
  }
  g <- sf::st_sfc(x[[gcol]][sel], crs = crs)
  out <- sf::st_sf(center_lat = as.numeric(x$center_lat)[sel],
                   center_lng = as.numeric(x$center_lng)[sel],
                   drive_time_minutes = as.numeric(b),
                   geometry = g)
  # Bands within a single release do NOT share a CRS -- rbind() fails with
  # "arguments have different crs". Normalise every band to EPSG:4326 here so
  # the nesting comparison downstream is made on one datum.
  suppressWarnings(sf::st_transform(out, 4326))
})
parts <- Filter(function(z) !is.null(z) && nrow(z) > 0, parts)
if (!length(parts)) { saveRDS(tibble(), OUT); cat("no rows\n"); quit(status = 0) }

comb <- do.call(rbind, parts)
saveRDS(comb, OUT)
cat(sprintf("[%s] combined: %s rows, %s origins, bands %s\n", LABEL, nrow(comb),
            dplyr::n_distinct(sprintf("%.6f_%.6f", comb$center_lat, comb$center_lng)),
            paste(sort(unique(comb$drive_time_minutes)), collapse = "/")))
