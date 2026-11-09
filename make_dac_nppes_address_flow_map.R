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
# min_flow_n=1 (set below, 2026-10-22 at the repo owner's request): every
# city-pair is drawn, including ones shared by exactly one midwife. NPPES
# and DAC are both public CMS data (NPI is a public identifier; per this
# project's own standing policy, NPI-level provider data is not treated as
# person-level-sensitive), so a flow of n=1 names a public provider's two
# publicly-reported addresses, not private information -- min_flow_n is
# kept as a parameter (legibility, not disclosure) rather than removed, so
# a future caller can still raise it.
#
# Input : artifacts/dac_vs_nppes_address_pairs.csv (person-level, gitignored;
#           build_dac_nppes_address_flow_pairs.R)
# Output: docs/figures/dac_vs_nppes_address_flows_national_2026.png
#         docs/figures/dac_vs_nppes_address_flows_colorado_2026.png
#         artifacts/dac_vs_nppes_address_flows.csv (aggregated, tracked --
#           city-level flow counts; at min_flow_n=1 a row can correspond to
#           one midwife's own two addresses, same public-data basis above)
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
#'   drawn. Default here is 1 (every flow) -- NPPES/DAC are public CMS data,
#'   see the file header.
#' @param colorado_only Restrict the basemap and flows to Colorado + its
#'   immediate neighbors.
#' @param save_dir Directory for the exported PNG.
#' @return list(plot, flows, summary, saved_path)
plot_midwife_address_flows <- function(address_pairs, study_year = 2026L, min_flow_n = 1L,
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

  # CONUS only: AK, HI, and PR are excluded from the basemap display anyway
  # (see tigris::states() filter below) -- excluding them from the data too,
  # not just the drawing, keeps a flow/distance from counting a record the
  # map could never show. A midwife with either address in one of these
  # drove the single largest outlier in the distance distribution (Anchorage
  # AK, 4,343 mi) -- genuine, not a bug, but out of scope for a CONUS map.
  NON_CONUS <- c("AK", "HI", "PR")
  pre_conus_n <- nrow(valid_coordinate_rows(rows))
  comparable <- valid_coordinate_rows(rows) %>%
    filter(!nppes_state %in% NON_CONUS, !comparison_state %in% NON_CONUS)
  cli_alert_info("Excluded for AK/HI/PR (CONUS only): {pre_conus_n - nrow(comparable)}")
  comparable <- comparable %>%
    mutate(mismatch_type = classify_mismatch(nppes_lat, nppes_lon, nppes_city, nppes_state,
                                             comparison_lat, comparison_lon, comparison_city, comparison_state),
          # Same haversine_km() classify_mismatch() uses internally, exposed
          # here as a column: the straight-line (great-circle) distance
          # between NPPES's and DAC's reported address for every record,
          # not just the ones that disagree at city level. "Straight line"
          # because that's what haversine computes -- not driving distance.
          dist_km = haversine_km(nppes_lat, nppes_lon, comparison_lat, comparison_lon))
  cli_alert_info("Geocoded comparable records: {nrow(comparable)}")

  mismatches <- comparable %>% filter(mismatch_type != "Same city")
  if (colorado_only) mismatches <- mismatches %>% filter(nppes_state == "CO" | comparison_state == "CO")
  if (nrow(mismatches) == 0) stop("No geographic mismatches to display")
  cli_alert_info("Different-city/state records: {nrow(mismatches)}")

  # Median +/- SD straight-line distance for exactly the pairs THIS map is
  # showing (CONUS, and CO-only when colorado_only) -- not the national
  # figure reused on the Colorado view. 1 km = 0.621371 mi, same conversion
  # the distance-distribution figure below uses.
  mismatches$dist_mi <- mismatches$dist_km * 0.621371
  dist_median_mi <- median(mismatches$dist_mi)
  dist_sd_mi <- sd(mismatches$dist_mi)

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
    geom_sf(data = flow_map, aes(color = mismatch_type, linewidth = n_midwives), alpha = 0.48, lineend = "round",
           arrow = grid::arrow(length = unit(0.09, "inches"), type = "closed", ends = "last")) +
    geom_sf(data = origin_points, color = "#1D4ED8", size = 0.6, alpha = 0.5) +
    geom_sf(data = dest_points, color = "#111827", size = 0.6, alpha = 0.5) +
    facet_wrap(vars(source), ncol = 1) +
    scale_color_manual(values = c("Different city, same state" = "#0D9488", "Different state" = "#E76F51"),
                       name = "Type of mismatch") +
    # Whole-number breaks: n_midwives is a count, "2.5 midwives" on the
    # legend is nonsensical. scale_linewidth_continuous's default
    # extended_breaks() doesn't know that, so round and dedupe its picks.
    scale_linewidth_continuous(range = c(0.25, 2.2), name = "Midwives per flow",
                               breaks = function(lims) sort(unique(round(scales::extended_breaks(n = 5)(lims))))) +
    coord_sf(datum = NA) +
    labs(title = "Where NPPES and DAC disagree on practice location",
        subtitle = paste0("NPPES practice address vs. DAC (PECOS-derived), ", study_year, " -- both sources year-matched\n",
                          "Straight-line distance: median ", round(dist_median_mi, 1), " mi ± ",
                          round(dist_sd_mi, 1), " mi (SD), n=", nrow(mismatches), " mismatches"),
        caption = paste0(
          "Each curve connects a reported NPPES city to DAC's city for the same NPI, same year -- the arrow points FROM NPPES TO DAC.\n",
          if (min_flow_n > 1) paste0("Only flows involving at least ", min_flow_n, " midwives are drawn.\n") else "",
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

  list(plot = p, flows = flow_pairs, summary = summary_table, saved_path = saved_path, mismatches = mismatches)
}

if (sys.nframe() == 0) {
  IN <- "artifacts/dac_vs_nppes_address_pairs.csv"
  stopifnot(file.exists(IN))
  address_pairs <- read_csv(IN, show_col_types = FALSE)

  national <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 1L, colorado_only = FALSE)
  print(as.data.frame(national$summary))
  colorado <- plot_midwife_address_flows(address_pairs, study_year = 2026L, min_flow_n = 1L, colorado_only = TRUE)
  print(as.data.frame(colorado$summary))

  # Track the aggregated flow table -- city-level, not individual
  # coordinates (median of whichever NPIs share that city-pair; at n=1
  # that's just the one NPI's own point). min_flow_n is applied in
  # national$flows' upstream filter but NOT re-applied here automatically,
  # so re-derive at the same threshold used for the national map.
  tracked <- national$flows %>% dplyr::filter(n_midwives >= 1L)
  write_with_provenance(tracked, "artifacts/dac_vs_nppes_address_flows.csv",
                        inputs = "artifacts/dac_vs_nppes_address_pairs.csv")

  # Straight-line (haversine) distance between NPPES's and DAC's reported
  # address for EVERY disparate (city-level-or-coarser mismatch) pair --
  # national scope, not Colorado-restricted. Individual distances stay in
  # memory/the gitignored mismatches table (person-level, same treatment as
  # address_pairs.csv); only the distribution's quantiles are tracked.
  # Reported in miles (1 km = 0.621371 mi) -- haversine_km() itself stays in
  # km, the unit R/lib/geocode_conflicts.R's own tolerances use; this is a
  # display-only conversion at the point this script reports the numbers.
  KM_TO_MI <- 0.621371
  national$mismatches$dist_mi <- national$mismatches$dist_km * KM_TO_MI
  d <- national$mismatches$dist_mi
  dist_summary <- tibble::tibble(
    n = length(d), min_mi = min(d), p25_mi = quantile(d, 0.25, names = FALSE),
    median_mi = median(d), p75_mi = quantile(d, 0.75, names = FALSE),
    p90_mi = quantile(d, 0.90, names = FALSE), max_mi = max(d), mean_mi = mean(d)) %>%
    mutate(across(-n, ~ round(.x, 1)))
  cli_alert_info("Straight-line distance, all {nrow(national$mismatches)} disparate pairs (national, miles):")
  print(as.data.frame(dist_summary))
  write_with_provenance(dist_summary, "artifacts/dac_vs_nppes_address_distance_summary.csv",
                        inputs = "artifacts/dac_vs_nppes_address_pairs.csv")

  dist_plot <- ggplot(national$mismatches, aes(x = dist_mi, fill = mismatch_type)) +
    geom_histogram(bins = 40, alpha = 0.8, position = "identity") +
    scale_x_log10(labels = scales::label_comma(), breaks = c(1, 10, 100, 1000, 3000)) +
    scale_fill_manual(values = c("Different city, same state" = "#0D9488", "Different state" = "#E76F51"),
                      name = "Type of mismatch") +
    labs(title = "How far apart are NPPES and DAC when they disagree?",
        subtitle = sprintf("Straight-line distance, all %s city-level-or-coarser mismatches (2026, DAC vs. NPPES)",
                           format(nrow(national$mismatches), big.mark = ",")),
        x = "Distance between NPPES and DAC addresses (miles, log scale)", y = "Number of midwives",
        caption = paste0(
          "Median ", round(dist_summary$median_mi, 1), " mi; 90th percentile ",
          round(dist_summary$p90_mi, 1), " mi; max ", round(dist_summary$max_mi, 0), " mi.\n",
          "Every disparate pair is included here, individually -- the map instead collapses them into ",
          nrow(tracked), " distinct city-to-city flows.")) +
    theme_minimal(base_size = 12)
  ggsave("docs/figures/dac_vs_nppes_address_distance_distribution.png", dist_plot,
        width = 9, height = 6, dpi = 200, bg = "white")
  cli_alert_success("wrote docs/figures/dac_vs_nppes_address_distance_distribution.png")
}
