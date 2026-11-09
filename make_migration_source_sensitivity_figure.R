#!/usr/bin/env Rscript
#' @title Figure 3: source-family sensitivity -- how much each family moves the needle
#'
#' @description
#' audit_migration_source_sensitivity.R already compares each "drop one
#' family" leave-one-out variant against the full baseline two ways: how
#' many predicted states change, and how much each transition's move rate
#' shifts. This figure renders both as one two-panel chart, ordered by
#' prediction-change magnitude so NPPES's outsized role is immediately
#' visible. Reads the aggregate (no NPI column) summary CSV that script
#' already wrote -- this script only renders it.
#'
#' Aggregate input, aggregate output: both the backing CSV and this
#' figure carry source-family-level counts only, so both are publishable.
#'
#' Output: docs/figures/migration_source_sensitivity.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(patchwork)})

SUMMARY_CSV <- file.path("artifacts", "migration_source_sensitivity_summary.csv")
OUT <- file.path("docs", "figures", "migration_source_sensitivity")

if (!file.exists(SUMMARY_CSV))
  stop("Missing ", SUMMARY_CSV, " -- run audit_migration_source_sensitivity.R first.", call. = FALSE)

FAMILY_LABELS <- c(nppes = "NPPES", dac_pecos_combined = "DAC + PECOS", open_payments = "Open Payments",
                    tmsis_medicaid = "T-MSIS Medicaid", facility_affiliation = "Facility affiliation")

d <- read_csv(SUMMARY_CSV, show_col_types = FALSE) %>%
  mutate(family_label = factor(FAMILY_LABELS[excluded_family], levels = FAMILY_LABELS[excluded_family][order(pct_changed_value)]))

p1 <- ggplot(d, aes(x = family_label, y = pct_changed_value)) +
  geom_col(fill = "#4A6B8A", width = 0.65) +
  geom_text(aes(label = sprintf("%.2f%%", pct_changed_value)), hjust = -0.15, size = 3) +
  coord_flip(clip = "off") +
  labs(title = "Predicted state changed when this family is excluded", x = NULL, y = "% of comparable npi-years") +
  theme_minimal(base_size = 10) + theme(plot.title = element_text(face = "bold", size = 9.5)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.18)))

p2 <- ggplot(d, aes(x = family_label, y = mean_abs_rate_change_pts, fill = mean_signed_rate_change_pts > 0)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = sprintf("%+.2f", mean_signed_rate_change_pts)), hjust = -0.15, size = 3) +
  scale_fill_manual(values = c(`TRUE` = "#B4473E", `FALSE` = "#2E8B57"), guide = "none") +
  coord_flip(clip = "off") +
  labs(title = "Mean absolute change in move rate (label = signed, pts)", x = NULL, y = "mean absolute change (points)") +
  theme_minimal(base_size = 10) + theme(plot.title = element_text(face = "bold", size = 9.5)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.25)))

p <- p1 + p2 +
  plot_annotation(
    title = "NPPES dominates the fused model by roughly an order of magnitude over every other source",
    subtitle = "Leave-one-source-family-out sensitivity, dawid_skene method, 2013-2026 (red = excluding this family pushes the rate up; green = pushes it down)",
    theme = theme(plot.title = element_text(face = "bold", size = 11))
  )

ggsave(paste0(OUT, ".pdf"), p, width = 10.5, height = 4.6, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 10.5, height = 4.6, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 10.5, height = 4.6),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
