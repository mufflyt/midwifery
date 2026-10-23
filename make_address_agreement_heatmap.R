#!/usr/bin/env Rscript
# =============================================================================
# One heatmap: every address-agreement comparison this project runs, side by side
# =============================================================================
# Reads the three pairwise agreement tables this project's compare_*_address.R
# scripts each write independently (one artifact per comparison, not one
# shared table) and plots them as a single state/city/ZIP5 heatmap.
#
# STREET IS NOT HERE. Every comparison dropped it (2026-10-23): free-text
# street formatting never agreed cleanly enough across any source pair to be
# worth reporting -- see each compare_*_address.R script's own header for the
# specific numbers that led to removing it. ZIP5 is the finest grain any of
# these comparisons report, and the one this repo treats as the headline
# metric -- its tile is outlined to mark that, not because the other two
# levels don't matter.
#
# Inputs : artifacts/pecos_vs_nppes_address_agreement.csv        (compare_pecos_to_nppes_address.R)
#          artifacts/healthgrades_vs_nppes_address_agreement.csv (compare_healthgrades_to_nppes_address.R)
#          artifacts/healthgrades_vs_pecos_address_agreement.csv (compare_healthgrades_to_pecos_address.R)
#          artifacts/pecos_vs_doximity_address_agreement.csv     (compare_pecos_to_doximity_address.R)
#          artifacts/pecos_vs_bon_address_agreement.csv          (compare_pecos_to_bon_address.R)
# Outputs: docs/figures/address_agreement_heatmap.png
#
# BON: the POOLED row only (vs_bon_same_year_pooled), not the four per-state
# rows compare_pecos_to_bon_address.R also writes -- one tile per source pair
# here, same as every other comparison. CO alone (n=166) dominates the pool
# (n=181), so the pooled number and CO's own number are nearly identical; the
# per-state breakdown (including IL's unusable n=1 and DE's n=0) stays in
# artifacts/pecos_vs_bon_address_agreement.csv for anyone who wants it.
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(purrr); library(ggplot2); library(cli)
})

INPUTS <- c(
  "artifacts/pecos_vs_nppes_address_agreement.csv",
  "artifacts/healthgrades_vs_nppes_address_agreement.csv",
  "artifacts/healthgrades_vs_pecos_address_agreement.csv",
  "artifacts/pecos_vs_doximity_address_agreement.csv",
  "artifacts/pecos_vs_bon_address_agreement.csv"
)
stopifnot(all(file.exists(INPUTS)))

dir.create("docs/figures", showWarnings = FALSE, recursive = TRUE)

d <- map_dfr(INPUTS, read_csv, col_types = cols(.default = "c")) %>%
  filter(level != "street", comparison_type != "vs_bon_same_year") %>%
  mutate(level = factor(level, levels = c("state", "city", "zip5"),
                         labels = c("State", "City", "ZIP5")),
         agree_pct = as.numeric(agree_pct),
         comparable_n = as.numeric(comparable_n))

heat <- ggplot(d, aes(x = level, y = source_pair, fill = agree_pct)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_tile(data = filter(d, level == "ZIP5"), fill = NA, color = "black", linewidth = 1.2) +
  geom_text(aes(label = sprintf("%.0f%%", agree_pct),
                fontface = ifelse(level == "ZIP5", "bold", "plain")),
            size = 3.6) +
  scale_fill_distiller(palette = "RdYlBu", direction = 1, limits = c(0, 100), name = "Agreement %") +
  labs(title = "Address agreement across every source pair this project has checked",
       subtitle = "ZIP5 (outlined, bold) is the metric this project treats as primary. Street dropped -- never reliable.",
       x = NULL, y = NULL,
       caption = "n per cell: see artifacts/*_address_agreement.csv. BON row is CO+IL+CT+DE pooled -- see artifacts/pecos_vs_bon_address_agreement.csv for the per-state breakdown.") +
  theme_minimal(base_size = 11) +
  theme(panel.grid = element_blank(),
        axis.text.y = element_text(size = 8),
        plot.caption = element_text(hjust = 0, size = 7.5))

ggsave("docs/figures/address_agreement_heatmap.png", heat, width = 11.5, height = 5.5, dpi = 200)
cli::cli_alert_success("wrote docs/figures/address_agreement_heatmap.png")
