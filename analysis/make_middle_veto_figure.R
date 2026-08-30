#!/usr/bin/env Rscript
# Figure: the middle-name veto's two-sided footprint, and what the fix moved.
# Counts are from docs/TECHNICAL_APPENDIX_RECORD_LINKAGE.md and the control-vs-
# treatment comparison; they are literals here so the figure cannot silently
# disagree with the prose it illustrates.
suppressPackageStartupMessages(library(ggplot2))
out <- file.path("docs", "figures", "middle_name_veto.png")

foot <- data.frame(
  what = factor(c("Ruled in by a middle name\nthat agrees elsewhere",
                  "Resolved ONLY because every\nrival was vetoed",
                  "Unresolved either way\n(82 lost their only candidate)"),
                levels = c("Unresolved either way\n(82 lost their only candidate)",
                           "Resolved ONLY because every\nrival was vetoed",
                           "Ruled in by a middle name\nthat agrees elsewhere")),
  n = c(1454L, 218L, 568L),
  kind = c("veto is inert", "uniqueness manufactured", "evidence destroyed"))

pal <- c("veto is inert" = "#4C7C64",
         "uniqueness manufactured" = "#B08A2E",
         "evidence destroyed" = "#A8412A")

p <- ggplot(foot, aes(n, what, fill = kind)) +
  geom_col(width = 0.62) +
  geom_text(aes(label = format(n, big.mark = ",")), hjust = -0.15,
            size = 4.1, colour = "#16211C") +
  scale_fill_manual(values = pal, name = NULL) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.16))) +
  labs(
    title = "One rule, two opposite failures",
    subtitle = paste("2,240 roster rows had an exact first-and-last-name candidate deleted",
                     "on a middle-initial conflict.\nNeither tail was counted anywhere",
                     "before 2026-08-30."),
    caption = "AMCB → NPPES linkage · docs/TECHNICAL_APPENDIX_RECORD_LINKAGE.md",
    x = "roster rows", y = NULL) +
  theme_minimal(base_size = 12) +
  theme(panel.grid.major.y = element_blank(),
        panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold", size = 15),
        plot.subtitle = element_text(colour = "#5C6B64", size = 10, lineheight = 1.15),
        plot.caption = element_text(colour = "#8B9791", size = 8),
        axis.text.y = element_text(lineheight = 1.05, colour = "#16211C"),
        legend.position = "top", legend.justification = "left")

dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)
ggsave(out, p, width = 8.6, height = 4.3, dpi = 200, bg = "white")
cat("wrote", out, "\n")
