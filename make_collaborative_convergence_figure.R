#!/usr/bin/env Rscript
#' @title Figure: two independent tests, opposite experimental moves, same conclusion
#'
#' @description
#' docs/TECHNICAL_APPENDIX_TRUTH_FUSION_MIGRATION.md S6's headline convergent finding,
#' visualized directly: this repo's own test REMOVES NPPES from the full 2013-2026 panel
#' (219,536 entity-years) and watches each spike transition's dawid_skene move rate change.
#' A parallel mysteryroster-side session's test ADDS T-MSIS to a smaller, independently
#' frozen 1,806-case/3,556-NPI-year cohort and watches majority-vote abstention change. Two
#' structurally different experiments, on two different (though overlapping) analysis units,
#' computed by two separate sessions -- both find the same asymmetry: 2017-18 is sensitive to
#' whichever independent-of-NPPES test is applied (its NPPES-dependence shows up either way);
#' 2023-24 is comparatively robust to both.
#'
#' Panel 2's four numbers (baseline/+T-MSIS abstention %, 2018 and 2024 only) are READ directly
#' from mysteryroster/docs/midwifery-evidence-ledger-results.md SS3 (commit ec90662) and
#' verified against that file's own abstention-by-year table before use here -- not re-derived
#' from midwifery's own data, since the 1,806-case cohort and its T-MSIS claims extraction are
#' owned by that session, not this one. If that source document is revised, this panel's two
#' numbers must be re-checked against it, not assumed stable.
#'
#' Aggregate input (panel 1 from the tracked leave-one-out CSV; panel 2 hand-transcribed and
#' cited from an external, already-aggregate markdown table), aggregate output.
#'
#' Output: docs/figures/collaborative_convergence.{pdf,png,svg}
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({library(ggplot2); library(dplyr); library(readr); library(patchwork); library(ggrepel)})

LOO_CSV <- file.path("artifacts", "truth_fusion_leave_one_out_sensitivity.csv")
OUT <- file.path("docs", "figures", "collaborative_convergence")
if (!file.exists(LOO_CSV))
  stop("Missing ", LOO_CSV, " -- run build_leave_one_source_out_sensitivity.R first.", call. = FALSE)

TRANSITION_COLORS <- c("2017→2018" = "#B4473E", "2023→2024" = "#2E6E8E")

# --- panel 1: this repo's own test (full panel, 219,536 entity-years) ------
p1_data <- read_csv(LOO_CSV, show_col_types = FALSE) %>%
  filter(method == "dawid_skene", is_spike_transition, variant %in% c("full", "drop_nppes")) %>%
  mutate(
    transition = sprintf("%d→%d", year_from, year_to),
    x = factor(ifelse(variant == "full", "NPPES included", "NPPES removed"),
               levels = c("NPPES included", "NPPES removed"))
  )

p1 <- ggplot(p1_data, aes(x = x, y = pct_moved, color = transition, group = transition)) +
  geom_line(linewidth = 1, alpha = 0.8) +
  geom_point(size = 3.2) +
  geom_text_repel(aes(label = sprintf("%.1f%%", pct_moved)), size = 3.1, show.legend = FALSE,
                   direction = "y", seed = 1, min.segment.length = Inf) +
  scale_color_manual(values = TRANSITION_COLORS, name = NULL) +
  scale_y_continuous(limits = c(0, 6.5), expand = expansion(mult = c(0.02, 0.1))) +
  labs(title = "This repo's test: remove NPPES\nfrom the full 219,536-entity-year panel",
       x = NULL, y = "% of NPI-years with a state change\n(dawid_skene move rate)") +
  theme_minimal(base_size = 10.5) +
  theme(plot.title = element_text(face = "bold", size = 10), legend.position = "top")

# --- panel 2: parallel session's test (1,806-case/3,556-NPI-year cohort) ---
# Source: mysteryroster/docs/midwifery-evidence-ledger-results.md S3, commit ec90662 --
# verified by direct read before use, 2026-11-06.
p2_data <- tibble(
  transition = rep(c("2017→2018", "2023→2024"), each = 2),
  x = rep(c("3 sources (baseline)", "+ T-MSIS (4th source)"), times = 2),
  abstain_pct = c(8.0, 19.3, 23.7, 18.9)
) %>% mutate(x = factor(x, levels = c("3 sources (baseline)", "+ T-MSIS (4th source)")))

p2 <- ggplot(p2_data, aes(x = x, y = abstain_pct, color = transition, group = transition)) +
  geom_line(linewidth = 1, alpha = 0.8) +
  geom_point(size = 3.2) +
  geom_text_repel(aes(label = sprintf("%.1f%%", abstain_pct)), size = 3.1, show.legend = FALSE,
                   direction = "y", seed = 1, min.segment.length = Inf) +
  scale_color_manual(values = TRANSITION_COLORS, name = NULL, guide = "none") +
  scale_y_continuous(limits = c(0, 26), expand = expansion(mult = c(0.02, 0.1))) +
  labs(title = "Parallel session's test: add T-MSIS to a\nseparate 1,806-case, 3,556-NPI-year cohort",
       x = NULL, y = "majority-vote abstention %") +
  theme_minimal(base_size = 10.5) +
  theme(plot.title = element_text(face = "bold", size = 10), legend.position = "none")

combined <- (p1 | p2) +
  plot_annotation(
    title = "Two independent tests, opposite experimental moves, the same conclusion",
    subtitle = "2017–18 is sensitive to NPPES either way it's tested; 2023–24 is comparatively robust to both",
    theme = theme(plot.title = element_text(face = "bold", size = 13),
                  plot.subtitle = element_text(size = 10.5, color = "grey30"))
  )

ggsave(paste0(OUT, ".pdf"), combined, width = 10, height = 5.6, device = if (capabilities("cairo")) cairo_pdf else pdf)
ggsave(paste0(OUT, ".png"), combined, width = 10, height = 5.6, dpi = 300, bg = "white")
tryCatch(ggsave(paste0(OUT, ".svg"), combined, width = 10, height = 5.6),
         error = function(e) cat("svg device unavailable, skipped:", conditionMessage(e), "\n"))
cat("Wrote", paste0(OUT, ".{pdf,png,svg}"), "\n")
