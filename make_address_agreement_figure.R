#!/usr/bin/env Rscript
# =============================================================================
# Figure: how DAC, Open Payments and NPPES agree and disagree on address
# =============================================================================
# Reads the tracked aggregate compare_dac_openpayments_to_nppes_address.R
# writes; draws no new numbers itself. Three panels, one per comparison_type:
# each source vs NPPES (same year), Open Payments against itself year over
# year, and DAC directly against Open Payments.
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

d$level <- factor(d$level, levels = c("state", "city", "zip5", "street"),
                  labels = c("State", "City", "ZIP5", "Street"))
d$panel <- factor(d$comparison_type,
  levels = c("vs_nppes_same_year", "open_payments_yoy", "dac_vs_open_payments"),
  labels = c("Each source vs. NPPES\n(same year)",
            "Open Payments vs. itself\n(different years, same person)",
            "DAC (2026) vs. Open Payments\n(different years)"))

# Shorten legend labels: drop the repeated "vs NPPES"/"DAC (2026) vs " text,
# panel titles already say what's being compared.
d$series <- d$source_pair
d$series <- str_remove(d$series, " vs NPPES$")
d$series <- str_remove(d$series, "^DAC \\(2026\\) vs ")
d$series <- str_replace(d$series, "^Open Payments ", "")

pal <- c("DAC" = "#c0392b",
        "(2022)" = "#aed6f1", "(2023)" = "#5dade2", "(2024)" = "#1b4f72",
        "2022 vs 2023" = "#aed6f1", "2022 vs 2024" = "#5dade2", "2023 vs 2024" = "#1b4f72")

p <- ggplot(d, aes(x = level, y = agree_pct, fill = series)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7, na.rm = TRUE) +
  geom_text(aes(label = ifelse(is.na(agree_pct), "", sprintf("%.0f%%", agree_pct))),
            position = position_dodge(width = 0.75), vjust = -0.4, size = 2.7, na.rm = TRUE) +
  facet_wrap(~panel, nrow = 1) +
  scale_fill_manual(values = pal) +
  scale_y_continuous(limits = c(0, 100), expand = expansion(mult = c(0, 0.1))) +
  labs(
    title = "Three ways to check a midwife's address, and how often they agree",
    subtitle = "DAC (PECOS-derived) has one vintage (2026). Open Payments is year-matched where it says \"same year\";\nits recipient address is partly NPPES-sourced, so its high agreement there is not fully independent.",
    x = NULL, y = "Agreement (%)", fill = NULL,
    caption = paste(
      "n: DAC vs NPPES 5,576. Open Payments vs NPPES 3,210-4,020/year. Open Payments year-over-year 2,175-2,500.",
      "DAC vs Open Payments 1,577-2,019 (smaller: requires a midwife present in both DAC and that OP year).",
      "No street field in the public Open Payments file before this session's fix; now captured for 2022-2024.",
      "See docs/TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md.",
      sep = "\n")
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold", size = 13),
    plot.subtitle = element_text(size = 9, color = "grey30"),
    plot.caption = element_text(size = 7, color = "grey40", hjust = 0),
    legend.position = "bottom",
    strip.text = element_text(face = "bold", size = 9.5),
    panel.grid.minor = element_blank(),
    panel.spacing = unit(1, "lines")
  )

ggsave(OUT, p, width = 12.5, height = 6.8, dpi = 200)
cat("wrote", OUT, "\n")
