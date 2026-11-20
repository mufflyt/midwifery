#!/usr/bin/env Rscript
# =============================================================================
# Figure 2 -- where location information in this cohort comes from
# =============================================================================
# WHY THIS WAS REWRITTEN. This file used to be make_source_reliability_slide.R
# and it drew a slide: a navy title bar, a red-to-green gradient "reliability
# spectrum", four rounded cards and a boxed "The Core Challenge / Solution"
# panel with a large empty area under it. It was adapted from a conference
# deck in ~/isochrones and then used, unchanged, as Figure 2 of a journal
# manuscript. Three things were wrong with that, none of them cosmetic:
#
#   1. IT NAMED A SOURCE THE PAPER DOES NOT EXAMINE. The fourth card was
#      Trilliant, a commercial provider directory. The manuscript's Table 1
#      lists eleven record systems and Trilliant is not one of them, so a
#      reader checking the figure against the table found a source that is
#      nowhere else in the paper. The billing-derived role it illustrated
#      belongs to Medicare claims (Parts B and D), which IS in Table 1 and is
#      what the Results actually lean on.
#   2. THE GRADIENT WAS RED TO GREEN, the one ramp a colour-blind reader
#      cannot decode, and it carried no data -- position along it was
#      authored, not measured.
#   3. IT DID NOT READ AS A FIGURE. A "Solution:" statement belongs in a
#      Discussion, not in a figure a journal will typeset.
#
# WHAT IS DRAWN NOW. One tile per (source, property), labelled in words as
# well as in colour, so the inversion the text claims -- that the source which
# is authoritative for the credential carries no location at all, and every
# source carrying a location is either self-reported or derived from billing
# -- is readable directly off the panel.
#
# THESE CELLS ARE DOCUMENTED PROPERTIES, NOT MEASUREMENTS. Each one states how
# a system is populated, which is a fact about the system and is cited in the
# Methods; none of them is a computed accuracy. The figure says so in its
# caption rather than letting a reader take the ordering for a result.
#
# Output: docs/figures/source_reliability_spectrum.png (+pdf/svg)
# Usage:  Rscript make_source_reliability_figure.R
# =============================================================================

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(tidyr)
})
source(file.path("R", "lib", "audit_figure_style.R"))

# Ordered from no location information to location observed in billing. The
# order is the figure's argument and is stated in the caption; it is not a
# measured scale, so nothing is drawn on a numeric axis.
SOURCE_PROPERTIES <- tibble::tribble(
  ~source,                            ~property,            ~value,
  "AMCB roster\n(certifying body)",   "Credential",         "Authoritative",
  "AMCB roster\n(certifying body)",   "Practice location",  "Not carried",
  "NPPES\n(provider registry)",       "Credential",         "Self-reported",
  "NPPES\n(provider registry)",       "Practice location",  "Self-reported",
  "Medicare DAC\n(clinician directory)", "Credential",      "Administrative",
  "Medicare DAC\n(clinician directory)", "Practice location", "Administrative",
  "Medicare claims\n(Parts B and D)", "Credential",         "Not carried",
  "Medicare claims\n(Parts B and D)", "Practice location",  "Billing-derived")

VALUE_LEVELS <- c("Authoritative", "Administrative", "Billing-derived",
                  "Self-reported", "Not carried")
# Four hues from the validated audit ramp plus a neutral for the absent cells.
# Not a sequential ramp: these are kinds of provenance, not degrees of one.
VALUE_FILL <- c(Authoritative   = AUDIT_SERIES[3],
                Administrative  = AUDIT_SERIES[1],
                `Billing-derived` = AUDIT_SERIES[5],
                `Self-reported` = AUDIT_SERIES[2],
                `Not carried`   = "grey82")
# White on the four saturated fills, dark on the neutral one.
VALUE_INK <- c(Authoritative = "white", Administrative = "white",
               `Billing-derived` = "white", `Self-reported` = "white",
               `Not carried` = "grey20")

d <- SOURCE_PROPERTIES %>%
  mutate(source = factor(source, levels = rev(unique(SOURCE_PROPERTIES$source))),
         property = factor(property, levels = c("Credential", "Practice location")),
         value = factor(value, levels = VALUE_LEVELS))

p <- ggplot(d, aes(x = property, y = source, fill = value)) +
  geom_tile(colour = "white", linewidth = 2.2) +
  geom_text(aes(label = value, colour = value), size = 3.5, fontface = "bold",
            show.legend = FALSE) +
  scale_fill_manual(values = VALUE_FILL, breaks = VALUE_LEVELS) +
  scale_colour_manual(values = VALUE_INK, guide = "none") +
  scale_x_discrete(position = "top", expand = expansion(0)) +
  scale_y_discrete(expand = expansion(0)) +
  labs(title = "The source with the strongest credential data carries no location data",
       subtitle = paste0("How each system is populated for the two attributes this ",
                         "study compares. Ordered from no location information ",
                         "to location observed in billing."),
       caption = paste0("Documented properties of each record system, not ",
                        "measured accuracy; sources as listed in Table 1",
                        gloss("NPPES", "DAC")),
       x = NULL, y = NULL, fill = NULL) +
  theme_minimal(base_size = 13) +
  theme(legend.position = "bottom",
        panel.grid = element_blank(),
        axis.text.x.top = element_text(face = "bold"),
        axis.text.y = element_text(lineheight = 0.95),
        plot.subtitle = element_text(size = 9.3, lineheight = 1.2))

save_audit_fig(p, "source_reliability_spectrum", width = 8.5, height = 5.0)
cat("done\n")
