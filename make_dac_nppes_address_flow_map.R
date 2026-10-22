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
source(file.path("R", "lib", "work_site_topology.R"))  # haversine_km()

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
  required_cols <- c("npi", "year", "source", "nppes_city", "nppes_state", "nppes_lon", "nppes_lat",
                     "comparison_city", "comparison_state", "comparison_lon", "comparison_lat")
  missing_cols <- setdiff(required_cols, names(address_pairs))
  if (length(missing_cols) > 0) stop("Missing columns: ", paste(missing_cols, collapse = ", "))
  if (min_flow_n < 1) stop("min_flow_n must be at least one")

  rows <- address_pairs %>%
    mutate(npi = as.character(npi), year = as.integer(year), source = as.character(source),
          across(c(nppes_city, nppes_state, comparison_city, comparison_state),
                 ~ str_to_upper(str_squish(as.character(.x))))) %>%
    filter(year == study_year, source %in% c("DAC", "Open Payments"))
  cli_alert_info("Rows after year/source filtering: {nrow(rows)}")

  dupes <- rows %>% count(npi, year, source) %>% filter(n > 1)
  if (nrow(dupes) > 0) stop("Duplicate NPI/year/source records -- resolve before mapping.")

  # Distance (km, haversine_km() from R/lib/work_site_topology.R) -- used to
  # catch city-name SPELLING variants (SAINT PAUL vs ST PAUL, GEORGETOWN vs
  # GEORGE TOWN) that geocode to the identical building but fail a
  # string-equality city test. Found by inspecting this map's own output:
  # 5.2% of string-different-city pairs geocode within 0.5 km of each other
  # -- including the single largest flow in an early draft of this map
  # (LARGO -> UPPER MARLBORO, n=8, verified identical coordinates).
  # Classifying by distance instead of city-string equality is only
  # possible here because this script has actual coordinates; the main
  # comparison pipeline (compare_dac_openpayments_to_nppes_address.R) is
  # string-only by necessity -- it never geocodes -- so its city-level
  # agreement numbers are NOT corrected by this and may undercount
  # agreement by a similar margin. Not fixed there as part of this map.
  SAME_PLACE_KM <- 1  # same tolerance R/lib/geocode_conflicts.R uses for "same rooftop, different precision"

  comparable <- rows %>%
    filter(!is.na(nppes_lon), !is.na(nppes_lat), !is.na(comparison_lon), !is.na(comparison_lat),
          nzchar(nppes_city), nzchar(comparison_city), nzchar(nppes_state), nzchar(comparison_state),
          between(nppes_lon, -180, 180), between(comparison_lon, -180, 180),
          between(nppes_lat, -90, 90), between(comparison_lat, -90, 90)) %>%
    mutate(
      dist_km = haversine_km(nppes_lat, nppes_lon, comparison_lat, comparison_lon),
      mismatch_type = case_when(
        dist_km < SAME_PLACE_KM ~ "Same city",
        nppes_state != comparison_state ~ "Different state",
        nppes_city != comparison_city ~ "Different city, same state",
        TRUE ~ "Same city"
      ))
  cli_alert_info("Geocoded comparable records: {nrow(comparable)}")
  cli_alert_info("Reclassified as same place despite differing city string (<{SAME_PLACE_KM}km apart): {sum(comparable$dist_km < SAME_PLACE_KM & comparable$nppes_city != comparable$comparison_city)}")

  mismatches <- comparable %>% filter(mismatch_type != "Same city")
  if (colorado_only) mismatches <- mismatches %>% filter(nppes_state == "CO" | comparison_state == "CO")
  if (nrow(mismatches) == 0) stop("No geographic mismatches to display")
  cli_alert_info("Different-city/state records: {nrow(mismatches)}")

  # A city-pair is a flow, not an individual practitioner -- aggregating here
  # is also what makes min_flow_n an effective disclosure control below.
  flow_pairs <- mismatches %>%
    group_by(source, nppes_state, nppes_city, comparison_state, comparison_city, mismatch_type) %>%
    summarise(n_midwives = n_distinct(npi),
             origin_lon = median(nppes_lon), origin_lat = median(nppes_lat),
             destination_lon = median(comparison_lon), destination_lat = median(comparison_lat),
             .groups = "drop")
  cli_alert_info("Distinct city-to-city flows: {nrow(flow_pairs)}")

  mapped_flows <- flow_pairs %>% filter(n_midwives >= min_flow_n)
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

  national <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 5L, colorado_only = FALSE)
  print(as.data.frame(national$summary))
  colorado <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 2L, colorado_only = TRUE)
  print(as.data.frame(colorado$summary))

  # Track only the aggregated, disclosure-controlled flow table -- no
  # individual coordinates, min_flow_n already applied in national$flows'
  # upstream filter is NOT applied here, so re-derive at the same threshold
  # used for the national map before writing.
  tracked <- national$flows %>% dplyr::filter(n_midwives >= 5L)
  write_with_provenance(tracked, "artifacts/dac_vs_nppes_address_flows.csv",
                        inputs = "artifacts/dac_vs_nppes_address_pairs.csv")
}
