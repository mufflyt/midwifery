#!/usr/bin/env Rscript
#' @title Figure: a weighted method uses noisy evidence majority vote can't
#'
#' @description
#' The literal final exchange in the collaborative truth-fusion investigation
#' (docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S6, last paragraph): adding T-MSIS to the
#' parallel session's 1,806-case cohort makes plain majority vote WORSE (more ties, not fewer --
#' see make_collaborative_convergence_figure.R's right panel), but the same new evidence makes
#' dawid_skene behave more like real 3-source synthesis, not less. Two numbers, both re-run on
#' the SAME 759 majority ties by that session: how often dawid_skene and truthfinder agree on the
#' resolved value, and how often dawid_skene's resolution is just NPPES's own claim restated.
#'
#' Source: mysteryroster/docs/midwifery-evidence-ledger-results.md SS3 (commit ec90662) --
#' verified by direct read before use, 2026-11-06, including that document's own footnote that
#' the original 97.6% figure was of the 678/695 single-remaining-source subset specifically, not
#' all 695 (the right-hand bar below, 79.2%, is of the full 759). That asymmetry in denominators
#' is real and is kept visible in the subtitle rather than smoothed over.
#'
#' Aggregate input (hand-transcribed and cited from an external, already-aggregate markdown
#' table), aggregate output.
#'
#' Output: docs/figures/weighted_vs_majority_tmsis.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(patchwork)})

OUT <- file.path("docs", "figures", "weighted_vs_majority_tmsis")

d <- tibble::tribble(
  ~metric, ~x, ~value, ~note,
  "dawid_skene & truthfinder\nagree on resolved value", "695 ties\n(3 sources)", 6.6, "46/695",
  "dawid_skene & truthfinder\nagree on resolved value", "759 ties\n(+ T-MSIS)", 19.1, "145/759",
  "dawid_skene's resolution\nis just NPPES restated", "695 ties\n(3 sources)", 97.6, "678/695*",
  "dawid_skene's resolution\nis just NPPES restated", "759 ties\n(+ T-MSIS)", 79.2, "601/759"
) %>% mutate(x = factor(x, levels = c("695 ties\n(3 sources)", "759 ties\n(+ T-MSIS)")))

make_panel <- function(metric_name, fill_color, show_note) {
  pd <- d %>% filter(metric == metric_name)
  ggplot(pd, aes(x = x, y = value)) +
    geom_col(fill = fill_color, width = 0.55) +
    geom_text(aes(label = sprintf("%.1f%%", value)), vjust = -0.6, size = 3.4, fontface = "bold") +
    { if (show_note) geom_text(aes(label = note), vjust = 1.8, size = 2.6, color = "grey30") } +
    scale_y_continuous(limits = c(0, 110), expand = expansion(mult = c(0, 0))) +
    labs(title = metric_name, x = NULL, y = "%") +
    theme_minimal(base_size = 10.5) +
    theme(plot.title = element_text(face = "bold", size = 10.5, lineheight = 1.1),
          axis.text.x = element_text(lineheight = 0.9))
}

p1 <- make_panel("dawid_skene & truthfinder\nagree on resolved value", "#2E6E8E", TRUE)
p2 <- make_panel("dawid_skene's resolution\nis just NPPES restated", "#B4473E", TRUE)

combined <- (p1 | p2) +
  plot_annotation(
    title = "Adding a noisy 4th source makes majority vote WORSE but dawid_skene MORE like real synthesis",
    subtitle = "Same 1,806-case cohort, same T-MSIS addition. *97.6% is of the 678/695 single-remaining-source subset specifically, not all 695 — the 79.2% bar is of all 759.",
    caption = "Source: mysteryroster/docs/midwifery-evidence-ledger-results.md §3 (commit ec90662)",
    theme = theme(plot.title = element_text(face = "bold", size = 12.5),
                  plot.subtitle = element_text(size = 9, color = "grey30"),
                  plot.caption = element_text(size = 8, color = "grey50"))
  )

ggsave(paste0(OUT, ".pdf"), combined, width = 9.5, height = 5.8, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), combined, width = 9.5, height = 5.8, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), combined, width = 9.5, height = 5.8),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
