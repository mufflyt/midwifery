#!/usr/bin/env Rscript
# =============================================================================
# Extract ORIGIN COORDINATES ONLY from one historical isochrone artifact
# =============================================================================
# Run as: Rscript extract_archive_origins.R <in.rds> <out_catalog.rds> <source_label>
#
# ONE FILE PER PROCESS, DELIBERATELY. This machine has 8.6 GB of RAM and some of
# these artifacts are 2.7 GB compressed with an sf geometry list-column; loading
# two in one session is how you get a silent OOM kill halfway through an
# inventory and mistake it for "the file had no origins". Each extraction gets
# its own process so a death is visible and isolated.
#
# Geometry is dropped as early as possible: this pass answers only "which
# distinct origin LOCATIONS and which bands does this artifact contain", which
# is what the recovery match needs. Polygons are read later, and only for
# origins that actually rescue an unrepresented midwife.
#
# NOTHING IS ROUTED. NOTHING IS GENERATED. Read-only.
# =============================================================================
suppressPackageStartupMessages({library(sf); library(dplyr)})

a <- commandArgs(trailingOnly = TRUE)
stopifnot(length(a) == 3)
IN <- a[1]; OUT <- a[2]; LABEL <- a[3]

cat(sprintf("[%s] reading %s (%.0f MB)\n", LABEL, IN,
            file.info(IN)$size / 1e6))
x <- readRDS(IN)
cat(sprintf("[%s] class=%s rows=%s\n", LABEL, paste(class(x), collapse = "/"),
            format(NROW(x), big.mark = ",")))

d <- if (inherits(x, "sf")) sf::st_drop_geometry(x) else as.data.frame(x)
rm(x); invisible(gc())
cat(sprintf("[%s] columns: %s\n", LABEL, paste(names(d), collapse = ", ")))

pick <- function(cands) {
  hit <- cands[cands %in% names(d)]
  if (length(hit)) hit[1] else NA_character_
}
lat_c  <- pick(c("center_lat", "centre_lat", "origin_lat", "lat", "latitude",
                 "center_latitude"))
lon_c  <- pick(c("center_lng", "center_lon", "centre_lng", "origin_lon",
                 "lng", "lon", "longitude", "center_longitude"))
band_c <- pick(c("drive_time_minutes", "contour", "time_band", "band",
                 "minutes", "isochrone_minutes", "range"))
id_c   <- pick(c("id", "npi", "NPI", "provider_npi", "location_key"))

if (is.na(lat_c) || is.na(lon_c)) {
  cat(sprintf("[%s] NO ORIGIN COORDINATE COLUMNS -- cannot contribute origins\n",
              LABEL))
  saveRDS(data.frame(), OUT)
  quit(status = 0)
}

out <- tibble(
  source        = LABEL,
  source_file   = IN,
  center_lat    = suppressWarnings(as.numeric(d[[lat_c]])),
  center_lng    = suppressWarnings(as.numeric(d[[lon_c]])),
  band          = if (is.na(band_c)) NA_real_ else
                    suppressWarnings(as.numeric(d[[band_c]])),
  origin_id     = if (is.na(id_c)) NA_character_ else as.character(d[[id_c]])
) %>%
  filter(!is.na(center_lat), !is.na(center_lng),
         # Guard against a degenerate 0/0 or out-of-range coordinate being
         # counted as a recovered origin.
         abs(center_lat) <= 90, abs(center_lng) <= 180,
         !(center_lat == 0 & center_lng == 0)) %>%
  # The canonical artifacts key locations at 6dp; use the same key so a
  # recovered origin can be compared to the canonical set exactly.
  mutate(location_key = sprintf("%.6f_%.6f", center_lat, center_lng))

cat(sprintf("[%s] lat=%s lon=%s band=%s id=%s\n", LABEL, lat_c, lon_c,
            band_c, id_c))
cat(sprintf("[%s] bands present: %s\n", LABEL,
            paste(sort(unique(out$band)), collapse = ", ")))
cat(sprintf("[%s] distinct origin locations: %s\n", LABEL,
            format(dplyr::n_distinct(out$location_key), big.mark = ",")))

saveRDS(out, OUT)
cat(sprintf("[%s] catalog written: %s\n", LABEL, OUT))
