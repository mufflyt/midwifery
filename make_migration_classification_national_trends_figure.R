#!/usr/bin/env Rscript
#' @title Figure 1: apparent vs. corroborated vs. unresolved interstate migration, 2013-2026
#'
#' @description
#' classify_migration_moves_full_panel.R already answers, per transition,
#' how much apparent NPPES interstate migration survives independent,
#' held-out corroboration. This figure renders that as three parallel
#' annual rates over the SAME denominator (eligible NPI-year pairs), so
#' "apparent" and "corroborated" are directly comparable, not apples to
#' oranges: apparent movers, confirmed movers (>=2 independent source
#' families, held out against a leave-one-out refit), and unresolved
#' pairs (abstained or genuinely conflicting evidence). Reads the
#' aggregate (no NPI column) summary CSV that script already wrote --
#' this script only renders it.
#'
#' Aggregate input, aggregate output: both the backing CSV and this
#' figure carry transition-level counts only, so both are publishable.
#'
#' Output: docs/figures/migration_classification_national_trends.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(tidyr)})

SUMMARY_CSV <- file.path("artifacts", "migration_move_classification_summary_by_transition.csv")
OUT <- file.path("docs", "figures", "migration_classification_national_trends")

if (!file.exists(SUMMARY_CSV))
  stop("Missing ", SUMMARY_CSV, " -- run classify_migration_moves_full_panel.R first.", call. = FALSE)

d <- read_csv(SUMMARY_CSV, show_col_types = FALSE) %>%
  mutate(
    transition = sprintf("%d→%d", year_from, year_to),
    transition = factor(transition, levels = transition[order(year_from)]),
    pct_apparent = round(100 * apparent_movers / eligible_pairs, 2),
    pct_confirmed_any = round(100 * (confirmed + confirmed_not_held_out) / eligible_pairs, 2),
    pct_unresolved = round(100 * indeterminate / eligible_pairs, 2)
  ) %>%
  select(transition, year_from, is_known_gap_transition, pct_apparent, pct_confirmed_any, pct_unresolved) %>%
  pivot_longer(c(pct_apparent, pct_confirmed_any, pct_unresolved), names_to = "series", values_to = "pct") %>%
  mutate(series = recode(series,
                          pct_apparent = "Apparent movers",
                          pct_confirmed_any = "Confirmed (≥2 independent families, held out)",
                          pct_unresolved = "Indeterminate"),
         series = factor(series, levels = c("Apparent movers", "Confirmed (≥2 independent families, held out)", "Indeterminate")))

gap_years <- d %>% filter(is_known_gap_transition) %>% distinct(year_from) %>% pull(year_from)

p <- ggplot(d, aes(x = year_from, y = pct, color = series, group = series)) +
  geom_rect(data = tibble(year_from = gap_years),
            aes(xmin = year_from - 0.5, xmax = year_from + 0.5, ymin = -Inf, ymax = Inf),
            inherit.aes = FALSE, fill = "#E8D6CF", alpha = 0.5) +
  geom_line(linewidth = 0.7, alpha = 0.9) +
  geom_point(size = 1.6) +
  scale_color_manual(values = c("Apparent movers" = "#4A6B8A", "Confirmed (≥2 independent families, held out)" = "#2E8B57",
                                 "Indeterminate" = "#8A6B4A"), name = NULL) +
  scale_x_continuous(breaks = unique(d$year_from), labels = unique(d$transition)) +
  labs(
    title = "Almost none of the apparent interstate migration in this cohort is independently confirmed",
    subtitle = "% of eligible NPI-year pairs, 2013-2026\nShaded columns: the two known >20-month NPPES snapshot-gap transitions (2017→18, 2023→24)",
    x = NULL, y = "% of eligible pairs"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
        axis.text.x = element_text(angle = 45, hjust = 1))

ggsave(paste0(OUT, ".pdf"), p, width = 9.5, height = 5.6, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 9.5, height = 5.6, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 9.5, height = 5.6),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
