# =============================================================================
# Shared drawing style for the state-source audit figures
# =============================================================================
# WHY THIS IS A LIBRARY. These four things -- the validated categorical ramp,
# the label fitter, the abbreviation glossary and the saver -- were defined
# inside make_state_source_audit_figures.R, which is a 480-line script that
# parses a markdown appendix and cannot be sourced without running. A second
# figure script therefore had no way to reuse them, and ci_hygiene.R's H4
# forbids defining a top-level name in two tracked files -- correctly, because
# the duplication that matters here is not the NAME but the WORK: two savers
# would drift on size, dpi or label fitting, and the figures they wrote would
# stop being comparable while still looking finished.
#
# Nothing in the drawing changed when this moved. The ramp, the measurement
# and the save sizes are the committed ones.
# =============================================================================

suppressPackageStartupMessages({
  library(ggplot2); library(stringr)
})

AUDIT_FIG_DIR <- file.path("docs", "figures")

# Five hues now: the claims arm added a fifth multi-year series on
# 2026-11-14. #7a5195 keeps the worst contrast at 6.1:1 against white and is
# far from the blue/aqua pair on the hue circle.
AUDIT_SERIES <- c("#2a78d6", "#d2551f", "#0f8f62", "#9c6b00", "#7a5195")

# A LABEL THAT DOES NOT FIT IS DRAWN ANYWAY, AND ggsave REPORTS SUCCESS.
# base_size went 11 -> 13 on 2026-11-15 (eb8d693) but only two of the six
# figures were regenerated, so four kept their 11pt rendering and the repo
# stopped agreeing with the script that claims to produce it. Redrawn at 13
# they lose text with nothing failing: the consensus title ends "disagree
# abou", the multistate subtitle ends "43.8% were e". No test reads a figure,
# so a truncated sentence ships looking finished.
#
# Titles and captions are aligned to the plot rather than the panel, which
# gives them the whole canvas instead of whatever is left beside the axis
# labels, and each label is then wrapped to what that canvas actually holds.
# The width is MEASURED, never counted in characters: systemfonts is what
# svglite and ragg measure with at draw time, and the size comes from the
# plot's own completed theme, so a figure that overrides plot.subtitle is
# wrapped at the size it will really be drawn at. Change the font or the base
# size and the wrap moves; nothing silently falls off the edge.
fit_plot_labels <- function(p, width_in) {
  th <- ggplot2::complete_theme(p$theme)
  margin_pt <- as.numeric(grid::convertUnit(
    ggplot2::calc_element("plot.margin", th), "pt"))
  limit <- width_in * 72 - margin_pt[2] - margin_pt[4]
  for (part in c("title", "subtitle", "caption")) {
    label <- p$labels[[part]]
    if (!is.character(label) || length(label) != 1L || !nzchar(label)) next
    size <- ggplot2::calc_element(paste0("plot.", part), th)$size
    widest <- function(text) max(systemfonts::string_width(
      strsplit(text, "\n", fixed = TRUE)[[1]], size = size))
    flat <- gsub("[\r\n]+", " ", label)
    if (widest(flat) <= limit) { p$labels[[part]] <- flat; next }
    for (chars in seq(nchar(flat), 20L, by = -3L)) {
      wrapped <- stringr::str_wrap(flat, width = chars)
      if (widest(wrapped) <= limit) { p$labels[[part]] <- wrapped; break }
    }
  }
  p + ggplot2::theme(plot.title.position = "plot",
                     plot.caption.position = "plot")
}

# AND THE LEGEND IS A LABEL TOO -- fit_plot_labels() above measures the title,
# the subtitle and the caption, and for a long time that was the whole list.
# A legend is text on the same canvas, obeys none of that wrapping, and when a
# bottom legend is wider than the figure ggplot draws it anyway and centres the
# overflow, so it loses text from BOTH ends at once. That is what happened to
# state_source_agreement_by_year when the claims arm added a fifth series on
# 2026-11-14: the published figure reads "tem" where it should read "Record
# system", and the fifth series -- PECOS revalidation, a line plotted in the
# panel -- has no label at all. Five hues, one of them unnamed.
#
# The width is MEASURED, not estimated: the legend is built into its real grob
# and its real width asked for in points, then rows are added until it fits.
# Measuring the assembled guide box is what makes this independent of key size,
# spacing, title width and the font, none of which this function has to know.
#' The width of a plot's assembled legend, in points
#'
#' @param p [ggplot] the plot, with whatever guide settings it carries.
#' @return [numeric(1)] the widest guide box, or 0 when there is no legend.
legend_box_width_pt <- function(p) {
  g <- ggplot2::ggplotGrob(p)
  idx <- grep("guide-box", g$layout$name)
  if (!length(idx)) return(0)
  widths <- vapply(idx, function(i) {
    grb <- g$grobs[[i]]
    w <- grb$widths
    if (is.null(w) || !length(w)) return(0)
    sum(grid::convertWidth(w, "pt", valueOnly = TRUE))
  }, numeric(1))
  max(widths, 0)
}

#' Wrap a bottom or top legend onto as many rows as it takes to fit
#'
#' @param p [ggplot] the plot.
#' @param width_in [numeric(1)] the canvas width the figure will be saved at.
#' @param max_rows [integer(1)] the most rows to try before giving up and
#'   returning the narrowest arrangement found.
#' @return [ggplot] the plot, with legend rows set if it needed them.
fit_plot_legend <- function(p, width_in, max_rows = 4L) {
  th <- ggplot2::complete_theme(p$theme)
  pos <- ggplot2::calc_element("legend.position", th)
  if (!is.character(pos) || !pos %in% c("bottom", "top")) return(p)
  margin_pt <- as.numeric(grid::convertUnit(
    ggplot2::calc_element("plot.margin", th), "pt"))
  limit <- width_in * 72 - margin_pt[2] - margin_pt[4]
  if (legend_box_width_pt(p) <= limit) return(p)
  for (rows in 2:max_rows) {
    cand <- p + ggplot2::guides(
      colour = ggplot2::guide_legend(nrow = rows),
      fill   = ggplot2::guide_legend(nrow = rows))
    if (legend_box_width_pt(cand) <= limit) return(cand)
  }
  # Still too wide at max_rows: return the most-wrapped arrangement rather than
  # the original, because the alternative is shipping the clipped one.
  p + ggplot2::guides(
    colour = ggplot2::guide_legend(nrow = max_rows),
    fill   = ggplot2::guide_legend(nrow = max_rows))
}

# A FIGURE HAS TO READ ON ITS OWN. These plots travel into slides and reviews
# with no appendix beside them, and an axis tick has no room for "Provider
# Enrollment, Chain, and Ownership System", so the expansions go in the
# caption. That only became safe once fit_plot_labels() measured and wrapped:
# a longer caption used to be published with its first words cut off, which is
# exactly what happened to state_source_agreement_by_year, whose caption shipped
# starting mid-sentence at "of TECHNICAL_APPENDIX_...".
GLOSS <- c(
  NPPES = "National Plan and Provider Enumeration System",
  DAC   = "Doctors and Clinicians, formerly Physician Compare",
  PECOS = "Provider Enrollment, Chain, and Ownership System",
  CCN   = "CMS Certification Number",
  NDH   = "National Directory of Healthcare Providers",
  FHIR  = "Fast Healthcare Interoperability Resources",
  CMS   = "Centers for Medicare & Medicaid Services",
  OIG   = "HHS Office of Inspector General")

#' Caption tail defining the abbreviations one figure actually shows
#'
#' @param ... abbreviations, which must be names of `GLOSS`.
#' @return [character(1)] " NPPES = ...; DAC = ...." for pasting onto a caption.
gloss <- function(...) {
  keys <- c(...)
  unknown <- setdiff(keys, names(GLOSS))
  if (length(unknown))
    stop(sprintf("gloss(): no expansion for %s", paste(unknown, collapse = ", ")),
         call. = FALSE)
  paste0("; ", paste(sprintf("%s = %s", keys, GLOSS[keys]), collapse = "; "), ".")
}

#' Write one figure as png, pdf and svg at one measured size
#'
#' @param p [ggplot] the plot.
#' @param name [character(1)] basename, no extension.
#' @param width,height [numeric(1)] inches; the width is what the label
#'   fitter measures against, so the two cannot disagree.
#' @param out_dir [character(1)] directory. Defaults to docs/figures rather
#'   than reading a caller's global, which is what it used to do.
#' @return invisible NULL; writes three files.
save_audit_fig <- function(p, name, width = 8.5, height = 5.4,
                           out_dir = AUDIT_FIG_DIR) {
  p <- fit_plot_labels(p, width)
  p <- fit_plot_legend(p, width)
  out <- file.path(out_dir, name)
  ggsave(paste0(out, ".pdf"), p, width = width, height = height,
         device = grDevices::cairo_pdf)
  ggsave(paste0(out, ".png"), p, width = width, height = height, dpi = 300, bg = "white")
  tryCatch(ggsave(paste0(out, ".svg"), p, width = width, height = height),
           error = function(e) message("  (svg skipped: ", conditionMessage(e), ")"))
  cat(sprintf("  wrote %s.{png,pdf,svg}\n", out))
}
