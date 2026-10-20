#!/usr/bin/env Rscript
# =============================================================================
# make_amcb_npi_matching_slide.R
# 3-panel PowerPoint-ready slide: AMCB name -> NPI matching pipeline
# =============================================================================
# Adapted from ~/isochrones/scripts/npi_name_matching_slide.R (same 3-panel
# layout, same box/arrow/patchwork drawing code) for this project's own
# method and numbers. Two things are deliberately NOT carried over:
#
#   * Panel B's original content was a "Multi-Source Name Matching Cascade"
#     across 9 federal/state databases with an explicit gender-mismatch
#     penalty. That's the isochrones/ABOHNS physician pipeline's method, not
#     this one's: this project links one source (AMCB) to one registry
#     (NPPES) by name-evidence class and credential/taxonomy compatibility,
#     and -- per credential_compatibility.R -- deliberately does NOT use
#     gender. Reusing the original panel's content here would describe a
#     method this pipeline doesn't use.
#   * Panel C's original numbers (match-strategy percentages, a confidence
#     score distribution) were specific to that pipeline's output and are not
#     reused. This panel instead reads the real, current breakdown from
#     artifacts/accepted_by_evidence_class.csv (built by
#     make_evidence_class_figure.R from the frozen crosswalk) -- computed,
#     not typed in.
#
# Output: docs/figures/amcb_npi_matching_slide.png  (14 x 8 in, 300 DPI)
# Usage:  Rscript make_amcb_npi_matching_slide.R
#   (run make_evidence_class_figure.R first if
#    artifacts/accepted_by_evidence_class.csv is missing or stale)
# =============================================================================

suppressPackageStartupMessages({
  library(ggplot2)
  library(patchwork)
  library(dplyr)
  library(readr)
  library(scales)
})

CSV <- "artifacts/accepted_by_evidence_class.csv"
if (!file.exists(CSV))
  stop("Missing ", CSV, " -- run make_evidence_class_figure.R first.", call. = FALSE)
ev <- read_csv(CSV, show_col_types = FALSE)

base_theme <- theme_minimal(base_size = 12) +
  theme(
    panel.grid        = element_blank(),
    axis.text         = element_blank(),
    axis.ticks        = element_blank(),
    axis.title        = element_blank(),
    plot.background   = element_rect(fill = "white", color = NA),
    panel.background  = element_rect(fill = "white", color = NA),
    plot.title        = element_text(face = "bold", size = 14, hjust = 0.5,
                                     margin = margin(b = 6)),
    plot.subtitle     = element_text(size = 11, hjust = 0.5, color = "gray40",
                                     margin = margin(b = 4)),
    plot.margin       = margin(8, 8, 8, 8)
  )

# =============================================================================
# PANEL A -- "The Challenge: Name Chaos" (fictional illustrative example)
# =============================================================================
make_panel_a <- function() {
  boxes <- tibble::tribble(
    ~label,            ~content1,                 ~content2,          ~yc,  ~fill_col,  ~border_col,
    "AMCB directory",  "RILEY A. CARPENTER, CNM",  "current legal name", 8.5, "#FDECEA", "#C62828",
    "NPPES (2011)",    "RILEY A. BOWEN",           "maiden name on file", 5.5, "#FFF3E0", "#E65100",
    "NPPES (2019)",    "RILEY CARPENTER",          "NPI: 1XXXXXXXXX",    2.5, "#E3F2FD", "#1565C0"
  )
  box_h <- 1.6; box_xmin <- 0.08; box_xmax <- 0.92

  arrows_df <- tibble::tibble(
    x = 0.5, xend = 0.5,
    y    = c(boxes$yc[1] - box_h - 0.05, boxes$yc[2] - box_h - 0.05),
    yend = c(boxes$yc[2] + box_h + 0.05, boxes$yc[3] + box_h + 0.05))
  arrow_lbl <- tibble::tibble(
    x = 0.5,
    y = c((boxes$yc[1] - box_h + boxes$yc[2] + box_h) / 2,
          (boxes$yc[2] - box_h + boxes$yc[3] + box_h) / 2),
    label = c("Same\nperson?", "Same\nperson?"))

  ggplot() +
    geom_rect(data = boxes,
             aes(xmin = box_xmin, xmax = box_xmax, ymin = yc - box_h, ymax = yc + box_h,
                 fill = fill_col, color = border_col), linewidth = 1.1) +
    scale_fill_identity() + scale_color_identity() +
    geom_text(data = boxes, aes(x = box_xmin + 0.05, y = yc + box_h - 0.35, label = label),
             hjust = 0, vjust = 1, size = 3.2, fontface = "bold", color = "gray25") +
    geom_text(data = boxes, aes(x = 0.5, y = yc + 0.15, label = content1),
             hjust = 0.5, size = 3.8, fontface = "bold", color = "gray10") +
    geom_text(data = boxes, aes(x = 0.5, y = yc - 0.45, label = content2),
             hjust = 0.5, size = 3.0, color = "#1565C0", fontface = "italic") +
    geom_segment(data = arrows_df, aes(x = x, xend = xend, y = y, yend = yend),
                arrow = arrow(length = unit(0.18, "cm"), type = "closed"),
                color = "gray55", linewidth = 0.7) +
    geom_label(data = arrow_lbl, aes(x = x, y = y, label = label),
              size = 2.9, color = "gray45", fill = "white", linewidth = 0,
              label.padding = unit(0.15, "lines")) +
    annotate("rect", xmin = 0.05, xmax = 0.95, ymin = 0.35, ymax = 1.25,
            fill = "#FFEBEE", color = "#C62828", linewidth = 0.8, linetype = "dashed") +
    annotate("text", x = 0.5, y = 0.80,
            label = "Same midwife --\nmaiden name, then a nickname",
            hjust = 0.5, size = 2.9, color = "#C62828", fontface = "bold",
            lineheight = 1.05) +
    coord_cartesian(xlim = c(0, 1), ylim = c(0.1, 10.4), clip = "off") +
    base_theme +
    labs(title = "The Challenge: Name Chaos",
        subtitle = "Illustrative -- not a real certificant")
}

# =============================================================================
# PANEL B -- "AMCB -> NPI Name-Evidence Cascade"
# =============================================================================
make_panel_b <- function() {
  classes <- tibble::tribble(
    ~label,     ~detail,                                           ~conf, ~yc,  ~fill,
    "Class 1",  "Exact surname + given name,\nmiddle name agrees", 1.00,  8.60, "#1B5E20",
    "Class 2",  "Exact surname + given name,\nno usable middle name", 0.90, 7.05, "#558B2F",
    "Class 3",  "Exact surname,\nfirst initial only",              0.70,  5.50, "#F9A825",
    "Class 4",  "Surname within 2 edits,\nexact given name",       0.50,  3.95, "#E65100",
    "Class 5",  "Shared surname component,\nexact given name",     0.35,  2.40, "#6A1B9A"
  )
  bar_h <- 0.55; bar_xmin <- 0.06; bar_xmax <- 0.70

  p <- ggplot() +
    annotate("rect", xmin = 0.10, xmax = 0.90, ymin = 9.75, ymax = 10.30,
            fill = "#0D47A1", color = NA) +
    annotate("text", x = 0.5, y = 10.02, label = "Surname block -> parse & normalize",
            color = "white", fontface = "bold", size = 3.4) +
    geom_rect(data = classes,
             aes(xmin = bar_xmin, xmax = bar_xmin + conf * (bar_xmax - bar_xmin),
                 ymin = yc - bar_h / 2, ymax = yc + bar_h / 2, fill = fill),
             color = "white", linewidth = 0.4) +
    scale_fill_identity() +
    geom_text(data = classes, aes(x = bar_xmin + 0.02, y = yc + 0.17, label = label),
             hjust = 0, size = 3.2, color = "white", fontface = "bold") +
    geom_text(data = classes, aes(x = bar_xmin + 0.02, y = yc - 0.17,
                                 label = sprintf("confidence = %.2f", conf)),
             hjust = 0, size = 2.6, color = "white") +
    geom_text(data = classes, aes(x = bar_xmax + 0.03, y = yc, label = detail),
             hjust = 0, size = 2.9, color = "gray25", lineheight = 1.05) +
    annotate("text", x = 0.5, y = 1.55,
            label = "Resolves only when ONE candidate occupies the strongest class reached;\nelse quarantined. A credential/taxonomy gate (CNM/CM vs MD/DO) narrows every class.",
            size = 2.9, color = "gray35", lineheight = 1.15) +
    annotate("rect", xmin = 0.04, xmax = 0.96, ymin = 0.05, ymax = 0.85,
            fill = "#FFF8E1", color = "#F57F17", linewidth = 0.7) +
    annotate("text", x = 0.5, y = 0.45,
            label = "NOT used: gender (~99% women; would be inferred from first name) | age (built, awaiting birth-year input)",
            hjust = 0.5, size = 2.75, color = "#E65100", fontface = "bold") +
    coord_cartesian(xlim = c(0, 1), ylim = c(0.0, 10.5), clip = "off") +
    base_theme +
    labs(title = "AMCB -> NPI Name-Evidence Cascade",
        subtitle = "One registry, ranked by evidence class, never blended into a score")
  p
}

# =============================================================================
# PANEL C -- "Results" (real numbers, read from the frozen crosswalk)
# =============================================================================
make_panel_c <- function(ev) {
  conf_lookup <- c(`1` = 1.00, `2` = 0.90, `3` = 0.70, `4` = 0.50, `5` = 0.35)
  d <- ev %>%
    mutate(name_evidence_class = factor(name_evidence_class, levels = 1:5)) %>%
    group_by(name_evidence_class) %>%
    mutate(class_n = sum(n)) %>%
    ungroup() %>%
    mutate(pct = 100 * n / sum(n),
          class_pct = 100 * class_n / sum(n))

  total_n <- sum(ev$n)
  lbl <- d %>% distinct(name_evidence_class, class_pct) %>%
    mutate(lbl = sprintf("%.1f%%\n(conf %.2f)", class_pct, conf_lookup[as.character(name_evidence_class)]))

  p_bar <- ggplot(d, aes(x = name_evidence_class, y = pct, fill = taxonomy)) +
    geom_col(width = 0.68, color = "white", linewidth = 0.5) +
    geom_text(data = lbl, aes(x = name_evidence_class, y = class_pct + 2, label = lbl),
             inherit.aes = FALSE, size = 2.9, color = "gray20", lineheight = 0.95) +
    scale_fill_manual(values = c("Midwifery taxonomy" = "#1A237E", "Nursing taxonomy" = "#90A4AE"),
                      name = NULL) +
    scale_y_continuous(limits = c(0, max(lbl$class_pct) * 1.22), expand = c(0, 0)) +
    scale_x_discrete(labels = paste0("Class ", 1:5)) +
    theme_minimal(base_size = 11) +
    theme(panel.grid.major.x = element_blank(), panel.grid.minor = element_blank(),
         axis.text.x = element_text(size = 9), axis.text.y = element_text(size = 9),
         axis.title.y = element_text(size = 10),
         legend.position = "bottom", legend.text = element_text(size = 8),
         plot.background = element_rect(fill = "white", color = NA),
         panel.background = element_rect(fill = "white", color = NA),
         plot.title = element_text(face = "bold", size = 12, hjust = 0.5, margin = margin(b = 4)),
         plot.margin = margin(4, 8, 4, 4)) +
    labs(title = "Accepted Links by Evidence Class", x = NULL, y = "% of accepted links")

  p_bar + plot_annotation(
    caption = sprintf("n = %s accepted AMCB-to-NPI links, from artifacts/accepted_by_evidence_class.csv",
                      formatC(total_n, format = "d", big.mark = ",")),
    theme = theme(plot.caption = element_text(size = 8, color = "gray50", hjust = 0.5)))
}

# =============================================================================
# Assemble
# =============================================================================
pA <- make_panel_a()
pB <- make_panel_b()
pC <- make_panel_c(ev)

final_plot <- (pA | pB | pC) +
  plot_layout(widths = c(2.5, 4.5, 3.0)) +
  plot_annotation(
    title    = "Matching AMCB Names to NPI Numbers",
    subtitle = "One registry, ranked by name-evidence class -- gender and age deliberately not used",
    caption  = paste0(
      "NPI = National Provider Identifier.  ",
      "NPPES = National Plan and Provider Enumeration System.  ",
      "A record resolves only when exactly one candidate occupies its strongest class."),
    theme = theme(
      plot.title    = element_text(face = "bold", size = 20, hjust = 0.5, margin = margin(b = 4)),
      plot.subtitle = element_text(size = 12.5, hjust = 0.5, color = "gray40", margin = margin(b = 6)),
      plot.caption  = element_text(size = 9, hjust = 0.5, color = "gray50", margin = margin(t = 6)),
      plot.background = element_rect(fill = "white", color = NA)))

out_path <- "docs/figures/amcb_npi_matching_slide.png"
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
tmp <- paste0(out_path, ".tmp.png")
ggsave(tmp, final_plot, width = 14, height = 8, dpi = 300, bg = "white")
invisible(file.rename(tmp, out_path))
cat(sprintf("[DONE] Saved: %s (%.1f MB)\n", out_path, file.info(out_path)$size / 1e6))
