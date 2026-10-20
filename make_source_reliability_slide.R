#!/usr/bin/env Rscript
# =============================================================================
# make_source_reliability_slide.R -- Where Location Reliability Actually Comes From
# =============================================================================
# Adapted from ~/isochrones/scripts/make_subspecialty_sources_slide.R (same
# spectrum-of-cards layout) for this project's four sources. The axis here is
# LOCATION reliability, not credential reliability -- AMCB is authoritative
# for certification status but publishes no location at all, which is the
# opposite failure mode from the isochrones ABMS/NPPES case this was built
# from. The isochrones version's bottom accuracy-percentage bars are dropped:
# this project has no measured location-accuracy figure per source to put
# there, and inventing one would be exactly the kind of typed-not-computed
# number this project's own NEWS.md keeps retracting elsewhere.
#
# Output: docs/figures/source_reliability_spectrum.png
# Format: 13.33 x 7.5 in (16:9 PPT), 300 DPI, white background
# Usage:  Rscript make_source_reliability_slide.R
# =============================================================================

library(grid)

out <- "docs/figures/source_reliability_spectrum.png"
dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
png(out, width = 13.33, height = 7.5, units = "in", res = 300, bg = "white")
grid.newpage()

# Title bar
grid.rect(x = 0.5, y = 0.94, width = 1, height = 0.12,
          gp = gpar(fill = "#1A237E", col = NA))
grid.text("Where Does Location Reliability Actually Come From?",
          x = 0.5, y = 0.96, gp = gpar(col = "white", fontsize = 23, fontface = "bold"))
grid.text("The source with the best credential data has none of the location data, and vice versa",
          x = 0.5, y = 0.91, gp = gpar(col = "#C5CAE9", fontsize = 12))

# ---- Reliability spectrum bar ----
grid.rect(x = 0.5, y = 0.83, width = 0.80, height = 0.015,
          gp = gpar(fill = NA, col = "gray70", lwd = 1))
n_seg <- 100
for (i in seq_len(n_seg)) {
  x_start <- 0.10 + (i - 1) * 0.80 / n_seg
  r <- as.integer(255 * (1 - (i - 1) / n_seg))
  g <- as.integer(200 * (i - 1) / n_seg)
  col <- rgb(r, g, 50, maxColorValue = 255)
  grid.rect(x = x_start + 0.004, y = 0.83, width = 0.80 / n_seg, height = 0.015,
            gp = gpar(fill = col, col = NA))
}
grid.text("No Location Data", x = 0.13, y = 0.805,
          gp = gpar(fontsize = 9, fontface = "bold", col = "#C62828"))
grid.text("Reflects Actual Billed Location", x = 0.87, y = 0.805,
          gp = gpar(fontsize = 9, fontface = "bold", col = "#2E7D32"))
grid.text("Location Reliability Spectrum", x = 0.5, y = 0.805,
          gp = gpar(fontsize = 8, col = "gray50"))

# ---- Source 1: AMCB (leftmost -- zero location) ----
x1 <- 0.14
grid.roundrect(x = x1, y = 0.60, width = 0.22, height = 0.30,
               r = unit(0.015, "npc"),
               gp = gpar(fill = "#FFEBEE", col = "#C62828", lwd = 2.5))
grid.circle(x = 0.18, y = 0.83, r = 0.008,
            gp = gpar(fill = "#C62828", col = "white", lwd = 1.5))
grid.lines(x = c(0.18, x1), y = c(0.822, 0.75),
           gp = gpar(col = "#C62828", lwd = 1, lty = "dashed"))

grid.text("AMCB", x = x1, y = 0.72,
          gp = gpar(fontsize = 16, fontface = "bold", col = "#C62828"))
grid.text("(Public Directory)", x = x1, y = 0.69,
          gp = gpar(fontsize = 9, col = "#C62828"))
grid.rect(x = x1, y = 0.64, width = 0.18, height = 0.002,
          gp = gpar(fill = "#FFCDD2", col = NA))
grid.text("Authoritative for credential,\nZERO location data", x = x1, y = 0.60,
          gp = gpar(fontsize = 9.5, fontface = "bold", col = "#B71C1C", lineheight = 1.2))
grid.text("\"Not considered primary source\"\n(AMCB's own words)\nNo address, city, state or ZIP\nLocation verification is paywalled,\nper-record -- never scraped here", x = x1, y = 0.51,
          gp = gpar(fontsize = 8.5, col = "gray30", lineheight = 1.25))

# ---- Source 2: NPPES ----
x2 <- 0.40
grid.roundrect(x = x2, y = 0.60, width = 0.22, height = 0.30,
               r = unit(0.015, "npc"),
               gp = gpar(fill = "#FFF3E0", col = "#E65100", lwd = 2.5))
grid.circle(x = 0.37, y = 0.83, r = 0.008,
            gp = gpar(fill = "#E65100", col = "white", lwd = 1.5))
grid.lines(x = c(0.37, x2), y = c(0.822, 0.75),
           gp = gpar(col = "#E65100", lwd = 1, lty = "dashed"))

grid.text("NPPES", x = x2, y = 0.72,
          gp = gpar(fontsize = 16, fontface = "bold", col = "#E65100"))
grid.text("(Provider Registry)", x = x2, y = 0.69,
          gp = gpar(fontsize = 9, col = "#E65100"))
grid.rect(x = x2, y = 0.64, width = 0.18, height = 0.002,
          gp = gpar(fill = "#FFE0B2", col = NA))
grid.text("Practice address is\nSELF-ENUMERATED by the provider", x = x2, y = 0.60,
          gp = gpar(fontsize = 9.5, fontface = "bold", col = "#BF360C", lineheight = 1.2))
grid.text("Often a billing address, not\nthe exam room\nCan go stale between updates\nSecondary locations (pl_pfile)\noften missing entirely", x = x2, y = 0.51,
          gp = gpar(fontsize = 8.5, col = "gray30", lineheight = 1.25))

# ---- Source 3: CMS Doctors & Clinicians (DAC) ----
x3 <- 0.66
grid.roundrect(x = x3, y = 0.60, width = 0.22, height = 0.30,
               r = unit(0.015, "npc"),
               gp = gpar(fill = "#E8F5E9", col = "#2E7D32", lwd = 2.5))
grid.circle(x = 0.64, y = 0.83, r = 0.008,
            gp = gpar(fill = "#2E7D32", col = "white", lwd = 1.5))
grid.lines(x = c(0.64, x3), y = c(0.822, 0.75),
           gp = gpar(col = "#2E7D32", lwd = 1, lty = "dashed"))

grid.text("CMS DAC", x = x3, y = 0.72,
          gp = gpar(fontsize = 16, fontface = "bold", col = "#2E7D32"))
grid.text("(Federal Admin Data)", x = x3, y = 0.69,
          gp = gpar(fontsize = 9, col = "#2E7D32"))
grid.rect(x = x3, y = 0.64, width = 0.18, height = 0.002,
          gp = gpar(fill = "#C8E6C9", col = NA))
grid.text("Facility affiliation from\nMedicare enrollment records", x = x3, y = 0.60,
          gp = gpar(fontsize = 9.5, fontface = "bold", col = "#1B5E20", lineheight = 1.2))
grid.text("Independent of self-report\nHospital-level, not exact suite\nCoverage limited to\nMedicare-enrolled clinicians\nUpdated on CMS's own cycle", x = x3, y = 0.51,
          gp = gpar(fontsize = 8.5, col = "gray30", lineheight = 1.25))

# ---- Source 4: Trilliant claims (rightmost) ----
x4 <- 0.88
grid.roundrect(x = x4, y = 0.60, width = 0.18, height = 0.30,
               r = unit(0.015, "npc"),
               gp = gpar(fill = "#E8F5E9", col = "#1B5E20", lwd = 3))
grid.circle(x = 0.88, y = 0.83, r = 0.01,
            gp = gpar(fill = "#FFD600", col = "#F57F17", lwd = 2))
grid.lines(x = c(0.88, x4), y = c(0.82, 0.75),
           gp = gpar(col = "#1B5E20", lwd = 1.5, lty = "dashed"))

grid.text("Trilliant", x = x4, y = 0.72,
          gp = gpar(fontsize = 16, fontface = "bold", col = "#1B5E20"))
grid.text("(Claims-Derived)", x = x4, y = 0.69,
          gp = gpar(fontsize = 9, col = "#1B5E20", fontface = "italic"))
grid.rect(x = x4, y = 0.64, width = 0.14, height = 0.002,
          gp = gpar(fill = "#A5D6A7", col = NA))
grid.text("Work site inferred from\nwhere care was BILLED", x = x4, y = 0.60,
          gp = gpar(fontsize = 9.5, fontface = "bold", col = "#1B5E20", lineheight = 1.2))
grid.text("Reflects billed activity, not\nself-enumeration\nPatient-panel mix comes free\nCoverage: active-flagged\nsubset only, newest layer", x = x4, y = 0.51,
          gp = gpar(fontsize = 8.5, col = "gray30", lineheight = 1.25))

# ---- Bottom: The Core Challenge ----
grid.rect(x = 0.5, y = 0.22, width = 0.92, height = 0.24,
          gp = gpar(fill = "#E8EAF6", col = "#1A237E", lwd = 2))

grid.text("The Core Challenge", x = 0.5, y = 0.33,
          gp = gpar(fontsize = 16, fontface = "bold", col = "#1A237E"))

grid.text("AMCB is the authoritative credential source but has NO location data at all.",
          x = 0.5, y = 0.29,
          gp = gpar(fontsize = 12, col = "#283593"))
grid.text("NPPES has location data but it is self-enumerated and can drift from where care happens.",
          x = 0.5, y = 0.26,
          gp = gpar(fontsize = 12, col = "#283593"))
grid.text("Solution: resolve identity AMCB -> NPPES by name-evidence class, then cross-check location",
          x = 0.5, y = 0.22,
          gp = gpar(fontsize = 12, fontface = "bold", col = "#1A237E"))
grid.text("against CMS DAC and Trilliant rather than trusting any single source alone.",
          x = 0.5, y = 0.19,
          gp = gpar(fontsize = 12, fontface = "bold", col = "#1A237E"))

dev.off()
cat("Saved:", out, "\n")
