#!/usr/bin/env Rscript
#' @title Figure: independent corroboration rate, spike transitions vs. controls
#'
#' @description
#' docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md already shows the two
#' spike transitions (2017->2018, 2023->2024) have an elevated raw move rate.
#' This figure answers a different question: of the NPIs that moved in each
#' transition, what share does an external source (DAC, PECOS, or Open
#' Payments) corroborate -- and is that rate any different for the spikes
#' than for the four control transitions
#' docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md S4b already used for
#' comparison? Reads the aggregate (no NPI column) summary CSV
#' audit_migration_corroboration_by_transition.R already wrote -- this script
#' only renders it.
#'
#' Aggregate input, aggregate output: both the backing CSV and this figure
#' carry transition-level counts only, so both are publishable.
#'
#' Output: docs/figures/migration_corroboration_by_transition.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr)})

SUMMARY_CSV <- file.path("artifacts", "migration_corroboration_summary_by_transition.csv")
OUT <- file.path("docs", "figures", "migration_corroboration_by_transition")

if (!file.exists(SUMMARY_CSV))
  stop("Missing ", SUMMARY_CSV, " -- run audit_migration_corroboration_by_transition.R first.", call. = FALSE)

d <- read_csv(SUMMARY_CSV, show_col_types = FALSE) %>%
  mutate(
    transition = sprintf("%d→%d", year_from, year_to),
    transition = factor(transition, levels = transition[order(year_from)]),
    group = factor(tools::toTitleCase(group), levels = c("Spike", "Control"))
  )

p <- ggplot(d, aes(x = transition, y = any_corrob_pct_of_movers, fill = group)) +
  geom_col(width = 0.6) +
  geom_errorbar(aes(ymin = any_corrob_ci_low, ymax = any_corrob_ci_high), width = 0.15, linewidth = 0.4) +
  scale_fill_manual(values = c(Spike = "#B4473E", Control = "#6B7A8F"), name = NULL) +
  labs(
    title = "Independent corroboration of NPPES state moves is driven by source coverage, not spike status",
    subtitle = "Share of movers each transition where DAC, PECOS revalidation, or Open Payments confirms both the old and new state (95% Wilson CI)",
    x = NULL, y = "% of movers corroborated by ≥1 external source"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11), legend.position = "top")

ggsave(paste0(OUT, ".pdf"), p, width = 8.6, height = 5.4, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 8.6, height = 5.4, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 8.6, height = 5.4),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
