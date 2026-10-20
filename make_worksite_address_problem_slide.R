#!/usr/bin/env Rscript
# =============================================================================
# make_worksite_address_problem_slide.R -- The Work-Site Address Problem
# =============================================================================
# Adapted from ~/isochrones/scripts/make_address_slide.R (same radial layout,
# same drawing primitives) for this project's own sources: one midwife's NPI
# can carry up to four candidate addresses, which is exactly the problem
# build_trilliant_work_sites.R / R/lib/work_site_topology.R exist to resolve.
#
# Output: docs/figures/worksite_address_problem.png
# Format: 13.33 x 7.5 in (16:9 PPT), 300 DPI, white background
# Usage:  Rscript make_worksite_address_problem_slide.R
# =============================================================================

library(grid)

out <- "docs/figures/worksite_address_problem.png"
dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
png(out, width = 13.33, height = 7.5, units = "in", res = 300, bg = "white")
grid.newpage()

# Title bar
grid.rect(x = 0.5, y = 0.94, width = 1, height = 0.12,
          gp = gpar(fill = "#B71C1C", col = NA))
grid.text("The Work-Site Address Problem",
          x = 0.5, y = 0.96, gp = gpar(col = "white", fontsize = 26, fontface = "bold"))
grid.text("One midwife, up to four candidate addresses -- which one reflects where she actually practices?",
          x = 0.5, y = 0.91, gp = gpar(col = "#FFCDD2", fontsize = 13))

# ---- NPI Key label (top, under title bar) ----
grid.roundrect(x = 0.5, y = 0.84, width = 0.45, height = 0.04,
               r = unit(0.008, "npc"),
               gp = gpar(fill = "#37474F", col = "white", lwd = 1.5))
grid.text("NPI Number: the sole identifier linking one midwife across every source below",
          x = 0.5, y = 0.84, gp = gpar(col = "white", fontsize = 9, fontface = "bold"))

# Central provider
grid.circle(x = 0.5, y = 0.62, r = 0.065,
            gp = gpar(fill = "#37474F", col = "white", lwd = 3))
grid.text("One Midwife", x = 0.5, y = 0.64,
          gp = gpar(col = "white", fontsize = 10, fontface = "bold"))
grid.text("One NPI", x = 0.5, y = 0.60,
          gp = gpar(col = "#B0BEC5", fontsize = 8))

# Arrows - 4 directions
grid.lines(x = c(0.435, 0.22), y = c(0.62, 0.62),
           arrow = arrow(length = unit(0.012, "npc"), type = "closed"),
           gp = gpar(col = "#1565C0", lwd = 3))
grid.lines(x = c(0.565, 0.78), y = c(0.62, 0.62),
           arrow = arrow(length = unit(0.012, "npc"), type = "closed"),
           gp = gpar(col = "#2E7D32", lwd = 3))
grid.lines(x = c(0.47, 0.38), y = c(0.56, 0.44),
           arrow = arrow(length = unit(0.012, "npc"), type = "closed"),
           gp = gpar(col = "#E65100", lwd = 3))
grid.lines(x = c(0.53, 0.63), y = c(0.56, 0.44),
           arrow = arrow(length = unit(0.012, "npc"), type = "closed"),
           gp = gpar(col = "#6A1B9A", lwd = 3))

# ======== LEFT: NPPES PRIMARY ========
grid.rect(x = 0.14, y = 0.64, width = 0.12, height = 0.16,
          gp = gpar(fill = "#90CAF9", col = "#1565C0", lwd = 2))
grid.polygon(x = c(0.07, 0.14, 0.21), y = c(0.72, 0.76, 0.72),
             gp = gpar(fill = "#1565C0", col = "#0D47A1", lwd = 2))
for (wx in c(0.11, 0.17)) {
  for (wy in c(0.60, 0.64, 0.68)) {
    grid.rect(x = wx, y = wy, width = 0.025, height = 0.025,
              gp = gpar(fill = "#E3F2FD", col = "#1565C0", lwd = 0.5))
  }
}
grid.rect(x = 0.14, y = 0.57, width = 0.03, height = 0.04,
          gp = gpar(fill = "#1565C0", col = "#0D47A1", lwd = 1))
grid.rect(x = 0.14, y = 0.715, width = 0.09, height = 0.02,
          gp = gpar(fill = "white", col = "#1565C0", lwd = 1))
grid.text("NPPES", x = 0.14, y = 0.715,
          gp = gpar(fontsize = 6, fontface = "bold", col = "#1565C0"))
grid.text("NPPES Primary", x = 0.14, y = 0.50,
          gp = gpar(fontsize = 13, fontface = "bold", col = "#1565C0"))
grid.text("Self-enumerated by the provider\nOften the billing address, not the exam room",
          x = 0.14, y = 0.46, gp = gpar(fontsize = 9, col = "gray30", lineheight = 1.2))

# ======== RIGHT: CMS DAC FACILITY ========
grid.rect(x = 0.86, y = 0.65, width = 0.14, height = 0.18,
          gp = gpar(fill = "#A5D6A7", col = "#2E7D32", lwd = 2))
grid.rect(x = 0.86, y = 0.77, width = 0.06, height = 0.08,
          gp = gpar(fill = "#81C784", col = "#2E7D32", lwd = 2))
grid.rect(x = 0.86, y = 0.77, width = 0.008, height = 0.04,
          gp = gpar(fill = "#2E7D32", col = NA))
grid.rect(x = 0.86, y = 0.77, width = 0.03, height = 0.008,
          gp = gpar(fill = "#2E7D32", col = NA))
for (wx in c(0.81, 0.86, 0.91)) {
  for (wy in c(0.61, 0.65, 0.69)) {
    grid.rect(x = wx, y = wy, width = 0.025, height = 0.025,
              gp = gpar(fill = "#E8F5E9", col = "#2E7D32", lwd = 0.5))
  }
}
grid.rect(x = 0.86, y = 0.57, width = 0.05, height = 0.04,
          gp = gpar(fill = "#2E7D32", col = "#1B5E20", lwd = 1))
grid.rect(x = 0.86, y = 0.595, width = 0.09, height = 0.02,
          gp = gpar(fill = "white", col = "#2E7D32", lwd = 1))
grid.text("CMS DAC", x = 0.86, y = 0.595,
          gp = gpar(fontsize = 6, fontface = "bold", col = "#2E7D32"))
grid.text("CMS Facility", x = 0.86, y = 0.50,
          gp = gpar(fontsize = 13, fontface = "bold", col = "#2E7D32"))
grid.text("Hospital affiliation from Medicare\nenrollment records, independent of self-report",
          x = 0.86, y = 0.46, gp = gpar(fontsize = 9, col = "gray30", lineheight = 1.2))

# ======== BOTTOM LEFT: NPPES SECONDARY (pl_pfile) ========
grid.rect(x = 0.35, y = 0.31, width = 0.10, height = 0.12,
          gp = gpar(fill = "#FFCC80", col = "#E65100", lwd = 2))
grid.polygon(x = c(0.29, 0.35, 0.41), y = c(0.37, 0.40, 0.37),
             gp = gpar(fill = "#E65100", col = "#BF360C", lwd = 2))
grid.rect(x = 0.32, y = 0.32, width = 0.025, height = 0.03,
          gp = gpar(fill = "#FFF3E0", col = "#E65100", lwd = 0.5))
grid.rect(x = 0.38, y = 0.32, width = 0.025, height = 0.03,
          gp = gpar(fill = "#FFF3E0", col = "#E65100", lwd = 0.5))
grid.rect(x = 0.35, y = 0.265, width = 0.025, height = 0.035,
          gp = gpar(fill = "#E65100", col = "#BF360C", lwd = 1))
grid.rect(x = 0.35, y = 0.355, width = 0.06, height = 0.015,
          gp = gpar(fill = "white", col = "#E65100", lwd = 0.5))
grid.text("PL FILE", x = 0.35, y = 0.355,
          gp = gpar(fontsize = 5, fontface = "bold", col = "#E65100"))
grid.text("NPPES Secondary", x = 0.35, y = 0.21,
          gp = gpar(fontsize = 12, fontface = "bold", col = "#E65100"))
grid.text("The 2nd+ practice location (pl_pfile)\nturns one NPI into several candidate sites",
          x = 0.35, y = 0.17, gp = gpar(fontsize = 9, col = "gray30", lineheight = 1.2))

# ======== BOTTOM RIGHT: TRILLIANT CLAIMS SITE (smaller) ========
grid.rect(x = 0.65, y = 0.32, width = 0.07, height = 0.09,
          gp = gpar(fill = "#CE93D8", col = "#6A1B9A", lwd = 2))
grid.polygon(x = c(0.61, 0.65, 0.69), y = c(0.365, 0.39, 0.365),
             gp = gpar(fill = "#6A1B9A", col = "#4A148C", lwd = 2))
grid.rect(x = 0.63, y = 0.33, width = 0.018, height = 0.022,
          gp = gpar(fill = "#F3E5F5", col = "#6A1B9A", lwd = 0.5))
grid.rect(x = 0.67, y = 0.33, width = 0.018, height = 0.022,
          gp = gpar(fill = "#F3E5F5", col = "#6A1B9A", lwd = 0.5))
grid.rect(x = 0.65, y = 0.28, width = 0.018, height = 0.025,
          gp = gpar(fill = "#6A1B9A", col = "#4A148C", lwd = 1))
grid.rect(x = 0.65, y = 0.35, width = 0.045, height = 0.012,
          gp = gpar(fill = "white", col = "#6A1B9A", lwd = 0.5))
grid.text("CLAIMS", x = 0.65, y = 0.35,
          gp = gpar(fontsize = 4, fontface = "bold", col = "#6A1B9A"))
grid.text("Trilliant Site", x = 0.65, y = 0.21,
          gp = gpar(fontsize = 12, fontface = "bold", col = "#6A1B9A"))
grid.text("Inferred from where care was\nactually billed -- newest, least externally checked",
          x = 0.65, y = 0.17, gp = gpar(fontsize = 9, col = "gray30", lineheight = 1.2))

# Bottom impact -- a real, cited number, not an invented one
grid.rect(x = 0.5, y = 0.06, width = 0.92, height = 0.08,
          gp = gpar(fill = "#FFEBEE", col = "#B71C1C", lwd = 1.5))
grid.text("Impact: switching to the current pl_pfile alone lifted cohort secondary locations from 2,687 to 5,303 -- no single address can be assumed to be where care happens.",
          x = 0.5, y = 0.06, gp = gpar(fontsize = 12, fontface = "bold", col = "#B71C1C"))

dev.off()
cat("Saved:", out, "\n")
