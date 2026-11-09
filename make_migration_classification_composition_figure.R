#!/usr/bin/env Rscript
#' @title Figure 2: classification composition of apparent moves, by transition
#'
#' @description
#' Figure 1 (migration_classification_national_trends) shows apparent vs.
#' confirmed vs. indeterminate as parallel rates over all eligible pairs.
#' This figure answers a narrower question: OF the apparent movers
#' specifically, what share of each transition lands in each of the 5
#' classification buckets classify_migration_moves_full_panel.R assigns --
#' confirmed, confirmed-but-not-held-out, possible, likely administrative
#' artifact, indeterminate. Reads the aggregate (no NPI column) summary CSV
#' that script already wrote -- this script only renders it.
#'
#' Aggregate input, aggregate output: both the backing CSV and this
#' figure carry transition-level counts only, so both are publishable.
#'
#' Output: docs/figures/migration_classification_composition.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(tidyr)})

SUMMARY_CSV <- file.path("artifacts", "migration_move_classification_summary_by_transition.csv")
OUT <- file.path("docs", "figures", "migration_classification_composition")

if (!file.exists(SUMMARY_CSV))
  stop("Missing ", SUMMARY_CSV, " -- run classify_migration_moves_full_panel.R first.", call. = FALSE)

CLASS_LEVELS <- c("confirmed", "confirmed_not_held_out", "possible", "administrative_artifact", "indeterminate")
CLASS_LABELS <- c(confirmed = "Confirmed (held out)", confirmed_not_held_out = "Confirmed (not held out)",
                   possible = "Possible", administrative_artifact = "Likely administrative artifact",
                   indeterminate = "Indeterminate")

d <- read_csv(SUMMARY_CSV, show_col_types = FALSE) %>%
  mutate(transition = sprintf("%d→%d", year_from, year_to),
         transition = factor(transition, levels = transition[order(year_from)])) %>%
  select(transition, year_from, apparent_movers, all_of(CLASS_LEVELS)) %>%
  pivot_longer(all_of(CLASS_LEVELS), names_to = "classification", values_to = "n") %>%
  mutate(pct = round(100 * n / apparent_movers, 2),
         classification = factor(CLASS_LABELS[classification], levels = CLASS_LABELS[CLASS_LEVELS]))

p <- ggplot(d, aes(x = transition, y = pct, fill = classification)) +
  geom_col(width = 0.72) +
  scale_fill_manual(values = c("Confirmed (held out)" = "#2E8B57", "Confirmed (not held out)" = "#8FBF9F",
                                "Possible" = "#B9B0A0", "Likely administrative artifact" = "#B4473E",
                                "Indeterminate" = "#6B7A8F"), name = NULL) +
  labs(
    title = "Within apparent moves, the 2 snapshot-gap transitions carry disproportionate artifact share",
    subtitle = "% of apparent movers per transition, 2013-2026",
    x = NULL, y = "% of apparent movers"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top",
        legend.text = element_text(size = 8), axis.text.x = element_text(angle = 45, hjust = 1))

ggsave(paste0(OUT, ".pdf"), p, width = 9.5, height = 5.8, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 9.5, height = 5.8, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 9.5, height = 5.8),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
