# =============================================================================
# Branching flow diagrams that render to a file
# =============================================================================
# WHY THIS EXISTS, having checked five existing implementations first.
#
#   ~/mysterycall  mysterycall_flowchart(), plot_consort(), flow_diagram(),
#                  strobe_flow()  -- four overlapping CONSORT helpers
#   ~/isochrones   generate_unified_consort_diagram()
#
# All five draw a LADDER: one vertical spine of steps with exclusions falling
# off to the side. That is the right shape for a CONSORT trial diagram and the
# wrong shape for a linkage study, where the flow branches three ways at the
# roster, MERGES two strata into one cohort, and fans again at the outcome
# strata. A steps/exclusions API cannot express a merge.
#
# The mysterycall helpers also return DiagrammeR::grViz(), an HTML widget.
# Turning that into a manuscript figure needs DiagrammeRsvg plus rsvg or
# webshot; none is installed here, and neither are rsvg-convert, cairosvg,
# magick or inkscape. grid draws straight into pdf(), png() and svglite(), so
# the figure has no dependency the manuscript render does not already have.
#
# WHAT IT DOES NOT DO: automatic edge routing around obstacles, or any layout
# search. Tiers are explicit and horizontal placement is either even or given.
# A diagram that needs more than that wants a real graphics tool, and saying so
# here is cheaper than growing a layout engine one special case at a time.
# =============================================================================

suppressPackageStartupMessages(library(grid))

FD_INK <- "#111820"; FD_MUTED <- "#5b6875"; FD_RULE <- "#c8d0d9"
FD_ACCENT <- "#1f6360"; FD_SOFT <- "#e9f1f0"; FD_PAPER <- "#ffffff"

#' One node
#'
#' @param id used by edges.
#' @param tier integer, 1 at the top. Tiers stack; nodes within a tier sit side
#'   by side.
#' @param at horizontal centre in 0..1 of the canvas. NA distributes the tier
#'   evenly -- correct for a symmetric fan, wrong the moment a tier is
#'   asymmetric, which is why it can be given.
#' @param kind lead (filled), keep (accent), band (accent top rule), drop
#'   (dashed, leaves the flow), plain.
#' @keywords internal
fd_node <- function(id, tier, label, value = NA_character_, sub = NA_character_,
                    at = NA_real_, kind = "plain", w = 200) {
  data.frame(id = id, tier = tier, label = label, value = value, sub = sub,
             at = at, kind = kind, w = w, stringsAsFactors = FALSE)
}

#' One edge. `label` rides on the horizontal run, where there is room for it.
#' @keywords internal
fd_edge <- function(from, to, label = NA_character_, kind = "plain") {
  data.frame(from = from, to = to, label = label, kind = kind,
             stringsAsFactors = FALSE)
}

#' Place nodes on a virtual canvas
#'
#' Node height follows its line count, so a node with a sub-label is taller
#' rather than having its sub-label pushed onto the border -- which is what the
#' first hand-placed version of this figure did.
#' @keywords internal
fd_layout <- function(nodes, canvas_w = 1000, tier_gap = 78, pad_top = 14) {
  # An unrecognized kind must fail here, not fall through to fd_render()'s
  # switch() default. It used to fall through via a "multi" special case that
  # set h to NA -- max(nodes$h[i]) then propagated that NA into every
  # SUBSEQUENT tier's y position (max() does not drop NA by default), silently
  # corrupting the entire rest of the diagram below the offending node with no
  # error anywhere in the pipeline. "multi" was never a documented kind (see
  # fd_node()'s own @param kind list) and had no live caller.
  valid_kinds <- c("lead", "keep", "band", "drop", "plain")
  bad_kind <- setdiff(unique(nodes$kind), valid_kinds)
  if (length(bad_kind))
    stop(sprintf("fd_layout(): unrecognized node kind(s): %s. Valid kinds: %s.",
                 paste(bad_kind, collapse = ", "), paste(valid_kinds, collapse = ", ")),
         call. = FALSE)
  nodes$lines <- 1L + (!is.na(nodes$value)) + (!is.na(nodes$sub))
  nodes$h <- 26 + 22 * (nodes$lines - 1L)
  y <- pad_top
  for (t in sort(unique(nodes$tier))) {
    i <- nodes$tier == t
    nodes$y[i] <- y
    y <- y + max(nodes$h[i]) + tier_gap
  }
  for (t in sort(unique(nodes$tier))) {
    i <- which(nodes$tier == t)
    given <- !is.na(nodes$at[i])
    if (all(given)) {
      nodes$cx[i] <- nodes$at[i] * canvas_w
    } else {
      k <- length(i); span <- canvas_w / k
      nodes$cx[i] <- (seq_len(k) - 0.5) * span
      nodes$cx[i][given] <- nodes$at[i][given] * canvas_w
    }
  }
  # A node pushed past either edge by its `at` is nudged back in. Clipping a box
  # off-canvas loses a count silently; moving it shows the spec is wrong.
  nodes$cx <- pmin(pmax(nodes$cx, nodes$w / 2 + 4), canvas_w - nodes$w / 2 - 4)
  nodes$x <- nodes$cx - nodes$w / 2
  nodes$bottom <- nodes$y + nodes$h
  nodes
}

#' Draw. Every edge leaves its source's bottom, runs to a shared horizontal
#' band, and enters its target's top -- the routing a reader expects, and the
#' only one this needs.
#' @keywords internal
fd_render <- function(nodes, edges, canvas_w = 1000, canvas_h = NULL) {
  # An edge naming a node id that does not exist (a typo) previously rendered
  # with no error: nodes[nodes$id == bad_id, ] returns a 0-row frame, so a$cx/
  # a$bottom become numeric(0) and the c()'d coordinate vector for that edge
  # silently drops elements rather than signalling anything. A missing arrow
  # in a cohort flow diagram is a missing TRANSITION, not a cosmetic gap.
  missing_ids <- setdiff(c(edges$from, edges$to), nodes$id)
  if (length(missing_ids))
    stop(sprintf("fd_render(): edge(s) reference undefined node id(s): %s.",
                 paste(unique(missing_ids), collapse = ", ")), call. = FALSE)
  if (is.null(canvas_h)) canvas_h <- max(nodes$bottom) + 40
  ty <- function(v) canvas_h - v
  grid.newpage()
  pushViewport(viewport(xscale = c(0, canvas_w), yscale = c(0, canvas_h)))
  grid.rect(gp = gpar(fill = FD_PAPER, col = NA))

  for (e in seq_len(nrow(edges))) {
    a <- nodes[nodes$id == edges$from[e], ]; b <- nodes[nodes$id == edges$to[e], ]
    acc <- edges$kind[e] == "accent"; dsh <- edges$kind[e] == "dashed"
    band <- a$bottom + (b$y - a$bottom) / 2
    gp <- gpar(col = if (acc) FD_ACCENT else FD_MUTED, lwd = if (acc) 1.5 else 1,
               lty = if (dsh) "22" else "solid",
               fill = if (acc) FD_ACCENT else FD_MUTED)
    grid.lines(x = c(a$cx, a$cx, b$cx, b$cx),
               y = ty(c(a$bottom, band, band, b$y)), default.units = "native",
               gp = gp, arrow = arrow(length = unit(5, "pt"), type = "closed"))
    if (!is.na(edges$label[e])) {
      # CLAMPED TO THE CANVAS. Monospace at 7pt is far wider in native units
      # than it looks in the spec, and a label centred on a short horizontal run
      # near the edge silently renders off-canvas -- which is how the first
      # version of this figure lost the left half of two labels. Measured, not
      # estimated.
      gpl <- gpar(col = if (acc) FD_ACCENT else FD_MUTED, fontsize = 7,
                  fontfamily = "mono")
      half <- convertWidth(grobWidth(textGrob(edges$label[e], gp = gpl)),
                           "native", valueOnly = TRUE) / 2
      lx <- min(max((a$cx + b$cx) / 2, half + 4), canvas_w - half - 4)
      # HALO. A merge puts the label's midpoint directly over the vertical
      # dropping from one of its sources, and moving the text just moves the
      # collision somewhere else. Knocking the line out behind the text is what
      # a draughtsman does, and it works for every edge rather than this one.
      grid.rect(x = lx, y = ty(band - 9), width = 2 * half + 8,
                height = unit(9, "pt"), default.units = "native",
                gp = gpar(fill = FD_PAPER, col = NA))
      grid.text(edges$label[e], x = lx, y = ty(band - 9),
                default.units = "native", gp = gpl)
    }
  }

  for (i in seq_len(nrow(nodes))) {
    n <- nodes[i, ]
    fill <- switch(n$kind, lead = FD_INK, keep = FD_SOFT, drop = FD_PAPER, FD_PAPER)
    col  <- switch(n$kind, lead = FD_INK, keep = FD_ACCENT, drop = FD_RULE, FD_RULE)
    grid.roundrect(x = n$cx, y = ty(n$y + n$h / 2), width = n$w, height = n$h,
                   r = unit(3, "pt"), default.units = "native",
                   gp = gpar(fill = fill, col = col,
                             lty = if (n$kind == "drop") "22" else "solid",
                             lwd = if (n$kind == "keep") 1.4 else 0.8))
    if (n$kind == "band")
      grid.lines(x = c(n$x, n$x + n$w), y = ty(c(n$y, n$y)),
                 default.units = "native", gp = gpar(col = FD_ACCENT, lwd = 2.2))
    txt <- if (n$kind == "lead") FD_PAPER else FD_MUTED
    val <- if (n$kind == "lead") FD_PAPER else FD_INK
    lx <- n$x + 13; ly <- n$y + 17
    grid.text(n$label, x = lx, y = ty(ly), just = "left", default.units = "native",
              gp = gpar(col = txt, fontsize = 8.2))
    if (!is.na(n$value))
      grid.text(n$value, x = lx, y = ty(ly + 24), just = "left",
                default.units = "native",
                gp = gpar(col = val, fontsize = 13, fontfamily = "mono"))
    if (!is.na(n$sub))
      grid.text(n$sub, x = lx, y = ty(ly + 24 + 18), just = "left",
                default.units = "native", gp = gpar(col = txt, fontsize = 7))
  }
  popViewport()
}

#' Render to pdf, png and svg at one aspect ratio
#' @keywords internal
fd_write <- function(nodes, edges, base, width_in = 7.6, canvas_w = 1000,
                     canvas_h = NULL, extra = NULL) {
  lay <- fd_layout(nodes, canvas_w = canvas_w)
  if (is.null(canvas_h)) canvas_h <- max(lay$bottom) + 40
  h_in <- width_in * canvas_h / canvas_w
  draw <- function() {
    fd_render(lay, edges, canvas_w, canvas_h)
    if (is.function(extra)) extra(lay, canvas_w, canvas_h)
  }
  dir.create(dirname(base), showWarnings = FALSE, recursive = TRUE)
  pdf(paste0(base, ".pdf"), width = width_in, height = h_in); draw(); invisible(dev.off())
  png(paste0(base, ".png"), width = width_in * 300, height = h_in * 300, res = 300); draw(); invisible(dev.off())
  if (requireNamespace("svglite", quietly = TRUE)) {
    svglite::svglite(paste0(base, ".svg"), width = width_in, height = h_in); draw(); invisible(dev.off())
  }
  invisible(lay)
}
