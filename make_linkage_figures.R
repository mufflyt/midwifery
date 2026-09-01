#!/usr/bin/env Rscript
#' @title Figures: what linkage did, and what it licenses
#'
#' @description
#' The study's binding limitation had no figure. The cohort flow shows where
#' records went; these two show the consequence -- that linkage is selected on
#' certification status, and how far the located geography can therefore be from
#' the roster.
#'
#' Both read the stats catalog, so neither can drift from the artifacts the
#' manuscript reports. Print-safe: white ground, one accent that survives
#' greyscale because it also differs in shape and weight.
#'
#' Output: docs/figures/linkage_by_status.{pdf,png,svg}
#'         docs/figures/selection_bounds.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(tidyr)})
source(file.path("manuscript", "R", "build_stats_catalog.R"))
source(file.path("manuscript", "R", "inline_stats.R"))
mw_init_stats(".")

INK <- "#111820"; MUT <- "#5b6875"; RULE <- "#c8d0d9"; ACC <- "#1f6360"; SOFT <- "#e9f1f0"
# fig_num rather than NUM: ci_hygiene H4 forbids a top-level function defined in
# two tracked files, and make_cohort_flow_figure.R already defines NUM. Two
# figure scripts needing the same one-line accessor is a hint it belongs in the
# catalog's own API, not in each caller -- noted rather than done here, because
# moving it touches a file the manuscript renders from.
fig_num <- function(k) suppressWarnings(as.numeric(mw_stat(k, "%f")))

base_theme <- theme_minimal(base_size = 10) +
  theme(panel.grid.minor = element_blank(),
        panel.grid.major.y = element_blank(),
        panel.grid.major.x = element_line(colour = RULE, linewidth = .3),
        axis.title = element_text(colour = MUT, size = 9),
        axis.text = element_text(colour = INK),
        plot.title = element_text(face = "bold", size = 11.5, colour = INK),
        plot.subtitle = element_text(colour = MUT, size = 9, lineheight = 1.15),
        plot.caption = element_text(colour = MUT, size = 7.5, hjust = 0, lineheight = 1.2),
        plot.title.position = "plot", plot.caption.position = "plot",
        legend.position = "top", legend.title = element_blank(),
        legend.text = element_text(colour = INK, size = 8.5))

save3 <- function(p, base, w, h) {
  dir.create(dirname(base), showWarnings = FALSE, recursive = TRUE)
  ggsave(paste0(base, ".pdf"), p, width = w, height = h, device = if (capabilities("cairo")) cairo_pdf else pdf)
  ggsave(paste0(base, ".png"), p, width = w, height = h, dpi = 300, bg = "white")
  if (requireNamespace("svglite", quietly = TRUE))
    ggsave(paste0(base, ".svg"), p, width = w, height = h)
  message(sprintf("written: %s.{pdf,png,svg}", base))
}

# --- 1. linkage is selected on certification status --------------------------
# TWO RATES, SHOWN AS A SEGMENT rather than two bars. The gap between them IS
# the cross-taxonomy rule, and a dumbbell makes the gap the mark; grouped bars
# would make it something the reader has to subtract.
lc <- read_csv(file.path("artifacts", "linkage_completeness_by_status.csv"),
               show_col_types = FALSE, progress = FALSE)
st <- lc |>
  mutate(resolution = 100 * matched / n,
         ascertainment = 100 * (matched + matched_nursing_taxonomy) / n) |>
  filter(n >= 100) |>
  arrange(resolution) |>
  mutate(status = factor(status, levels = status),
         lab = sprintf("%s  (n = %s)", status, formatC(n, format = "d", big.mark = ",")))
st$lab <- factor(st$lab, levels = st$lab)

p1 <- ggplot(st) +
  geom_segment(aes(y = lab, yend = lab, x = resolution, xend = ascertainment),
               colour = RULE, linewidth = 2.4, lineend = "round") +
  geom_point(aes(y = lab, x = ascertainment, shape = "Ascertainment: found in the registry at all"),
             colour = ACC, fill = "white", size = 3, stroke = 1.1) +
  geom_point(aes(y = lab, x = resolution, shape = "Cohort resolution: midwifery taxonomy"),
             colour = INK, size = 2.9) +
  geom_text(aes(y = lab, x = resolution, label = sprintf("%.1f", resolution)),
            hjust = 1.35, size = 2.9, colour = INK) +
  geom_text(aes(y = lab, x = ascertainment, label = sprintf("%.1f", ascertainment)),
            hjust = -0.35, size = 2.9, colour = ACC) +
  scale_shape_manual(values = c("Cohort resolution: midwifery taxonomy" = 16,
                                "Ascertainment: found in the registry at all" = 21)) +
  scale_x_continuous(limits = c(10, 95), breaks = seq(20, 90, 10),
                     labels = function(x) paste0(x, "%")) +
  labs(title = "Linkage is selected on certification status",
       subtitle = "The gap between the two marks is the cross-taxonomy rule: a nursing-only match is found\nbut is not promoted into the primary midwifery cohort.",
       x = "Percentage of certificants", y = NULL,
       caption = "Certification statuses with at least 100 certificants. Providers who left the workforce are\nsubstantially less likely to appear, which is the study's binding limitation.") +
  base_theme
save3(p1, file.path("docs", "figures", "linkage_by_status"), 7.2, 3.4)

# --- 2. what the located geography licenses ----------------------------------
# ORDERED BY ASSUMPTION, weakest at the top, because that is the axis the reader
# is actually choosing along. The observed point is drawn on every row so the
# widening is visible as distance from one fixed mark.
obs <- fig_num("bounds.metro_pct")
bd <- tibble::tribble(
  ~label,                                              ~lo,                              ~hi,
  "Bounds, no assumptions",                            fig_num("bounds.lower_pct"),          fig_num("bounds.upper_pct"),
  "Bounds, discarding locatable non-cohort records",   fig_num("bounds.manski_lower_pct"),   fig_num("bounds.manski_upper_pct"),
  "Bounds, ACTIVE certificants only",                  fig_num("bounds.active_lower_pct"),   fig_num("bounds.active_upper_pct")
) |> mutate(label = factor(label, levels = rev(label)))

pts <- tibble::tribble(
  ~label,                                   ~x,                          ~what,
  "Observed in the cohort",                 obs,                         "Observed",
  "Inverse-probability weighted",           fig_num("bounds.ipw_pct"),       "Sensitivity",
  "Non-cohort records that could be placed", fig_num("bounds.outside_pct"),  "Sensitivity"
) |> mutate(label = factor(label, levels = rev(label)))

p2 <- ggplot() +
  geom_vline(xintercept = obs, colour = ACC, linetype = "22", linewidth = .4) +
  geom_segment(data = bd, aes(y = label, yend = label, x = lo, xend = hi),
               colour = ACC, linewidth = 5, lineend = "round", alpha = .28) +
  geom_point(data = bd, aes(y = label, x = lo), colour = ACC, size = 2.2) +
  geom_point(data = bd, aes(y = label, x = hi), colour = ACC, size = 2.2) +
  geom_text(data = bd, aes(y = label, x = lo, label = sprintf("%.1f", lo)),
            hjust = 1.3, size = 2.8, colour = ACC) +
  geom_text(data = bd, aes(y = label, x = hi, label = sprintf("%.1f", hi)),
            hjust = -0.3, size = 2.8, colour = ACC) +
  geom_point(data = pts, aes(y = label, x = x), colour = INK, size = 2.9) +
  # LEFT OF THE POINT, not above it. The reference line sits at the observed
  # value, so a label centred above a point near that value is bisected by it.
  geom_text(data = pts, aes(y = label, x = x, label = sprintf("%.1f", x)),
            hjust = 1.35, size = 2.8, colour = INK) +
  scale_x_continuous(limits = c(60, 100), breaks = seq(60, 100, 5),
                     labels = function(x) paste0(x, "%")) +
  labs(title = "Metropolitan share: what the located cohort licenses about the roster",
       subtitle = sprintf("Dashed line is the share observed among the %s cohort members with an assignable county.\nIntervals are roster-wide and make no assumption about why geography is missing.",
                          mw_n("cohort.known_n")),
       x = "Metropolitan share of the roster", y = NULL,
       caption = sprintf("Discarding the %s non-cohort certificants whose ZIP does resolve widens the interval without adding\ncaution; they are %.1f%% metropolitan, below the cohort rather than above it. For the roster-wide share to\nreach 75%%, the unobserved would have to be %.1f%% metropolitan -- a %.1f-point departure.",
                         mw_n("bounds.outside_n"), fig_num("bounds.outside_pct"),
                         fig_num("bounds.tip_required"), fig_num("bounds.tip_departure"))) +
  base_theme
save3(p2, file.path("docs", "figures", "selection_bounds"), 7.6, 3.8)
