#!/usr/bin/env Rscript
# =============================================================================
# Geographic mismatch flow map: NPPES practice address vs. DAC
# =============================================================================
# Curved origin-destination lines from each midwife's NPPES-reported practice
# city to her DAC-reported practice city, for the NPIs where the two
# disagree at city level or coarser. Same-city/exact-address disagreements
# are excluded from the main map -- restricting to city-level-or-greater
# keeps the map legible; exact-street disagreements within one city would
# otherwise produce dense, overlapping short lines that add noise, not
# signal. Line color encodes same-state-different-city vs. different-state;
# line thickness encodes how many midwives share that same city-to-city
# displacement (aggregated, not drawn as one line per person).
#
# Scope: DAC vs NPPES, 2026 only -- DAC has no other public vintage (see
# docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md §4). An
# Open-Payments-vs-NPPES panel is not built here: it would need Census
# geocoding of roughly 25,000-30,000 more addresses (Open Payments 2022-2024
# plus the matching NPPES snapshots), scoped out until this panel is
# validated. The facet by `source` is kept in the code so adding that panel
# later is a data change, not a rewrite.
#
# min_flow_n is a disclosure control as much as a legibility one: a flow of
# n=1 names a specific midwife's two addresses on a public map.
#
# Input : artifacts/dac_vs_nppes_address_pairs.csv (person-level, gitignored;
#           build_dac_nppes_address_flow_pairs.R)
# Output: docs/figures/dac_vs_nppes_address_flows_national_2026.png
#         docs/figures/dac_vs_nppes_address_flows_colorado_2026.png
#         artifacts/dac_vs_nppes_address_flows.csv (aggregated, tracked --
#           city-level flow counts only, no individual coordinates)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
  library(ggplot2); library(sf); library(tigris); library(cli)
})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "address_flow_helpers.R"))

options(tigris_use_cache = TRUE)

#' Build curved origin-destination flows between NPPES and a comparison source
#'
#' @param address_pairs One row per NPI/year/source; coordinate columns
#'   already geocoded (see build_dac_nppes_address_flow_pairs.R). Required
#'   columns: npi, year, source, nppes_city, nppes_state, nppes_lon,
#'   nppes_lat, comparison_city, comparison_state, comparison_lon,
#'   comparison_lat. source must be "DAC" or "Open Payments".
#' @param study_year Calendar year to display.
#' @param min_flow_n Minimum midwives sharing a city-to-city flow before it's
#'   drawn -- also a disclosure control, not just a legibility threshold.
#' @param colorado_only Restrict the basemap and flows to Colorado + its
#'   immediate neighbors.
#' @param save_dir Directory for the exported PNG.
#' @return list(plot, flows, summary, saved_path)
plot_midwife_address_flows <- function(address_pairs, study_year = 2026L, min_flow_n = 5L,
                                        colorado_only = FALSE, save_dir = "docs/figures") {
  validate_address_pairs_columns(address_pairs)
  if (min_flow_n < 1) stop("min_flow_n must be at least one")

  rows <- address_pairs %>%
    mutate(npi = as.character(npi), year = as.integer(year), source = as.character(source),
          across(c(nppes_city, nppes_state, comparison_city, comparison_state),
                 ~ str_to_upper(str_squish(as.character(.x))))) %>%
    filter(year == study_year, source %in% c("DAC", "Open Payments"))
  cli_alert_info("Rows after year/source filtering: {nrow(rows)}")
  check_no_duplicate_rows(rows)

  comparable <- valid_coordinate_rows(rows) %>%
    mutate(mismatch_type = classify_mismatch(nppes_lat, nppes_lon, nppes_city, nppes_state,
                                             comparison_lat, comparison_lon, comparison_city, comparison_state))
  cli_alert_info("Geocoded comparable records: {nrow(comparable)}")

  mismatches <- comparable %>% filter(mismatch_type != "Same city")
  if (colorado_only) mismatches <- mismatches %>% filter(nppes_state == "CO" | comparison_state == "CO")
  if (nrow(mismatches) == 0) stop("No geographic mismatches to display")
  cli_alert_info("Different-city/state records: {nrow(mismatches)}")

  flows <- aggregate_flows(mismatches, min_flow_n)
  flow_pairs <- flows$all
  mapped_flows <- flows$displayed
  cli_alert_info("Distinct city-to-city flows: {nrow(flow_pairs)}")
  cli_alert_info("Flows surviving min_flow_n={min_flow_n}: {nrow(mapped_flows)}")
  if (nrow(mapped_flows) == 0) stop("No flows meet min_flow_n -- inspect the flow table first.")

  # Quadratic-Bezier curve between two EPSG:5070-projected points, offset
  # perpendicular to the line so overlapping flows are visually separable.
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

  cli_alert_info("Preparing state boundary basemap")
  states <- tigris::states(cb = TRUE, year = 2023, class = "sf", progress_bar = FALSE) %>%
    filter(!STUSPS %in% c("AK", "HI", "PR", "VI", "GU", "MP", "AS")) %>%
    st_transform(5070)
  display_states <- if (colorado_only) {
    states %>% filter(STUSPS %in% c("CO", "WY", "UT", "NM", "AZ", "KS", "NE", "OK"))
  } else states

  origin_points <- st_transform(st_as_sf(mapped_flows, coords = c("origin_lon", "origin_lat"), crs = 4326), 5070)
  dest_points <- st_transform(st_as_sf(mapped_flows, coords = c("destination_lon", "destination_lat"), crs = 4326), 5070)

  p <- ggplot() +
    geom_sf(data = display_states, fill = "#F4F6F8", color = "#CBD5E1", linewidth = 0.25) +
    geom_sf(data = flow_map, aes(color = mismatch_type, linewidth = n_midwives), alpha = 0.48, lineend = "round") +
    geom_sf(data = origin_points, color = "#1D4ED8", size = 0.6, alpha = 0.5) +
    geom_sf(data = dest_points, color = "#111827", size = 0.6, alpha = 0.5) +
    facet_wrap(vars(source), ncol = 1) +
    scale_color_manual(values = c("Different city, same state" = "#0D9488", "Different state" = "#E76F51"),
                       name = "Type of mismatch") +
    scale_linewidth_continuous(range = c(0.25, 2.2), name = "Midwives per flow") +
    coord_sf(datum = NA) +
    labs(title = "Where NPPES and DAC disagree on practice location",
        subtitle = paste0("NPPES practice address vs. DAC (PECOS-derived), ", study_year, " -- both sources year-matched"),
        caption = paste0(
          "Each curve connects a reported NPPES city to DAC's city for the same NPI, same year.\n",
          "Only flows involving at least ", min_flow_n, " midwives are drawn (also a disclosure control).\n",
          "Same-city/exact-address disagreements are excluded here; see docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md.")) +
    theme_void(base_size = 11) +
    theme(plot.title = element_text(face = "bold", size = 17),
         plot.subtitle = element_text(color = "#475569", size = 11),
         strip.text = element_text(face = "bold", size = 12),
         legend.position = "bottom",
         plot.caption = element_text(color = "#64748B", hjust = 0),
         panel.spacing = unit(0.7, "cm"))

  summary_table <- tibble::tibble(
    study_year = study_year, input_rows = nrow(address_pairs), selected_rows = nrow(rows),
    comparable_rows = nrow(comparable), mismatch_rows = nrow(mismatches),
    total_flows = nrow(flow_pairs), displayed_flows = nrow(mapped_flows),
    displayed_midwife_pairs = sum(mapped_flows$n_midwives))

  dir.create(save_dir, recursive = TRUE, showWarnings = FALSE)
  scope_name <- if (colorado_only) "colorado" else "national"
  saved_path <- file.path(save_dir, sprintf("dac_vs_nppes_address_flows_%s_%s.png", scope_name, study_year))
  ggsave(saved_path, p, width = 11, height = 8, dpi = 200, bg = "white")
  cli_alert_success("wrote {saved_path}")

  list(plot = p, flows = flow_pairs, summary = summary_table, saved_path = saved_path)
}

if (sys.nframe() == 0) {
  IN <- "artifacts/dac_vs_nppes_address_pairs.csv"
  stopifnot(file.exists(IN))
  address_pairs <- read_csv(IN, show_col_types = FALSE)

  national <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 2L, colorado_only = FALSE)
  print(as.data.frame(national$summary))
  colorado <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 2L, colorado_only = TRUE)
  print(as.data.frame(colorado$summary))

  # Track only the aggregated, disclosure-controlled flow table -- no
  # individual coordinates, min_flow_n already applied in national$flows'
  # upstream filter is NOT applied here, so re-derive at the same threshold
  # used for the national map before writing.
  tracked <- national$flows %>% dplyr::filter(n_midwives >= 2L)
  write_with_provenance(tracked, "artifacts/dac_vs_nppes_address_flows.csv",
                        inputs = "artifacts/dac_vs_nppes_address_pairs.csv")
}
