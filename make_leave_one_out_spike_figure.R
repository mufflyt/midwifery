#!/usr/bin/env Rscript
#' @title Figure: only removing NPPES moves the 2017-18 spike
#'
#' @description
#' docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S4's headline result, visualized directly
#' from the tracked leave-one-out sensitivity table: dropping DAC+PECOS, Open Payments, T-MSIS,
#' or facility affiliation individually barely moves either spike transition's dawid_skene move
#' rate. Dropping NPPES is the one variant that changes the picture, and it changes the two
#' spikes in opposite directions -- 2017-18 falls, 2023-24 rises.
#'
#' Aggregate input, aggregate output: both the backing CSV and this figure carry
#' transition-level counts only, so both are publishable.
#'
#' Output: docs/figures/leave_one_out_spike_sensitivity.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr)})

CSV <- file.path("artifacts", "truth_fusion_leave_one_out_sensitivity.csv")
OUT <- file.path("docs", "figures", "leave_one_out_spike_sensitivity")

if (!file.exists(CSV))
  stop("Missing ", CSV, " -- run build_leave_one_source_out_sensitivity.R first.", call. = FALSE)

VARIANT_LABELS <- c(
  full = "All 5 sources",
  drop_dac_pecos_combined = "– DAC+PECOS",
  drop_open_payments = "– Open Payments",
  drop_tmsis_medicaid = "– T-MSIS",
  drop_facility_affiliation = "– Facility affiliation",
  drop_nppes = "– NPPES"
)

d <- read_csv(CSV, show_col_types = FALSE) %>%
  filter(method == "dawid_skene", is_spike_transition) %>%
  mutate(
    transition = sprintf("%d→%d", year_from, year_to),
    variant_label = factor(VARIANT_LABELS[variant],
                            levels = VARIANT_LABELS[c("full", "drop_dac_pecos_combined", "drop_open_payments",
                                                       "drop_tmsis_medicaid", "drop_facility_affiliation", "drop_nppes")]),
    is_nppes_drop = variant == "drop_nppes"
  )

p <- ggplot(d, aes(x = variant_label, y = pct_moved, fill = transition, alpha = is_nppes_drop)) +
  geom_col(position = position_dodge(width = 0.65), width = 0.55) +
  geom_text(aes(label = sprintf("%.1f%%", pct_moved)), position = position_dodge(width = 0.65),
            vjust = -0.5, size = 3, show.legend = FALSE) +
  scale_fill_manual(values = c("2017→2018" = "#B4473E", "2023→2024" = "#2E6E8E"), name = "Transition") +
  scale_alpha_manual(values = c(`FALSE` = 0.55, `TRUE` = 1), guide = "none") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(
    title = "Only removing NPPES moves the 2017–18 spike — and it moves the two spikes in opposite directions",
    subtitle = "dawid_skene move rate for each spike transition, with one source family dropped at a time (full panel, 2013–2026)",
    x = NULL, y = "% of NPI-years with a state change"
  ) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold", size = 11.5), legend.position = "top",
        axis.text.x = element_text(angle = 20, hjust = 1))

ggsave(paste0(OUT, ".pdf"), p, width = 9.5, height = 5.8, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), p, width = 9.5, height = 5.8, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), p, width = 9.5, height = 5.8),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
