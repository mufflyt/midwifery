#!/usr/bin/env Rscript
#' @title Figure: migration spikes, NPPES alone vs. every truth-fusion method
#'
#' @description
#' The single scientific question this build exists to answer: do the
#' 2017->2018 and 2023->2024 move-rate spikes survive when the state used
#' for each NPI-year comes from a multi-source truth-fusion estimate
#' instead of raw NPPES alone? Reads the aggregate (no NPI column)
#' artifacts/migration_rate_by_method.csv build_migration_rate_by_method.R
#' already wrote -- this script only renders it.
#'
#' Aggregate input, aggregate output: both the backing CSV and this figure
#' carry year-transition-level counts only, so both are publishable.
#'
#' Output: docs/figures/migration_rate_by_method.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr)})

RATES_CSV <- file.path("artifacts", "migration_rate_by_method.csv")
OUT <- file.path("docs", "figures", "migration_rate_by_method")

if (!file.exists(RATES_CSV))
  stop("Missing ", RATES_CSV, " -- run build_migration_rate_by_method.R first.", call. = FALSE)

d <- read_csv(RATES_CSV, show_col_types = FALSE) %>%
  mutate(
    method = factor(method, levels = c("nppes_raw", "majority", "dawid_skene", "one_coin_dawid_skene",
                                        "sums", "average_log", "investment", "pooled_investment", "truthfinder")),
    method = forcats::fct_na_value_to_level(method, "other")
  ) %>% filter(!is.na(method))

p <- ggplot(d, aes(x = year_to, y = pct_moved, color = method, group = method)) +
  geom_rect(data = d %>% filter(is_spike_transition) %>% distinct(year_to),
            aes(xmin = year_to - 0.5, xmax = year_to + 0.5, ymin = -Inf, ymax = Inf),
            inherit.aes = FALSE, fill = "#E8D6CF", alpha = 0.5) +
  geom_line(linewidth = 0.6, alpha = 0.85) +
  geom_point(size = 1.4) +
  scale_color_viridis_d(name = "State estimate", end = 0.92) +
  labs(
    title = "Do the 2017–18 and 2023–24 migration spikes survive multi-source truth fusion?",
    subtitle = "Shaded columns mark the two spike transitions. Each line uses that method's own state estimate and its own (non-abstained) denominator.",
    x = "Transition (ending year)", y = "% of NPI-years with a state change"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "right")

ggsave(paste0(OUT, ".pdf"), p, width = 10, height = 5.6, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 10, height = 5.6, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 10, height = 5.6),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
