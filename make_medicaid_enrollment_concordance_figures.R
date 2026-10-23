#!/usr/bin/env Rscript
# =============================================================================
# Four figures for the Medicaid enrollment concordance analysis
# =============================================================================
# Reads only the tracked aggregate CSVs analyze_medicaid_enrollment_
# concordance.R and analyze_medicaid_2023_2024_transition_support.R write;
# draws no new numbers of its own and touches no person-level file.
#
#   Figure 1  State concordance matrix (heatmap)      -- real data
#   Figure 2  Geographic disagreement flow map         -- real data, suppressed
#   Figure 3  Enrollment-transition timeline            -- SCHEMATIC, not real
#   Figure 4  Concordance over time, both definitions   -- real data
#
# Input : artifacts/medicaid_enrollment_concordance_state_pairs.csv
#         artifacts/medicaid_enrollment_concordance_snapshot_date_by_year.csv
#         artifacts/medicaid_enrollment_concordance_any_time_by_year.csv
#         artifacts/medicaid_enrollment_concordance_denominators.csv
# Output: docs/figures/medicaid_concordance_matrix.png
#         docs/figures/medicaid_disagreement_flow_map.png
#         docs/figures/medicaid_transition_timeline_schematic.png
#         docs/figures/medicaid_concordance_over_time.png
# =============================================================================
suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(readr); library(tidyr)
})

dir.create("docs/figures", showWarnings = FALSE, recursive = TRUE)

SMALL_CELL_SUPPRESSION_THRESHOLD <- 5L  # same spirit as this repo's other
  # disclosure-control thresholds -- a cell too small to show without risking
  # re-identifying one or two clinicians' states is suppressed, not shown.

THEME <- theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 13),
        plot.subtitle = element_text(size = 9, color = "grey30"),
        plot.caption = element_text(size = 7, color = "grey40", hjust = 0),
        legend.position = "bottom", panel.grid.minor = element_blank())

# =============================================================================
# FIGURE 1: state concordance matrix
# =============================================================================
pairs <- readr::read_csv("artifacts/medicaid_enrollment_concordance_state_pairs.csv",
                         show_col_types = FALSE)
total_pairs <- sum(pairs$n_pairs)
total_provider_years <- sum(pairs$n_pairs[pairs$nppes_state == pairs$medicaid_state])  # lower bound note below

top_states <- pairs |> dplyr::group_by(.data$nppes_state) |>
  dplyr::summarise(total = sum(.data$n_pairs), .groups = "drop") |>
  dplyr::arrange(dplyr::desc(.data$total)) |> utils::head(20) |> dplyr::pull("nppes_state")

mat <- pairs |>
  dplyr::filter(.data$nppes_state %in% top_states, .data$medicaid_state %in% top_states)

p1 <- ggplot(mat, aes(x = medicaid_state, y = nppes_state, fill = n_pairs)) +
  geom_tile(color = "white") +
  geom_text(aes(label = n_pairs), size = 2.3,
           color = ifelse(mat$n_pairs > max(mat$n_pairs) * 0.4, "white", "black")) +
  scale_fill_gradient(low = "#eaf2f8", high = "#1b4f72", trans = "sqrt") +
  coord_fixed() +
  labs(title = "State concordance matrix: NPPES practice state vs. Medicaid enrollment state",
      subtitle = paste0(
        "Top 20 states by volume, snapshot-date (primary) definition, 2018-2024.\n",
        "The diagonal is same-state concordance. One provider-year contributes MORE THAN ONE cell exactly ",
        "when Multistate -- this is a cell/pair count, not a count of people."),
      x = "Medicaid enrollment state", y = "NPPES practice state", fill = "Pairs",
      caption = sprintf(
        "%s total (state, state) pairs from %s provider-years with both sources comparable.\nSee docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md.",
        format(total_pairs, big.mark = ","), format(sum(mat$n_pairs[mat$nppes_state == mat$medicaid_state]) , big.mark = ","))) +
  THEME +
  theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "right")
ggsave("docs/figures/medicaid_concordance_matrix.png", p1, width = 9, height = 8, dpi = 200)
cat("wrote docs/figures/medicaid_concordance_matrix.png\n")

# =============================================================================
# FIGURE 2: geographic disagreement flow map
# =============================================================================
# State centroids: base R's own state.center (48 contiguous + ... actually
# all 50 states) supplemented with DC/PR/VI/GU, which state.center does not
# carry. Standard public reference points, not derived from any project
# source.
state_centroids <- dplyr::bind_rows(
  tibble::tibble(state = state.abb, lon = state.center$x, lat = state.center$y),
  tibble::tribble(
    ~state, ~lon, ~lat,
    "DC", -77.0369, 38.9072,
    "PR", -66.5901, 18.2208,
    "VI", -64.8963, 18.3358,
    "GU", 144.7937, 13.4443))

discordant <- pairs |> dplyr::filter(.data$nppes_state != .data$medicaid_state)
n_discordant_pairs_total <- sum(discordant$n_pairs)

# A simple equirectangular centroid-to-centroid map cannot sanely place
# AK (far northwest), HI, PR, VI or GU (Pacific, positive longitude) on the
# same frame as the 48 contiguous states without either badly distorting
# the projection or drawing curves that exit and re-enter the visible area
# at a nonsensical angle (observed directly on a first draft that included
# GU: curves spanning -100 to +144 degrees longitude cut diagonally across
# the whole image). Restricted to the 48 contiguous states + DC for this
# figure only; the pairs this excludes are disclosed in the caption, not
# silently dropped from the underlying data (the full set remains in
# artifacts/medicaid_enrollment_concordance_state_pairs.csv).
CONUS_PLUS_DC <- setdiff(c(state.abb, "DC"), c("AK", "HI"))
state_centroids_conus <- state_centroids |> dplyr::filter(.data$state %in% CONUS_PLUS_DC)

discordant_excluded <- discordant |>
  dplyr::filter(!(.data$nppes_state %in% CONUS_PLUS_DC) | !(.data$medicaid_state %in% CONUS_PLUS_DC))
n_pairs_noncontiguous <- sum(discordant_excluded$n_pairs)

flows <- discordant |>
  dplyr::filter(.data$nppes_state %in% CONUS_PLUS_DC, .data$medicaid_state %in% CONUS_PLUS_DC,
               .data$n_pairs >= SMALL_CELL_SUPPRESSION_THRESHOLD) |>
  dplyr::inner_join(state_centroids_conus, by = c("nppes_state" = "state")) |>
  dplyr::rename(lon_from = "lon", lat_from = "lat") |>
  dplyr::inner_join(state_centroids_conus, by = c("medicaid_state" = "state")) |>
  dplyr::rename(lon_to = "lon", lat_to = "lat")
n_suppressed <- nrow(discordant) - nrow(discordant_excluded) - nrow(flows)
n_pairs_suppressed <- n_discordant_pairs_total - n_pairs_noncontiguous - sum(flows$n_pairs)

us_states_map <- tryCatch(ggplot2::map_data("state"), error = function(e) NULL)

p2 <- ggplot()
if (!is.null(us_states_map))
  p2 <- p2 + geom_polygon(data = us_states_map, aes(x = .data$long, y = .data$lat, group = .data$group),
                         fill = "#f4f6f7", color = "white", linewidth = 0.2)
p2 <- p2 +
  geom_curve(data = flows, aes(x = lon_from, y = lat_from, xend = lon_to, yend = lat_to,
                               linewidth = n_pairs, alpha = n_pairs),
            curvature = 0.2, color = "#c0392b") +
  geom_point(data = state_centroids_conus, aes(x = lon, y = lat), size = 0.6, color = "grey40") +
  scale_linewidth(range = c(0.2, 2.5), name = "Discordant pairs") +
  scale_alpha(range = c(0.3, 0.9), guide = "none") +
  coord_fixed(xlim = c(-125, -65), ylim = c(23, 50)) +
  labs(title = "Where NPPES and Medicaid enrollment disagree on state",
      subtitle = sprintf(
        "48 contiguous states + DC only (AK, HI, PR, VI, GU excluded -- a flat centroid-to-centroid map cannot place them\nwithout distortion; %s pairs, %s provider-years involving them are not shown here). Cells under %d pairs also suppressed\n(%s pairs, %s provider-years).",
        format(nrow(discordant_excluded), big.mark = ","), format(n_pairs_noncontiguous, big.mark = ","),
        SMALL_CELL_SUPPRESSION_THRESHOLD, format(n_suppressed, big.mark = ","), format(n_pairs_suppressed, big.mark = ",")),
      caption = sprintf("%s discordant (state, state) pairs total before any exclusion.\nSee docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md.",
                        format(n_discordant_pairs_total, big.mark = ","))) +
  THEME + theme(axis.text = element_blank(), axis.title = element_blank(),
               panel.grid = element_blank())
ggsave("docs/figures/medicaid_disagreement_flow_map.png", p2, width = 10, height = 6.5, dpi = 200)
cat("wrote docs/figures/medicaid_disagreement_flow_map.png\n")

# =============================================================================
# FIGURE 3: enrollment-transition timeline -- SCHEMATIC, illustrative only
# =============================================================================
window_start <- as.Date("2023-01-01"); window_end <- as.Date("2024-12-31")
schematic <- tibble::tribble(
  ~example, ~segment, ~start, ~end, ~kind,
  "Strong support",      "origin",      as.Date("2022-06-01"), as.Date("2023-08-31"), "Origin-state enrollment",
  "Strong support",      "destination", as.Date("2023-09-01"), as.Date("2024-12-31"), "Destination-state enrollment",
  "Partial support",     "origin",      as.Date("2022-06-01"), as.Date("2024-12-31"), "Origin-state enrollment",
  "Partial support",     "destination", as.Date("2023-09-01"), as.Date("2024-12-31"), "Destination-state enrollment",
  "Preexisting",         "origin",      as.Date("2022-01-01"), as.Date("2022-12-31"), "Origin-state enrollment",
  "Preexisting",         "destination", as.Date("2021-01-01"), as.Date("2024-12-31"), "Destination-state enrollment",
  "Contradictory",       "origin",      as.Date("2022-01-01"), as.Date("2024-12-31"), "Origin-state enrollment",
  "No evidence",         "unknown",     window_start, window_end, "No enrollment evidence")
schematic$example <- factor(schematic$example,
  levels = c("Strong support", "Partial support", "Preexisting", "Contradictory", "No evidence"))
kind_colors <- c("Origin-state enrollment" = "#aed6f1", "Destination-state enrollment" = "#c0392b",
                 "No enrollment evidence" = "#d5d8dc")

p3 <- ggplot(schematic, aes(y = example, x = start, xend = end)) +
  geom_segment(aes(x = start, xend = end, y = example, yend = example, color = kind),
              linewidth = 8, lineend = "butt") +
  geom_vline(xintercept = c(window_start, window_end), linetype = "dashed", color = "grey50") +
  scale_color_manual(values = kind_colors, name = NULL) +
  labs(title = "Enrollment-transition timeline: SCHEMATIC examples, not real provider data",
      subtitle = "Illustrates the five transition-support categories against a hypothetical 2023-2024 window\n(dashed lines). 'Multistate concordant' overlap is shown as simultaneous origin+destination bars.",
      x = NULL, y = NULL,
      caption = "Every bar here is a constructed example for illustration -- see\nR/lib/medicaid_state_concordance.R::classify_transition_support() for the actual rule, and\nartifacts/medicaid_2023_2024_transition_support_by_category.csv for real counts.") +
  THEME
ggsave("docs/figures/medicaid_transition_timeline_schematic.png", p3, width = 9, height = 5, dpi = 200)
cat("wrote docs/figures/medicaid_transition_timeline_schematic.png\n")

# =============================================================================
# FIGURE 4: concordance over time, both definitions, with 95% CI
# =============================================================================
wilson_ci_low <- function(x, n, z = 1.96) {
  p <- x / n; denom <- 1 + z^2 / n
  center <- (p + z^2 / (2 * n)) / denom
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  pmax(0, center - half)
}
wilson_ci_high <- function(x, n, z = 1.96) {
  p <- x / n; denom <- 1 + z^2 / n
  center <- (p + z^2 / (2 * n)) / denom
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  pmin(1, center + half)
}
load_concordance_rate <- function(path, label) {
  d <- readr::read_csv(path, show_col_types = FALSE)
  d |> dplyr::group_by(.data$year) |>
    dplyr::summarise(
      n_comparable = sum(.data$n[.data$classification %in%
        c("Concordant", "Discordant", "Multistate concordant", "Multistate discordant")]),
      n_concordant = sum(.data$n[.data$classification %in% c("Concordant", "Multistate concordant")]),
      .groups = "drop") |>
    dplyr::mutate(rate = .data$n_concordant / .data$n_comparable,
                 ci_low = wilson_ci_low(.data$n_concordant, .data$n_comparable),
                 ci_high = wilson_ci_high(.data$n_concordant, .data$n_comparable),
                 definition = label)
}
over_time <- dplyr::bind_rows(
  load_concordance_rate("artifacts/medicaid_enrollment_concordance_snapshot_date_by_year.csv",
                        "Snapshot-date (primary)"),
  load_concordance_rate("artifacts/medicaid_enrollment_concordance_any_time_by_year.csv",
                        "Any-time-in-year (secondary)"))

p4 <- ggplot(over_time, aes(x = year, y = rate, color = definition)) +
  geom_line(linewidth = 0.8) +
  geom_pointrange(aes(ymin = ci_low, ymax = ci_high), size = 0.4) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_color_manual(values = c("Snapshot-date (primary)" = "#1b4f72",
                                "Any-time-in-year (secondary)" = "#aed6f1")) +
  labs(title = "Medicaid-NPPES state concordance over time, among providers with both sources",
      subtitle = "Concordant + Multistate concordant, as a share of all providers with a comparable Medicaid\nrecord that year. Points are Wilson 95% CIs; denominators shrink in both directions over the series.",
      x = NULL, y = "Concordance rate", color = NULL,
      caption = "See artifacts/medicaid_enrollment_concordance_denominators.csv for the n behind every point.") +
  THEME
ggsave("docs/figures/medicaid_concordance_over_time.png", p4, width = 8.5, height = 6, dpi = 200)
cat("wrote docs/figures/medicaid_concordance_over_time.png\n")
