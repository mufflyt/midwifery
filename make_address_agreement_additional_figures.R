#!/usr/bin/env Rscript
# =============================================================================
# Two more views of the DAC / Open Payments / NPPES address comparison
# =============================================================================
# Re-plots the existing comparison artifact
# (artifacts/dac_openpayments_vs_nppes_address_agreement.csv, written by
# compare_dac_openpayments_to_nppes_address.R) from two different angles.
# No new numbers of its own. The heatmap this script used to write moved to
# make_address_agreement_heatmap.R -- see the note at that block for why.
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
# Outputs: docs/figures/address_agreement_cascade.png
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

# Legend label = the non-NPPES side's name and year, e.g. "DAC (2026)" or
# "Open Payments (2022)" -- the NPPES side's year is dropped here only
# because it's identical (source_pair itself, e.g. "DAC (2026) vs NPPES
# (2026)", always spells out both, and is used as-is for the heatmap's
# row labels below).
d$series <- str_remove(d$source_pair, " vs NPPES \\([0-9]{4}\\)$")
d$series <- factor(d$series, levels = c("DAC (2026)", "Open Payments (2022)",
                                         "Open Payments (2023)", "Open Payments (2024)"))
pal <- c("DAC (2026)" = "#c0392b", "Open Payments (2022)" = "#aed6f1",
         "Open Payments (2023)" = "#5dade2", "Open Payments (2024)" = "#1b4f72")

# THE HEATMAP USED TO BE HERE, AND IT WAS OVERWRITING A BETTER ONE.
# make_address_agreement_heatmap.R (added 2026-10-23) writes the SAME path,
# docs/figures/address_agreement_heatmap.png, from all five comparison
# artifacts at 14x5.5in; the version here drew only this file's two sources at
# 8x4in. Both were tracked under one filename, so the committed figure was
# decided by whichever script ran last. The committed figure is 2800x1100 px,
# i.e. the five-source one -- meaning running THIS script, exactly as
# docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md s6 tells a
# reader to, silently replaced it with the narrower view. One filename, one
# writer: the heatmap belongs to make_address_agreement_heatmap.R, and this
# script keeps the two figures that are genuinely its own.
cli_alert_info("A. Cascade: agreement by geographic grain, every source")
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

cli_alert_info("B. Power check: agreement vs. how many records it's based on")
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
