#!/usr/bin/env Rscript
# =============================================================================
# make_access_stack_slide.R -- The access stack, bottom to top (CONUS)
# =============================================================================
# Adapted from ~/isochrones/scripts/create_layered_access_stack.R: that script
# draws Virginia as five exploded oblique plates (women 40+, terrain, roads,
# urogynecologists, drive-time bands) using an align-then-oblique-project
# affine transform so every plate sits on one shared plane.
#
# This version keeps the core trick -- rotate, squash vertically, offset each
# plate upward -- but drops what doesn't fit this project:
#   * ONE STATE -> CONUS. This project's unit is the nation, not a state, so
#     there is no minimum-bounding-rectangle axis search to do (that exists
#     in the original only because Virginia is an awkward triangle).
#   * Women 40+ -> women 15-44. The isochrones project studies pelvic floor
#     disorders (women 40+ is its epidemiological denominator); this one
#     studies births, whose denominator is reproductive-age women, already
#     the field Table 1 and the county supply artifact use.
#   * Terrain is dropped; it needs live AWS elevation-tile downloads this
#     project has no use for, and the original only draws it as orientation.
#   * Roads are reduced to INTERSTATES ONLY, drawn on the drive-time plate
#     rather than as their own plate. The original's full primary+secondary
#     network needs a per-state tigris::primary_secondary_roads() loop and
#     exists mainly to give an otherwise-empty terrain plate something to
#     show; here the one plate that actually needs road context is the
#     drive-time plate itself, so the overlay lives there. tigris::
#     primary_roads() is a single nationwide file -- no per-state loop.
#   * The provider plate is COUNTY-AGGREGATE points, not one dot per midwife.
#     map_midwife_geography.R's rule applies here too: a dot map is for
#     internal QA only, never a slide that leaves the room.
#   * The drive-time plate reuses the already-dissolved 30/60-minute union
#     polygons render_midwifery_map.R draws on the published leaflet map --
#     NOT a live Valhalla routing call. Routing the canonical 3,909 origins
#     fresh is a multi-hour job; the dissolved unions are the artifact that
#     routing produced, already committed, already the public figure's data.
#
# Plates, bottom to top:
#   5  Drive time to a midwife               30/60-min isochrone union, nested,
#                                             with an interstate overlay for orientation
#   4  Rurality (RUCC 2023)                  categorical choropleth
#   3  Certified midwives                    county points, sized by count
#   2  Obstetric hospitals                   one dot per hospital
#   1  Women aged 15-44 (ACS)                the denominator, areal choropleth
#
# Inputs (all already in this repo -- nothing downloaded beyond the cached
# tigris counties geometry, nothing routed beyond what's already committed):
#   artifacts/county_midwifery_supply.csv          women_15_44, study_midwives, rucc
#   artifacts/ob_hospitals_geocoded.csv            hospital lat/long
#   artifacts/maps/midwifery_isochrone_union_30min.rds
#   artifacts/maps/midwifery_isochrone_union_60min.rds
#
# Output: docs/figures/access_stack_conus.png
#         docs/figures/access_stack_conus_no_hospitals.png   with --no-hospitals
# Usage:  Rscript make_access_stack_slide.R [--no-hospitals]
#   --no-hospitals  drop plate 2 (obstetric hospitals) and renumber the rest,
#                   as an options variant for a deck that wants a leaner stack
# =============================================================================

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(ggplot2)
})
sf::sf_use_s2(FALSE)

NO_HOSP <- "--no-hospitals" %in% commandArgs(trailingOnly = TRUE)
OUT <- if (NO_HOSP) "docs/figures/access_stack_conus_no_hospitals.png" else "docs/figures/access_stack_conus.png"
dir.create(dirname(OUT), recursive = TRUE, showWarnings = FALSE)

# Plate indices -- hospitals occupy slot 1 only when included; everything
# above it shifts down one slot when they're dropped, so plate thickness and
# spacing stay identical between the two versions.
idx_mw   <- if (NO_HOSP) 1L else 2L
idx_rucc <- if (NO_HOSP) 2L else 3L
idx_iso  <- if (NO_HOSP) 3L else 4L
max_idx  <- idx_iso

# ---- data ------------------------------------------------------------------
supply <- read_csv("artifacts/county_midwifery_supply.csv", show_col_types = FALSE,
                   col_types = cols(fips = col_character())) %>%
  mutate(fips = sprintf("%05s", fips))

counties <- suppressMessages(tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  filter(!STATEFP %in% c("02", "15", "60", "66", "69", "72", "78")) %>% # CONUS only
  st_transform(5070) %>%
  left_join(supply, by = c("GEOID" = "fips"))

hosp <- read_csv("artifacts/ob_hospitals_geocoded.csv", show_col_types = FALSE) %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  st_as_sf(coords = c("longitude", "latitude"), crs = 4326) %>%
  st_transform(5070) %>%
  st_filter(st_union(st_geometry(counties)))

mw_pts <- counties %>%
  filter(!is.na(study_midwives), study_midwives > 0) %>%
  st_centroid()

conus_outline <- st_union(st_geometry(counties))
iso30 <- suppressWarnings(st_intersection(
  st_make_valid(st_transform(readRDS("artifacts/maps/midwifery_isochrone_union_30min.rds"), 5070)),
  conus_outline))
iso60 <- suppressWarnings(st_intersection(
  st_make_valid(st_transform(readRDS("artifacts/maps/midwifery_isochrone_union_60min.rds"), 5070)),
  conus_outline))

# Interstates only, as orientation for the drive-time plate -- the thing a
# viewer's eye uses to tell "no coverage because remote" from "no coverage
# despite a highway running right through it". A single nationwide tigris
# file, cached after the first run; no per-state loop.
options(tigris_use_cache = TRUE)
interstates <- suppressMessages(tigris::primary_roads(progress_bar = FALSE)) %>%
  filter(RTTYP == "I") %>%
  st_transform(5070) %>%
  st_filter(conus_outline)

# ---- the shared oblique transform -------------------------------------------
# Rotate th degrees, then squash vertically by `squash` -- one matrix for
# every plate and every layer within it, so nothing drifts off-plane.
th <- 12 * pi / 180
squash <- 0.52
M <- matrix(c(cos(th), sin(th), -sin(th), cos(th)), 2, 2) %*% matrix(c(1, 0, 0, squash), 2, 2)

tilt <- function(geom, dy = 0) {
  out <- st_geometry(geom) * M
  st_crs(out) <- NA
  out + c(0, dy)
}

GAP <- 2.6e6 # vertical spacing between plates, in projected (5070) metres

plate_outline <- tilt(st_union(st_geometry(counties)), 0)

# A single ggplot cannot carry two independent `fill` legends (one continuous,
# one categorical) without the ggnewscale package, which isn't installed here.
# Every plate's fill is therefore pre-computed to a literal hex colour and
# drawn with scale_fill_identity() -- one shared, legend-free scale -- with a
# hand-drawn key per plate instead of an automatic colourbar/legend.
RUCC_COLORS <- c("Metro (RUCC 1-3)" = "#1B5E20",
                 "Nonmetro, adjacent (RUCC 4-6)" = "#F9A825",
                 "Nonmetro, remote (RUCC 7-9)" = "#B71C1C")
# sqrt-transformed domain: Los Angeles County alone (2.07M) is ~2 orders of
# magnitude above a typical rural county, and a linear scale washes every
# other county to white. Same fix map_midwife_geography.R uses (trans="sqrt").
women_rng <- range(counties$women_15_44, na.rm = TRUE)
women_pal <- scales::col_numeric("BuPu", domain = sqrt(women_rng), na.color = "grey92")

# ---- build the four plates ---------------------------------------------------
p <- ggplot()

# Plate 1 (bottom): women 15-44, continuous choropleth
women_sf <- st_sf(geometry = tilt(st_geometry(counties), 0 * GAP),
                  fill_hex = women_pal(sqrt(counties$women_15_44)))
p <- p +
  geom_sf(data = women_sf, aes(fill = fill_hex), colour = NA)

# Plate 2: obstetric hospitals, points on a faint outline -- omitted entirely
# under --no-hospitals rather than drawn empty, so the options version has no
# dead plate sitting in the stack.
if (!NO_HOSP) {
  p <- p +
    geom_sf(data = st_sf(geometry = tilt(st_geometry(counties), 1 * GAP)),
           fill = "grey97", colour = "grey85", linewidth = 0.1) +
    geom_sf(data = st_sf(geometry = tilt(st_geometry(hosp), 1 * GAP)),
           colour = "#1565C0", size = 0.35, alpha = 0.55)
}

# Plate: midwives, county-aggregate points sized by count (never person-level)
p <- p +
  geom_sf(data = st_sf(geometry = tilt(st_geometry(counties), idx_mw * GAP)),
         fill = "grey97", colour = "grey85", linewidth = 0.1) +
  geom_sf(data = st_sf(geometry = tilt(st_geometry(mw_pts), idx_mw * GAP),
                       n = mw_pts$study_midwives),
         aes(size = n), colour = "#6A1B9A", alpha = 0.55) +
  scale_size_area(max_size = 3.2, name = "Midwives\n(county n)", guide = guide_legend(order = 1))

# Plate: rurality, categorical
rucc_sf <- st_sf(geometry = tilt(st_geometry(counties), idx_rucc * GAP),
                 fill_hex = ifelse(is.na(counties$rurality), "grey90",
                                   RUCC_COLORS[counties$rurality]))
p <- p +
  geom_sf(data = rucc_sf, aes(fill = fill_hex), colour = NA) +
  scale_fill_identity()

# Plate (top): drive-time isochrones -- 60-min band first, then the 30-min
# band nested on top of it, so the plate reads as two concentric reaches
# rather than one flat fill.
p <- p +
  geom_sf(data = st_sf(geometry = tilt(st_geometry(counties), idx_iso * GAP)),
         fill = "grey97", colour = "grey90", linewidth = 0.1) +
  geom_sf(data = st_sf(geometry = tilt(iso60, idx_iso * GAP)), fill = "#90CAF9", colour = NA) +
  geom_sf(data = st_sf(geometry = tilt(iso30, idx_iso * GAP)), fill = "#1565C0", colour = NA) +
  geom_sf(data = st_sf(geometry = tilt(st_geometry(interstates), idx_iso * GAP)),
         colour = "#B71C1C", linewidth = 0.22, alpha = 0.75)

# Plate outlines, drawn last per plate index so they sit visibly on each other
for (i in (if (NO_HOSP) c(0L, idx_mw, idx_rucc, idx_iso) else 0:max_idx)) {
  p <- p + geom_sf(data = st_sf(geometry = tilt(st_union(st_geometry(counties)), i * GAP)),
                   fill = NA, colour = "grey40", linewidth = 0.25)
}

# Hand-drawn keys, right of the plates they belong to -- replacing the
# automatic colourbar/legend scale_fill_identity() gives up.
rx <- st_bbox(plate_outline)[["xmax"]] + 3e5
y0 <- mean(st_bbox(tilt(st_union(st_geometry(counties)), 0 * GAP))[c("ymin", "ymax")])
grad_y <- seq(y0 - 5e5, y0 + 5e5, length.out = 20)
grad_col <- women_pal(seq(sqrt(women_rng[1]), sqrt(women_rng[2]), length.out = 20))
# Tick labels at round NATURAL values, positioned by their sqrt-transformed
# location along the same gradient -- not evenly spaced, because the scale
# underneath them isn't.
tick_vals <- c(0, 10000, 50000, 250000, round(women_rng[2], -3))
tick_y <- scales::rescale(sqrt(tick_vals), to = range(grad_y), from = sqrt(women_rng))
p <- p +
  annotate("point", x = rep(rx, 20), y = grad_y, colour = grad_col, size = 4, shape = 15) +
  annotate("text", x = rx + 1.5e5, y = tick_y,
          label = formatC(tick_vals, format = "d", big.mark = ","),
          hjust = 0, size = 2.6, colour = "grey30")

y_rucc <- mean(st_bbox(tilt(st_union(st_geometry(counties)), idx_rucc * GAP))[c("ymin", "ymax")])
rucc_y <- y_rucc + c(5e5, 0, -5e5)
p <- p +
  annotate("point", x = rep(rx, 3), y = rucc_y, colour = RUCC_COLORS, size = 4, shape = 15) +
  annotate("text", x = rx + 1.5e5, y = rucc_y, label = names(RUCC_COLORS),
          hjust = 0, size = 2.8, colour = "grey30")

y_iso <- mean(st_bbox(tilt(st_union(st_geometry(counties)), idx_iso * GAP))[c("ymin", "ymax")])
iso_y <- y_iso + c(3.5e5, 0.5e5, -2.5e5)
iso_colors <- c("Within 30 min" = "#1565C0", "31-60 min" = "#90CAF9", "Interstate" = "#B71C1C")
p <- p +
  annotate("point", x = rep(rx, 3), y = iso_y, colour = iso_colors, size = 4, shape = 15) +
  annotate("text", x = rx + 1.5e5, y = iso_y, label = names(iso_colors),
          hjust = 0, size = 2.8, colour = "grey30")

# Plate labels, left of each plate -- numbered 1..n over whichever plates are
# actually present, so --no-hospitals reads "1 2 3 4" with no gap at "2".
plate_specs <- list(
  list(idx = 0L, include = TRUE,
      text = "Women aged 15-44 (ACS)\n    the denominator"),
  list(idx = 1L, include = !NO_HOSP,
      text = "Obstetric hospitals\n    one dot per facility"),
  list(idx = idx_mw, include = TRUE,
      text = "Certified midwives\n    county-aggregate, never person-level"),
  list(idx = idx_rucc, include = TRUE,
      text = "Rurality (RUCC 2023)\n    context for every plate below"),
  list(idx = idx_iso, include = TRUE,
      text = "Drive time to a midwife\n    30/60-min union, with interstates for orientation")
)
plate_specs <- Filter(function(s) s$include, plate_specs)

lab_x <- st_bbox(plate_outline)[["xmin"]] - 6e5
labels_df <- data.frame(
  y = sapply(plate_specs, function(s) mean(st_bbox(tilt(st_union(st_geometry(counties)), s$idx * GAP))[c("ymin", "ymax")])),
  label = sprintf("%d  %s", seq_along(plate_specs), vapply(plate_specs, `[[`, character(1), "text")))

p <- p +
  annotate("text", x = lab_x, y = labels_df$y, label = labels_df$label,
          hjust = 1, size = 3.4, lineheight = 1.05, colour = "grey20") +
  coord_sf(clip = "off") +
  labs(title = "The Access Stack, Bottom to Top",
      subtitle = "Each plate the same counties, in a different layer -- CONUS, excluding AK/HI/territories") +
  theme_void(base_size = 12) +
  theme(plot.background = element_rect(fill = "white", colour = NA),
       plot.title = element_text(face = "bold", size = 16, hjust = 0.5),
       plot.subtitle = element_text(size = 10.5, colour = "grey40", hjust = 0.5, margin = margin(b = 6)),
       plot.margin = margin(14, 70, 10, 160),
       legend.position = "right")

ggsave(OUT, p, width = 11.5, height = if (NO_HOSP) 10 else 12, dpi = 220, bg = "white")
cat("wrote", OUT, "\n")
