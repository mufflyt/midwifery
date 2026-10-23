#!/usr/bin/env Rscript
# =============================================================================
# Geographic mismatch flow map: PECOS/DAC practice address vs. state BON
# =============================================================================
# Sibling of make_dac_nppes_address_flow_map.R, for the CO+CT state-board
# data compare_pecos_to_bon_address.R found a 7% ZIP5 agreement on. Curved
# origin-destination lines from each midwife's PECOS/DAC-reported practice
# city to her BON-reported city, for the NPIs where the two disagree at city
# level or coarser.
#
# ZIP5-CENTROID, NOT STREET-LEVEL -- see build_pecos_bon_address_flow_pairs.R
# for why. Flows here are coarser than the DAC/NPPES map's as a result.
#
# One map only (not a national + Colorado-zoomed pair like the DAC/NPPES
# script): CO and CT are the only two states in this data, so a Colorado-
# zoomed view and the national view would show nearly the same thing.
#
# min_flow_n=1: same public-data basis as make_dac_nppes_address_flow_map.R
# -- NPI is a public identifier and state board license data is public, so a
# flow of n=1 names a public provider's two publicly-reported addresses.
#
# Input : artifacts/pecos_vs_bon_address_pairs.csv (person-level, gitignored;
#           build_pecos_bon_address_flow_pairs.R)
# Output: docs/figures/pecos_vs_bon_address_flows_2026.png
#         artifacts/pecos_vs_bon_address_flows.csv (aggregated, tracked)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
  library(ggplot2); library(sf); library(tigris); library(cli)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_flow_helpers.R"))

options(tigris_use_cache = TRUE)

IN <- "artifacts/pecos_vs_bon_address_pairs.csv"
stopifnot(file.exists(IN))
address_pairs <- read_csv(IN, show_col_types = FALSE)

rows <- address_pairs %>%
  mutate(npi = as.character(npi), year = as.integer(year), source = as.character(source),
        across(c(nppes_city, nppes_state, comparison_city, comparison_state),
               ~ str_to_upper(str_squish(as.character(.x))))) %>%
  filter(year == 2026L, source == "BON")
cli_alert_info("Rows after year/source filtering: {nrow(rows)}")
check_no_duplicate_rows(rows)

comparable <- valid_coordinate_rows(rows) %>%
  mutate(mismatch_type = classify_mismatch(nppes_lat, nppes_lon, nppes_city, nppes_state,
                                           comparison_lat, comparison_lon, comparison_city, comparison_state),
        dist_km = haversine_km(nppes_lat, nppes_lon, comparison_lat, comparison_lon))
cli_alert_info("Zip5-geocoded comparable records: {nrow(comparable)}")

mismatches <- comparable %>% filter(mismatch_type != "Same city")
if (nrow(mismatches) == 0) stop("No geographic mismatches to display")
cli_alert_info("Different-city/state records: {nrow(mismatches)}")

flows <- aggregate_flows(mismatches, min_flow_n = 1L)
flow_pairs <- flows$all
mapped_flows <- flows$displayed
cli_alert_info("Distinct city-to-city flows: {nrow(flow_pairs)}")

# Quadratic-Bezier curve between two EPSG:5070-projected points, same as
# make_dac_nppes_address_flow_map.R's own make_curve() -- not extracted to
# the shared helper file since it's unchanged duplication of an already-small
# function, not new logic.
make_curve <- function(x1, y1, x2, y2) {
  dx <- x2 - x1; dy <- y2 - y1
  dist <- sqrt(dx^2 + dy^2)
  if (!is.finite(dist)) stop("Invalid projected flow coordinates")
  if (dist < 1) return(st_linestring(rbind(c(x1, y1), c(x2, y2))))
  curve_height <- 0.12 * dist
  cx <- (x1 + x2) / 2 - dy / dist * curve_height
  cy <- (y1 + y2) / 2 + dx / dist * curve_height
  t <- seq(0, 1, length.out = 40)
  curve_x <- (1 - t)^2 * x1 + 2 * (1 - t) * t * cx + t^2 * x2
  curve_y <- (1 - t)^2 * y1 + 2 * (1 - t) * t * cy + t^2 * y2
  st_linestring(cbind(curve_x, curve_y))
}

origin_xy <- st_coordinates(st_transform(st_as_sf(mapped_flows, coords = c("origin_lon", "origin_lat"),
                                                 crs = 4326, remove = FALSE), 5070))
dest_xy <- st_coordinates(st_transform(st_as_sf(mapped_flows, coords = c("destination_lon", "destination_lat"),
                                               crs = 4326, remove = FALSE), 5070))
geometries <- lapply(seq_len(nrow(mapped_flows)), function(i)
  make_curve(origin_xy[i, 1], origin_xy[i, 2], dest_xy[i, 1], dest_xy[i, 2]))
flow_map <- st_sf(mapped_flows, geometry = st_sfc(geometries, crs = 5070))

cli_alert_info("Preparing state boundary basemap (CO/CT + neighbors)")
states <- tigris::states(cb = TRUE, year = 2023, class = "sf", progress_bar = FALSE) %>%
  filter(STUSPS %in% c("CO", "WY", "UT", "NM", "AZ", "KS", "NE", "OK",
                       "CT", "NY", "MA", "RI")) %>%
  st_transform(5070)

origin_points <- st_transform(st_as_sf(mapped_flows, coords = c("origin_lon", "origin_lat"), crs = 4326), 5070)
dest_points <- st_transform(st_as_sf(mapped_flows, coords = c("destination_lon", "destination_lat"), crs = 4326), 5070)

p <- ggplot() +
  geom_sf(data = states, fill = "#F4F6F8", color = "#CBD5E1", linewidth = 0.25) +
  geom_sf(data = flow_map, aes(color = mismatch_type, linewidth = n_midwives), alpha = 0.55, lineend = "round",
         arrow = grid::arrow(length = unit(0.09, "inches"), type = "closed", ends = "last")) +
  geom_sf(data = origin_points, color = "#1D4ED8", size = 0.8, alpha = 0.6) +
  geom_sf(data = dest_points, color = "#111827", size = 0.8, alpha = 0.6) +
  scale_color_manual(values = c("Different city, same state" = "#0D9488", "Different state" = "#E76F51"),
                     name = "Type of mismatch") +
  scale_linewidth_continuous(range = c(0.3, 2.5), name = "Midwives per flow",
                             breaks = function(lims) sort(unique(round(scales::extended_breaks(n = 5)(lims))))) +
  coord_sf(datum = NA) +
  labs(title = "Where PECOS/DAC and state Boards of Nursing disagree on practice location",
      subtitle = paste0("PECOS/DAC practice address vs. CO+CT BON address, 2026 -- ZIP5-centroid, not street-level\n",
                        "n=", nrow(mismatches), " mismatches, CO's field is DORA's own mailing address (not practice)"),
      caption = paste0(
        "Each curve connects PECOS/DAC's reported city to the state board's city for the same NPI -- arrow points FROM PECOS/DAC TO BON.\n",
        "Same-city/exact-ZIP5 disagreements are excluded. See artifacts/pecos_vs_bon_address_agreement.csv for the underlying percentages.")) +
  theme_void(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 15),
       plot.subtitle = element_text(color = "#475569", size = 10.5),
       legend.position = "bottom",
       plot.caption = element_text(color = "#64748B", hjust = 0, size = 8))

dir.create("docs/figures", recursive = TRUE, showWarnings = FALSE)
OUT_PNG <- "docs/figures/pecos_vs_bon_address_flows_2026.png"
ggsave(OUT_PNG, p, width = 10, height = 7.5, dpi = 200, bg = "white")
cli_alert_success("wrote {OUT_PNG}")

tracked <- flow_pairs %>% filter(n_midwives >= 1L)
write_with_provenance(tracked, "artifacts/pecos_vs_bon_address_flows.csv", inputs = IN)
cli_alert_success("wrote artifacts/pecos_vs_bon_address_flows.csv")
