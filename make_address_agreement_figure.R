#!/usr/bin/env Rscript
# =============================================================================
# Figure: how DAC and Open Payments agree with NPPES on address
# =============================================================================
# Reads the tracked aggregate compare_dac_openpayments_to_nppes_address.R
# writes; draws no new numbers itself. One comparison, DAC or Open Payments
# against NPPES's own panel for the same year the other source is dated to.
#
# Two comparisons used to live alongside this one and were both removed as
# non-year-matched or redundant: DAC directly against Open Payments (DAC has
# one public vintage, 2026, so that pairing was never year-matched; removed
# 2026-10-22) and Open Payments against itself across years (removed
# 2026-10-22 at the repo owner's request). "Every analysis needs to be year
# matched" is a hard rule in this project. See git history for the prior
# numbers and docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md.
#
# Input : artifacts/dac_openpayments_vs_nppes_address_agreement.csv (tracked)
# Output: docs/figures/dac_openpayments_vs_nppes_agreement.png
# =============================================================================
suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(stringr)})

IN  <- "artifacts/dac_openpayments_vs_nppes_address_agreement.csv"
OUT <- "docs/figures/dac_openpayments_vs_nppes_agreement.png"
stopifnot(file.exists(IN))
dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)

d <- read_csv(IN, show_col_types = FALSE)
stopifnot(all(d$comparison_type == "vs_nppes_same_year"))

d$level <- factor(d$level, levels = c("state", "city", "zip5", "street"),
                  labels = c("State", "City", "ZIP5", "Street"))

# Shorten legend labels: drop the repeated "vs NPPES" text.
d$series <- str_remove(d$source_pair, " vs NPPES$")
d$series <- str_replace(d$series, "^Open Payments ", "")
d$series <- factor(d$series, levels = c("DAC", "(2022)", "(2023)", "(2024)"))

pal <- c("DAC" = "#c0392b", "(2022)" = "#aed6f1", "(2023)" = "#5dade2", "(2024)" = "#1b4f72")

p <- ggplot(d, aes(x = level, y = agree_pct, fill = series)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7, na.rm = TRUE) +
  geom_text(aes(label = ifelse(is.na(agree_pct), "", sprintf("%.0f%%", agree_pct))),
            position = position_dodge(width = 0.75), vjust = -0.4, size = 2.9, na.rm = TRUE) +
  scale_fill_manual(values = pal) +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0, 0.1))) +
  labs(
    title = "How well do DAC and Open Payments agree with NPPES on address?",
    subtitle = "Year-matched: DAC vs NPPES compares the same 2026 vintage; each Open Payments year compares against\nNPPES's snapshot for that same year. Open Payments' address is partly NPPES-sourced, so its high\nagreement here is not fully independent confirmation.",
    x = NULL, y = "Agreement (%)", fill = NULL,
    caption = paste(
      "n: DAC vs NPPES 5,576. Open Payments vs NPPES 3,210-4,020/year.",
      "See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md.",
      sep = "\n")
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold", size = 13),
    plot.subtitle = element_text(size = 9, color = "grey30"),
    plot.caption = element_text(size = 7, color = "grey40", hjust = 0),
    legend.position = "bottom",
    panel.grid.minor = element_blank()
  )

ggsave(OUT, p, width = 8, height = 6.5, dpi = 200)
cat("wrote", OUT, "\n")
