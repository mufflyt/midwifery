#!/usr/bin/env Rscript
# =============================================================================
# Polygon-level validation of recovered origins from ONE historical artifact
# =============================================================================
# Run as: Rscript validate_one_recovered_source.R <artifact.rds> <keys.csv> \
#                                                 <out.rds> <source_label>
#
# A recovered origin is NOT usable merely because its centre sits within 5 km of
# a midwife. This applies the gate the archive files never passed:
#
#   1. all four bands (30/60/120/180) present for that origin
#   2. geometry valid (st_is_valid, after one documented make_valid repair)
#   3. non-empty, POLYGON/MULTIPOLYGON, transformable to EPSG:4326
#   4. Russian-doll nesting: area(30) <= area(60) <= area(120) <= area(180)
#   5. origin coordinate falls inside its own 30-minute polygon
#   6. not a TEST_MODE / sample artifact
#
# Check 5 is the one that catches the failure mode these archives are most
# likely to have: a merge that paired a centre coordinate with another
# provider's polygon. A centre outside its own smallest band is incoherent
# regardless of how clean the geometry looks.
#
# NOTHING IS ROUTED OR REGENERATED. Failing origins are dropped, never repaired
# by interpolation.
# =============================================================================
suppressPackageStartupMessages({library(sf); library(dplyr); library(readr)})
sf::sf_use_s2(FALSE)

a <- commandArgs(trailingOnly = TRUE); stopifnot(length(a) == 4)
IN <- a[1]; KEYS <- a[2]; OUT <- a[3]; LABEL <- a[4]

want <- read_csv(KEYS, show_col_types = FALSE)$location_key
x <- readRDS(IN)
stopifnot(inherits(x, "sf"))

nm <- names(x)
lat_c <- intersect(c("center_lat"), nm)[1]
lon_c <- intersect(c("center_lng", "center_lon"), nm)[1]
bnd_c <- intersect(c("drive_time_minutes", "contour"), nm)[1]
x$.key <- sprintf("%.6f_%.6f", as.numeric(x[[lat_c]]), as.numeric(x[[lon_c]]))
x <- x[x$.key %in% want, ]
cat(sprintf("[%s] rows for wanted origins: %s (origins %s)\n", LABEL,
            format(nrow(x), big.mark = ","), format(n_distinct(x$.key), big.mark = ",")))
if (!nrow(x)) { saveRDS(tibble(), OUT); quit(status = 0) }

# 6. TEST_MODE / sample artifact
test_flag <- any(grepl("TEST_MODE|test_mode|sample", nm, ignore.case = TRUE)) ||
             (("run_id" %in% nm) && any(grepl("test|smoke|sample", x$run_id,
                                              ignore.case = TRUE)))

x <- suppressWarnings(sf::st_transform(x, 4326))          # 3. CRS
g <- sf::st_geometry(x)
ok_type  <- as.character(sf::st_geometry_type(g)) %in% c("POLYGON", "MULTIPOLYGON")
ok_empty <- !sf::st_is_empty(g)
valid0   <- suppressWarnings(sf::st_is_valid(g))
repaired <- !valid0 & ok_type & ok_empty
if (any(repaired, na.rm = TRUE)) {
  cat(sprintf("[%s] repairing %s invalid geometries via st_make_valid\n",
              LABEL, sum(repaired, na.rm = TRUE)))
  g[which(repaired)] <- sf::st_make_valid(g[which(repaired)])
  sf::st_geometry(x) <- g
}
ok_geom <- ok_type & ok_empty & suppressWarnings(sf::st_is_valid(g))

x$.area <- as.numeric(sf::st_area(g))
d <- sf::st_drop_geometry(x) %>%
  transmute(location_key = .key, band = as.numeric(.data[[bnd_c]]),
            area = .area, ok_geom = ok_geom,
            was_repaired = coalesce(repaired, FALSE))

# 5. centre inside its own 30-minute polygon
b30 <- which(d$band == 30 & d$ok_geom)
inside <- tibble(location_key = character(), centre_in_30 = logical())
if (length(b30)) {
  cc <- do.call(rbind, strsplit(d$location_key[b30], "_", fixed = TRUE))
  pt <- sf::st_as_sf(data.frame(lat = as.numeric(cc[, 1]),
                                lon = as.numeric(cc[, 2])),
                     coords = c("lon", "lat"), crs = 4326)
  hit <- suppressMessages(sf::st_intersects(pt, g[b30], sparse = FALSE))
  # One row per origin. An archive can hold DUPLICATE 30-minute rows for the
  # same centre (re-generation attempts left in place), and joining that back
  # un-deduplicated fans the result out -- it reported 664 origins for an input
  # of 557 before this collapse. An origin counts as centred if ANY of its
  # 30-minute polygons contains it.
  inside <- tibble(location_key = d$location_key[b30],
                   centre_in_30 = diag(as.matrix(hit))) %>%
    group_by(location_key) %>%
    summarise(centre_in_30 = any(centre_in_30), .groups = "drop")
}

res <- d %>%
  group_by(location_key) %>%
  summarise(
    n_bands      = n_distinct(band),
    all_4_bands  = n_distinct(band) == 4L,                      # 1
    geom_ok      = all(ok_geom),                                # 2,3
    any_repaired = any(was_repaired),
    # 4. Russian-doll nesting, on area with a 1% tolerance for the
    #    simplification the archives applied at generation time.
    nesting_ok   = {
      ar <- area[order(band)]
      length(ar) < 2 || all(diff(ar) >= -0.01 * head(ar, -1))
    },
    .groups = "drop") %>%
  left_join(inside, by = "location_key") %>%
  mutate(centre_in_30 = coalesce(centre_in_30, FALSE),
         test_artifact = test_flag,                             # 6
         source_group = LABEL,
         source_file = IN,
         passes = all_4_bands & geom_ok & nesting_ok & centre_in_30 & !test_artifact)

cat(sprintf("[%s] origins %s | all4 %s | geom %s | nest %s | centre %s | PASS %s\n",
            LABEL, nrow(res), sum(res$all_4_bands), sum(res$geom_ok),
            sum(res$nesting_ok), sum(res$centre_in_30), sum(res$passes)))
saveRDS(res, OUT)
