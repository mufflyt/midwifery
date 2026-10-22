#!/usr/bin/env Rscript
# =============================================================================
# Three more views of the DAC / Open Payments / NPPES address comparison
# =============================================================================
# Re-plots the existing comparison artifact
# (artifacts/dac_openpayments_vs_nppes_address_agreement.csv, written by
# compare_dac_openpayments_to_nppes_address.R) from three different angles.
# No new numbers of its own.
#
# The tracked artifact now holds exactly one comparison_type
# (vs_nppes_same_year) -- a three-way NPPES/DAC/Open-Payments concordance
# figure, a pairwise DAC-vs-Open-Payments comparison, and an
# Open-Payments-vs-itself (year-over-year) comparison all used to live here
# too. The first two were removed 2026-10-22 because DAC has a single public
# vintage (2026) and can't be year-matched to Open Payments' 2022-2024; the
# third was removed 2026-10-22 at the repo owner's request. "Every analysis
# needs to be year matched" is a hard rule in this project. See git history
# for the removed figures/computations and
# docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md.
#
# Input : artifacts/dac_openpayments_vs_nppes_address_agreement.csv (tracked)
# Outputs: docs/figures/address_agreement_heatmap.png
#          docs/figures/address_agreement_cascade.png
#          docs/figures/address_agreement_power.png
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
  library(ggplot2); library(scales); library(cli)
})

dir.create("docs/figures", showWarnings = FALSE, recursive = TRUE)

IN <- "artifacts/dac_openpayments_vs_nppes_address_agreement.csv"
stopifnot(file.exists(IN))
d <- read_csv(IN, show_col_types = FALSE)
stopifnot(all(d$comparison_type == "vs_nppes_same_year"))

d$level <- factor(d$level, levels = c("state", "city", "zip5", "street"),
                   labels = c("State", "City", "ZIP5", "Street"))

# Shorten labels: drop the repeated "vs NPPES" text.
d$series <- str_remove(d$source_pair, " vs NPPES$")
d$series <- str_replace(d$series, "^Open Payments ", "")
d$series <- factor(d$series, levels = c("DAC", "(2022)", "(2023)", "(2024)"))
pal <- c("DAC" = "#c0392b", "(2022)" = "#aed6f1", "(2023)" = "#5dade2", "(2024)" = "#1b4f72")

cli_alert_info("A. Heatmap: every source x every geographic level")
heat <- ggplot(d, aes(x = level, y = source_pair, fill = agree_pct)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = sprintf("%.0f%%", agree_pct)), size = 3) +
  scale_fill_distiller(palette = "RdYlBu", direction = 1, limits = c(0, 100), name = "Agreement %") +
  labs(title = "Every source, every geographic level, one view",
       subtitle = "DAC / Open Payments vs. NPPES address agreement (%), year-matched",
       x = NULL, y = NULL,
       caption = "See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md for n per cell.") +
  theme_minimal(base_size = 11) +
  theme(panel.grid = element_blank())
ggsave("docs/figures/address_agreement_heatmap.png", heat, width = 8, height = 4, dpi = 200)

cli_alert_info("B. Cascade: agreement by geographic grain, every source")
cascade <- ggplot(d, aes(x = level, y = agree_pct, group = series, color = series)) +
  geom_line(alpha = 0.9, linewidth = 0.9) +
  geom_point(size = 2) +
  scale_color_manual(values = pal, name = NULL) +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0.02, 0.05))) +
  labs(title = "Agreement falls apart at finer geography -- for every source",
       subtitle = "Each line is one source vs. NPPES, State through Street, year-matched",
       x = NULL, y = "Agreement (%)") +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")
ggsave("docs/figures/address_agreement_cascade.png", cascade, width = 8, height = 6, dpi = 200)

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
