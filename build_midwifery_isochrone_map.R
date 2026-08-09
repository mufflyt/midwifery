#!/usr/bin/env Rscript
# =============================================================================
# National 30/60-minute midwifery access map -- DISSOLVED UNION ONLY
# =============================================================================
# Run as: Rscript build_midwifery_isochrone_map.R
#
# PRIVACY IS THE CONTROLLING CONSTRAINT, NOT A PREFERENCE.
# An isochrone is centred on its origin, so a per-midwife polygon discloses that
# midwife's practice address as surely as a point map does -- more precisely, in
# fact, since the centroid is recoverable from the polygon. Publishing 11,792
# individual isochrones would therefore publish 11,792 practice locations.
#
# This script dissolves all polygons within a band into a SINGLE multipolygon
# before anything is written or rendered. The output answers "is this ground
# within 30 minutes of some midwife?" and cannot answer "where is any particular
# midwife?". No point layer is created, and an assertion below fails the build
# if the dissolved output ever contains more than one feature per band.
#
# MIXED ROUTING ENGINES. The 30/60 surface is assembled from EC2-Valhalla
# polygons (canonical) and osm.de public-server polygons (the 2,249 midwives the
# canonical library never covered). The engine split is rural-selective by
# construction. calibrate_osmde_vs_ec2.R measures the resulting disagreement;
# whatever it reports must accompany this map. The per-source areas printed at
# the end let a reader see how much of the surface rests on each engine.
#
# BANDS ARE 30/60 ONLY. No 120/180 polygons were generated for the newly routed
# locations, so a 120/180 map would silently revert to the biased canonical-only
# coverage. Do not extend this script to those bands without generating them.
#
# Inputs : ~/isochrones/artifacts/isochrones/isochrones_{30,60}min_consolidated.rds
#          artifacts/midwife_isochrone_match.csv
#          artifacts/isochrones_osmde/osmde_isochrones_30_60.rds
#          artifacts/county_midwifery_supply.csv
# Outputs: artifacts/maps/midwifery_isochrone_union_{30,60}min.rds
#          artifacts/maps/midwifery_access_map.html
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr)
  library(leaflet); library(htmlwidgets)
})
sf::sf_use_s2(FALSE)

BANDS   <- c(30, 60)
OUTDIR  <- "artifacts/maps"
SIMPLIFY_KEEP <- 0.05   # ms_simplify: web payload, not analysis geometry
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

# --- 1. which canonical origins actually serve a midwife? --------------------
# Only origins that matched a midwife within 5 km belong on this map. Including
# the whole 3,909-origin physician library would draw coverage around locations
# with no midwife at all.
mat <- read_csv("artifacts/midwife_isochrone_match.csv", show_col_types = FALSE)
canon_keys <- mat %>%
  distinct(latitude, longitude) %>%
  mutate(location_key = sprintf("%.6f_%.6f", latitude, longitude)) %>%
  pull(location_key)
cat(sprintf("canonical origins serving a midwife: %s\n", length(canon_keys)))

osm <- readRDS("artifacts/isochrones_osmde/osmde_isochrones_30_60.rds")
cat(sprintf("osm.de origins                     : %s\n", n_distinct(osm$location_key)))

# Recovered-archive polygons live mostly on the external drive. Their absence is
# reported rather than silently reducing coverage.
recov <- NULL
rv <- "artifacts/historical_isochrone_recovery_validated.csv"
if (file.exists(rv)) {
  v <- read_csv(rv, show_col_types = FALSE)
  avail <- unique(v$source_file[file.exists(v$source_file)])
  miss  <- setdiff(unique(v$source_file), avail)
  if (length(miss))
    cat(sprintf("recovered sources UNAVAILABLE      : %s of %s (external drive not mounted)\n",
                length(miss), n_distinct(v$source_file)))
  recov <- list(keys = v$location_key, files = avail)
}

# --- 2. build one dissolved multipolygon per band ----------------------------
# One band at a time: the consolidated files are 151-201 MB compressed and this
# machine has 8.6 GB of RAM.
band_union <- function(b) {
  parts <- list()

  f <- path.expand(sprintf("~/isochrones/artifacts/isochrones/isochrones_%dmin_consolidated.rds", b))
  x <- readRDS(f)
  k <- sprintf("%.6f_%.6f", as.numeric(x$center_lat), as.numeric(x$center_lng))
  sel <- which(k %in% canon_keys)
  gcol <- attr(x, "sf_column")
  if (is.null(gcol) || !gcol %in% names(x))
    gcol <- names(x)[vapply(x, function(z) inherits(z, "sfc"), logical(1))][1]
  g <- sf::st_sfc(x[[gcol]][sel], crs = sf::st_crs(x[[gcol]]))
  if (is.na(sf::st_crs(g))) sf::st_crs(g) <- 4326
  g <- suppressWarnings(sf::st_transform(g, 4326))
  parts$ec2 <- sf::st_make_valid(g)
  cat(sprintf("[%smin] EC2 canonical polygons : %s\n", b, length(parts$ec2)))
  rm(x, g); invisible(gc())

  o <- osm[osm$drive_time_minutes == b, ]
  og <- suppressWarnings(sf::st_transform(sf::st_geometry(o), 4326))
  # 7 of 2,942 osm.de polygons fail st_is_valid (self-intersections, the usual
  # Valhalla contour artifact). st_union errors on invalid input, so they are
  # repaired here -- and the repair is counted, never silent.
  bad <- !suppressWarnings(sf::st_is_valid(og))
  if (any(bad)) {
    cat(sprintf("[%smin] repairing %s invalid osm.de geometries\n", b, sum(bad)))
    og[which(bad)] <- sf::st_make_valid(og[which(bad)])
  }
  parts$osmde <- og
  cat(sprintf("[%smin] osm.de polygons        : %s\n", b, length(parts$osmde)))

  # Validated archive-recovered origins, from whichever source artifacts are
  # reachable. Most live on an external drive; when it is absent the coverage
  # shortfall is printed rather than quietly shrinking the surface.
  if (!is.null(recov) && length(recov$files)) {
    rg <- list()
    for (f in recov$files) {
      z <- readRDS(f)
      if (!inherits(z, "sf") || !nrow(z)) next
      zk <- sprintf("%.6f_%.6f", as.numeric(z$center_lat), as.numeric(z$center_lng))
      bcol <- intersect(c("drive_time_minutes", "contour"), names(z))[1]
      keep <- which(zk %in% recov$keys & as.numeric(z[[bcol]]) == b)
      if (!length(keep)) next
      gg <- suppressWarnings(sf::st_transform(sf::st_geometry(z)[keep], 4326))
      rg[[f]] <- sf::st_make_valid(gg)
    }
    if (length(rg)) {
      parts$recovered <- do.call(c, unname(rg))
      cat(sprintf("[%smin] recovered polygons     : %s\n", b, length(parts$recovered)))
    }
    rm(rg); invisible(gc())
  }

  areas <- vapply(parts, function(p)
    sum(as.numeric(sf::st_area(p))) / 1e6, numeric(1))

  all_g <- do.call(c, unname(parts))
  cat(sprintf("[%smin] dissolving %s polygons ...\n", b, length(all_g)))

  # BATCHED dissolve. A single st_union() over the whole mixed set silently
  # dropped about 7% of the osm.de polygons: their coverage was absent from the
  # result even though they were counted in n_origins_dissolved, so 130 midwives
  # fell outside a surface built from their own isochrones. Unioning osm.de
  # alone kept all 1,471, so the failure is in the large mixed dissolve, not the
  # inputs. Reducing in batches keeps each GEOS call small enough to be robust.
  bidx <- split(seq_along(all_g), ceiling(seq_along(all_g) / 250))
  bu <- lapply(bidx, function(i) sf::st_make_valid(sf::st_union(all_g[i])))
  u <- sf::st_make_valid(sf::st_union(do.call(c, bu)))
  rm(bu); invisible(gc())

  # OUTPUT ASSERTION. n_origins_dissolved counts what went IN; nothing checked
  # what came OUT, which is why the loss was invisible. Every input polygon must
  # be substantially represented in the dissolved surface.
  rp <- suppressWarnings(sf::st_point_on_surface(all_g))
  covered <- lengths(suppressMessages(sf::st_intersects(rp, u))) > 0
  n_lost <- sum(!covered)
  cat(sprintf("[%smin] containment check: %s of %s input polygons represented\n",
              b, format(sum(covered), big.mark = ","), format(length(all_g), big.mark = ",")))
  if (n_lost > 0) {
    stop(sprintf(paste0("[%smin] dissolve LOST %s of %s input polygons (%.1f%%).\n",
                        "  Their coverage is absent from the union while still being counted ",
                        "in n_origins_dissolved, so the surface understates access and the ",
                        "origin count overstates it."),
                 b, format(n_lost, big.mark = ","), format(length(all_g), big.mark = ","),
                 100 * n_lost / length(all_g)), call. = FALSE)
  }

  # THE PRIVACY ASSERTION. If the dissolve ever yields more than one feature,
  # the output is per-origin geometry and must not be written.
  stopifnot(length(u) == 1L)

  out <- sf::st_sf(band_minutes = b,
                   n_origins_dissolved = length(all_g),
                   area_km2 = round(as.numeric(sf::st_area(u)) / 1e6, 1),
                   ec2_input_area_km2 = round(areas[["ec2"]], 1),
                   osmde_input_area_km2 = round(areas[["osmde"]], 1),
                   recovered_input_area_km2 =
                     if ("recovered" %in% names(areas)) round(areas[["recovered"]], 1) else 0,
                   routing_engines = "EC2-Valhalla + valhalla1.openstreetmap.de",
                   geometry = u)
  saveRDS(out, file.path(OUTDIR, sprintf("midwifery_isochrone_union_%dmin.rds", b)))
  cat(sprintf("[%smin] dissolved area: %s km2\n", b,
              format(round(out$area_km2), big.mark = ",")))
  out
}

unions <- lapply(BANDS, band_union)
names(unions) <- as.character(BANDS)

# --- nesting: a smaller band must lie inside every larger one ----------------
# haa_dissolve_isochrones() in mufflyt/isochrones enforces this by cumulative
# union, ascending. Dissolving each band independently -- which this script did
# -- guarantees nothing, and with two routing engines whose polygons disagree
# by up to 15% in area it is a live risk, not a theoretical one: a 30-minute
# surface can escape its own 60-minute surface where the engines differ.
for (i in seq_along(BANDS)[-1]) {
  a <- as.character(BANDS[i]); b <- as.character(BANDS[i - 1])
  before <- as.numeric(sf::st_area(unions[[a]])) / 1e6
  g <- sf::st_union(sf::st_geometry(unions[[a]]), sf::st_geometry(unions[[b]]))
  sf::st_geometry(unions[[a]]) <- sf::st_make_valid(g)
  after <- as.numeric(sf::st_area(unions[[a]])) / 1e6
  cat(sprintf("[nesting] %smin absorbed %smin: %s -> %s km2 (+%.2f%%)\n",
              a, b, format(round(before), big.mark = ","),
              format(round(after), big.mark = ","),
              100 * (after - before) / before))
}

# --- clip to land ------------------------------------------------------------
# The surfaces previously ran over the Great Lakes, because they were clipped to
# the union of county polygons and counties extend into open water. Reported
# coverage area therefore counted water nobody drives across.
#
# Masks load through load_water_mask() from mufflyt/isochrones (cached,
# geometry-validated, CRS-matched). build_water_mask_and_clip() would be the
# fuller canonical path but requires a coastline layer we do not have here, and
# clip_isochrone_to_land() is per-state while these surfaces are national and
# already dissolved.
water_dir <- "/Volumes/MufflySamsung/nhdplus_hr/water_masks"
if (dir.exists(water_dir)) {
  local({
    owd <- setwd(path.expand("~/isochrones-main")); on.exit(setwd(owd), add = TRUE)
    suppressWarnings(suppressMessages(
      sys.source(file.path("R", "canonical_water_mask_loader.R"), envir = globalenv())))
  })
  # ALL of CONUS_STATE_ABBR, including DC. An earlier version excluded DC for
  # no reason, so the Potomac and Anacostia stayed counted as drivable ground.
  # A hand-written exception to a canonical constant is exactly the kind of
  # edit that survives review because it looks like housekeeping.
  states <- mufflyaccess::CONUS_STATE_ABBR
  cat(sprintf("loading water masks for %s states ...\n", length(states)))
  wm <- lapply(states, function(st) {
    f <- file.path(water_dir, sprintf("%s_water_mask.fgb", st))
    if (!file.exists(f)) return(NULL)
    g <- tryCatch(suppressWarnings(sf::st_geometry(sf::st_read(f, quiet = TRUE))),
                  error = function(e) NULL)
    if (is.null(g)) return(NULL)
    suppressWarnings(sf::st_transform(g, 4326))
  })
  names(wm) <- states
  failed <- states[vapply(wm, is.null, logical(1))]
  wm <- Filter(Negate(is.null), wm)

  # INVERSION GATE. A "water mask" covering most of its state is not water --
  # it is the state outline, and subtracting it erases every isochrone there.
  # WV, MO, IA, AR and KS each carried a single-feature mask of 102-104% of
  # their land area, which silently deleted all midwife coverage in five states
  # and made 400 midwives appear to have no isochrone. The cause is upstream:
  # the high-resolution downloader logged "Empty response, assuming complete"
  # and a fallback wrote the state boundary as the mask.
  #
  # Excluded rather than fatal: refusing to build would block the map on data we
  # cannot regenerate here, and a surface that includes some open water in five
  # states is far better than one that erases those states entirely. The
  # exclusion is printed, never silent.
  # Canonical guard (mysterymaps_guard_water_masks). A mask larger than 5x its
  # state's census water area is a state outline, not water, and subtracting it
  # erases every isochrone in that state -- silently, because removing too much
  # geometry does not error and leaves no hole a reader would recognise.
  # See docs/HALL_OF_SHAME.md #14.
  st_geo <- tigris::states(cb = TRUE, year = 2023, progress_bar = FALSE)
  water_km2 <- stats::setNames(as.numeric(st_geo$AWATER) / 1e6, st_geo$STUSPS)
  wm <- mysterymaps::mysterymaps_guard_water_masks(wm, water_km2)
  cat(sprintf("water masks usable: %s of %s states\n", length(wm), length(states)))
  cat(sprintf("water masks loaded: %s of %s states\n", length(wm), length(states)))
  # A mask that fails to read leaves that state's water counted as land. Silence
  # here would look identical to success, so it is an error, not a warning.
  if (length(failed))
    stop("water masks missing or unreadable for: ", paste(failed, collapse = ", "),
         " -- their water would be counted as drivable ground.", call. = FALSE)
  if (length(wm)) {
    water <- sf::st_make_valid(do.call(c, wm))
    water <- sf::st_union(water)
    for (b in names(unions)) {
      before <- as.numeric(sf::st_area(unions[[b]])) / 1e6
      g <- suppressWarnings(sf::st_difference(
        sf::st_make_valid(sf::st_geometry(unions[[b]])), water))
      sf::st_geometry(unions[[b]]) <- sf::st_make_valid(g)
      after <- as.numeric(sf::st_area(unions[[b]])) / 1e6
      unions[[b]]$area_km2 <- round(after, 1)
      unions[[b]]$water_removed_km2 <- round(before - after, 1)
      cat(sprintf("[land clip] %smin: %s -> %s km2 (water removed %s)\n", b,
                  format(round(before), big.mark = ","),
                  format(round(after), big.mark = ","),
                  format(round(before - after), big.mark = ",")))
    }
    rm(water, wm); invisible(gc())
  }
} else {
  cat("WATER MASKS NOT REACHABLE -- surfaces still include open water; areas overstated\n")
}

for (b in names(unions))
  saveRDS(unions[[b]], file.path(OUTDIR,
          sprintf("midwifery_isochrone_union_%smin.rds", b)))

# --- 3. simplify for the browser --------------------------------------------
# Analysis geometry is saved above at full resolution; only the web copy is
# simplified. Conflating the two is how a map ends up disagreeing with a table.
simplify_for_web <- function(u) {
  if (!requireNamespace("rmapshaper", quietly = TRUE)) return(u)
  s <- rmapshaper::ms_simplify(u, keep = SIMPLIFY_KEEP, keep_shapes = TRUE)
  sf::st_make_valid(s)
}
web <- lapply(unions, simplify_for_web)

# --- 4. county choropleth: midwives per 1,000 births -------------------------
sup <- read_csv("artifacts/county_midwifery_supply.csv", show_col_types = FALSE) %>%
  mutate(fips = str_pad(as.character(fips), 5, "left", "0"))
cty <- suppressMessages(
  tigris::counties(cb = TRUE, resolution = "20m", year = 2023, progress_bar = FALSE)) %>%
  sf::st_transform(4326) %>%
  mutate(fips = GEOID) %>%
  left_join(sup %>% select(fips, county_name_base, state, midwives_per_1k_births,
                           study_midwives, births_used, rurality),
            by = "fips")
cty <- suppressWarnings(rmapshaper::ms_simplify(cty, keep = 0.05, keep_shapes = TRUE))

pal <- leaflet::colorBin("viridis", domain = cty$midwives_per_1k_births,
                         bins = c(0, 0.5, 1, 2, 3, 5, 10, Inf),
                         na.color = "#e0e0e0")

lab <- sprintf(
  "<strong>%s, %s</strong><br/>%s midwives<br/>%s births<br/><b>%s</b> per 1,000 births<br/><em>%s</em>",
  cty$county_name_base, cty$state,
  ifelse(is.na(cty$study_midwives), "-", cty$study_midwives),
  ifelse(is.na(cty$births_used), "-", format(round(cty$births_used), big.mark = ",")),
  ifelse(is.na(cty$midwives_per_1k_births), "suppressed (<50 births)",
         cty$midwives_per_1k_births),
  ifelse(is.na(cty$rurality), "", cty$rurality)) %>% lapply(htmltools::HTML)

m <- leaflet::leaflet(options = leaflet::leafletOptions(minZoom = 3)) %>%
  leaflet::addProviderTiles("CartoDB.PositronNoLabels", group = "Basemap") %>%
  leaflet::addPolygons(data = cty, fillColor = ~pal(midwives_per_1k_births),
                       weight = 0.3, color = "#ffffff", fillOpacity = 0.75,
                       label = lab, group = "Midwives per 1,000 births",
                       highlightOptions = leaflet::highlightOptions(
                         weight = 2, color = "#333", bringToFront = TRUE)) %>%
  leaflet::addPolygons(data = web[["60"]], fillColor = "#2c7fb8", color = "#2c7fb8",
                       weight = 1, fillOpacity = 0.30,
                       group = "Within 60 minutes") %>%
  leaflet::addPolygons(data = web[["30"]], fillColor = "#253494", color = "#253494",
                       weight = 1, fillOpacity = 0.45,
                       group = "Within 30 minutes") %>%
  leaflet::addProviderTiles("CartoDB.PositronOnlyLabels", group = "Basemap") %>%
  leaflet::addLegend(position = "bottomright", pal = pal,
                     values = cty$midwives_per_1k_births,
                     title = "Midwives per<br/>1,000 births", opacity = 0.85) %>%
  leaflet::addLayersControl(
    overlayGroups = c("Within 30 minutes", "Within 60 minutes",
                      "Midwives per 1,000 births"),
    options = leaflet::layersControlOptions(collapsed = FALSE)) %>%
  leaflet::setView(-96, 38.5, zoom = 4)

# The caveats travel WITH the map. A reader who opens the HTML without the
# README must still learn that the surface mixes routing engines, that the
# engine split is rural-selective, and that no individual location is shown.
note <- sprintf(
  '<div style="position:fixed;bottom:12px;left:12px;z-index:1000;background:rgba(255,255,255,.94);
   padding:9px 12px;font:11px/1.45 system-ui,sans-serif;max-width:390px;
   border:1px solid #bbb;border-radius:4px">
   <b>Drive-time access to certified nurse-midwives</b><br/>
   Dissolved coverage surface: shaded ground lies within the stated drive time of
   at least one ACTIVE AMCB-certified, primary-linked midwife. <b>Individual
   practice locations are not shown and cannot be recovered from this map.</b><br/>
   Assembled from two routing engines &mdash; EC2 Valhalla (%s km&sup2; input at 30 min)
   and the public osm.de server (%s km&sup2;). <b>Engine calibration (n=88 shared
   origins):</b> median IoU is stable across the rural gradient (30&nbsp;min
   0.80/0.79/0.78 metro/adjacent/remote; 60&nbsp;min 0.86/0.85/0.85), but the
   area ratio drifts with rurality at 30&nbsp;min (0.85 metro &rarr; 1.09 remote),
   so the 30-minute surface is relatively <em>more</em> generous in rural areas.
   Do not read a rural gradient off the 30-minute band. Bands 30/60 only. County shading is midwives per 1,000 births
   (AHRF/NCHS denominator; counties under 50 births suppressed).
   </div>',
  format(unions[["30"]]$ec2_input_area_km2, big.mark = ","),
  format(unions[["30"]]$osmde_input_area_km2, big.mark = ","))
m <- htmlwidgets::prependContent(m, htmltools::HTML(note))

out_html <- file.path(OUTDIR, "midwifery_access_map.html")
htmlwidgets::saveWidget(m, out_html, selfcontained = TRUE, title =
                          "Drive-time access to certified nurse-midwives")
cat(sprintf("\nwritten: %s (%.1f MB)\n", out_html,
            file.size(out_html) / 1024^2))
cat("Dissolved union only. No per-midwife geometry written or rendered.\n")
