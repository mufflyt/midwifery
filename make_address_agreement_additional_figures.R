#!/usr/bin/env Rscript
# =============================================================================
# Three more views of the DAC / Open Payments / NPPES address comparison
# =============================================================================
# Re-plots the existing pairwise comparison artifact
# (artifacts/dac_openpayments_vs_nppes_address_agreement.csv, written by
# compare_dac_openpayments_to_nppes_address.R) from three different angles.
#
# A fourth figure here used to compute three-way (NPPES x DAC x Open
# Payments) concordance. Removed 2026-10-22: it necessarily paired DAC's
# single 2026 vintage against each Open Payments year (2022-2024), which is
# never a year match -- same problem as the pairwise DAC-vs-Open-Payments
# comparison this script's sibling script dropped for the same reason.
# "Every analysis needs to be year matched" is a hard rule in this project;
# see git history for the removed figure/computation and
# docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for why.
#
# Inputs : artifacts/dac_openpayments_vs_nppes_address_agreement.csv (tracked)
# Outputs: docs/figures/address_agreement_heatmap.png
#          docs/figures/address_agreement_cascade.png
#          docs/figures/address_agreement_power.png
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
  library(ggplot2); library(scales); library(cli)
})

dir.create("docs/figures", showWarnings = FALSE, recursive = TRUE)

COMPARISON_LABELS <- c(
  vs_nppes_same_year = "vs. NPPES (same year)",
  open_payments_yoy = "Open Payments vs. itself"
)

# =============================================================================
# A-C: re-plot the existing pairwise agreement table
# =============================================================================
IN <- "artifacts/dac_openpayments_vs_nppes_address_agreement.csv"
stopifnot(file.exists(IN))
d <- read_csv(IN, show_col_types = FALSE)
d$level <- factor(d$level, levels = c("state", "city", "zip5", "street"),
                   labels = c("State", "City", "ZIP5", "Street"))

cli_alert_info("A. Heatmap: every source pair x every geographic level")
heat <- ggplot(d, aes(x = level, y = source_pair, fill = agree_pct)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = sprintf("%.0f%%", agree_pct)), size = 3) +
  facet_grid(rows = vars(comparison_type), scales = "free_y", space = "free_y",
             labeller = labeller(comparison_type = COMPARISON_LABELS)) +
  scale_fill_distiller(palette = "RdYlBu", direction = 1, limits = c(0, 100), name = "Agreement %") +
  labs(title = "Every source pair, every geographic level, one view",
       subtitle = "DAC / Open Payments / NPPES address agreement (%)",
       x = NULL, y = NULL,
       caption = "See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for n per cell.") +
  theme_minimal(base_size = 11) +
  theme(strip.text.y = element_text(angle = 0, size = 8, face = "bold"),
        panel.grid = element_blank())
ggsave("docs/figures/address_agreement_heatmap.png", heat, width = 9, height = 6.5, dpi = 200)

cli_alert_info("B. Cascade: agreement by geographic grain, every source pair")
cascade <- ggplot(d, aes(x = level, y = agree_pct, group = source_pair, color = comparison_type)) +
  geom_line(alpha = 0.85, linewidth = 0.7) +
  geom_point(size = 1.8) +
  scale_color_brewer(palette = "Dark2", name = NULL, labels = COMPARISON_LABELS) +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0.02, 0.05))) +
  labs(title = "Agreement falls apart at finer geography -- for every source pair",
       subtitle = "Each line is one source-pair/year comparison, State through Street",
       x = NULL, y = "Agreement (%)") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave("docs/figures/address_agreement_cascade.png", cascade, width = 9, height = 6, dpi = 200)

cli_alert_info("C. Power check: agreement vs. how many records it's based on")
power <- ggplot(d, aes(x = comparable_n, y = agree_pct, color = level, size = comparable_n)) +
  geom_point(alpha = 0.75) +
  scale_x_log10(labels = comma) +
  scale_size_continuous(range = c(2, 8), guide = "none") +
  scale_y_continuous(limits = c(0, 100)) +
  scale_color_brewer(palette = "Set1", name = "Level") +
  labs(title = "No headline number in this comparison rests on a tiny sample",
       subtitle = "Every row of the agreement table, by how many comparable records it's based on",
       x = "Comparable records (log scale)", y = "Agreement (%)") +
  theme_minimal(base_size = 12)
ggsave("docs/figures/address_agreement_power.png", power, width = 8.5, height = 6, dpi = 200)

cli::cli_alert_success("wrote 3 figures to docs/figures/")
