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

# All node text (label/value/sub) renders at one uniform 12pt, so one uniform
# per-line vertical gap replaces the old label/value/sub-specific offsets
# (24, then 18) that were tuned for three different font sizes (8.2/13/7pt).
# Getting this wrong is not cosmetic: it's why "2,351" and its two-line sub
# label rendered on top of each other below -- the old fixed 18pt gap between
# a 13pt value line and its sub was already tight, and every node's text grew
# to 12pt without this gap growing with it.
FD_LINE_GAP <- 26

#' Count the number of visual lines in a node text field
#'
#' A `sub` field can carry an embedded "\n" for a deliberate two-line label
#' (e.g. "unmatched, or ambiguous and not\nresolved to one NPI"). Node height
#' and line spacing MUST know about that second line -- the previous version
#' only checked `!is.na(sub)`, which reserved space for the sub field's first
#' line and let the second line print directly on top of whatever came next.
#' @keywords internal
#' @noRd
.fd_nlines <- function(x) {
  if (is.na(x)) return(0L)
  lengths(gregexpr("\n", x, fixed = TRUE)) + 1L
}

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
  # Each field's OWN line count, not just whether it's present -- a
  # multi-line `sub` (embedded "\n") needs its full height reserved, or its
  # second line prints past the bottom of the box into whatever is below it.
  n_label <- vapply(nodes$label, .fd_nlines, integer(1))
  n_value <- vapply(nodes$value, .fd_nlines, integer(1))
  n_sub   <- vapply(nodes$sub,   .fd_nlines, integer(1))
  nodes$lines <- n_label + n_value + n_sub
  nodes$h <- 14 + FD_LINE_GAP * nodes$lines
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

#' Named colour/font sets `fd_render()`/`fd_write()` accept via `theme`.
#'
#' `NULL` (the default everywhere) resolves to `fd_theme_default()`, so every
#' existing call site (make_cohort_flow_figure.R included) renders exactly as
#' before. `fd_theme_journal()` is monochrome -- white fill, black border and
#' text throughout, weight rather than colour carrying emphasis -- for
#' figures headed to print in a journal that will greyscale a colour figure
#' on the way to the page anyway.
#' @keywords internal
fd_theme_default <- function() {
  list(ink = FD_INK, muted = FD_MUTED, rule = FD_RULE, accent = FD_ACCENT,
       soft = FD_SOFT, paper = FD_PAPER, font = NULL,
       corner = 3, reverse_lead = TRUE, dashed_drop = TRUE)
}

#' @rdname fd_theme_default
#'
#' @section Journal theme specifics:
#' Modelled directly on the classic CONSORT template (sharp-cornered boxes,
#' uniform white fill/black border throughout, no reversed "anchor" box, no
#' dashed exclusion border -- every box reads the same, distinguished only by
#' its position and its label text, exactly as in a published CONSORT
#' flowchart) rather than on this library's own softer default look.
#' @keywords internal
fd_theme_journal <- function() {
  list(ink = "#000000", muted = "#000000", rule = "#000000", accent = "#000000",
       soft = "#ffffff", paper = "#ffffff", font = "sans",
       corner = 0, reverse_lead = FALSE, dashed_drop = FALSE)
}

#' Draw. Every edge leaves its source's bottom, runs to a shared horizontal
#' band, and enters its target's top -- the routing a reader expects, and the
#' only one this needs.
#' @param theme [list] or NULL: colour/font set from `fd_theme_default()` /
#'   `fd_theme_journal()`. NULL (default) keeps the original look.
#' @keywords internal
fd_render <- function(nodes, edges, canvas_w = 1000, canvas_h = NULL, theme = NULL) {
  pal <- if (is.null(theme)) fd_theme_default() else theme
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
  grid.rect(gp = gpar(fill = pal$paper, col = NA))

  # TWO PASSES: every edge's LINE first, then every label's halo+text on top,
  # never interleaved per-edge. Two edges from the same source (e.g. roster
  # -> active and roster -> inactive) share the same vertical drop-out x, so
  # when the lines and labels were drawn per-edge in one pass, an unlabelled
  # sibling edge processed AFTER a labelled one silently repainted its bare
  # line straight over the first edge's halo+text -- undoing the mask that
  # was supposed to keep the arrow from crossing the words. A label can only
  # be guaranteed to stay on top if nothing else draws after it.
  edge_geom <- vector("list", nrow(edges))
  for (e in seq_len(nrow(edges))) {
    a <- nodes[nodes$id == edges$from[e], ]; b <- nodes[nodes$id == edges$to[e], ]
    acc <- edges$kind[e] == "accent"; dsh <- edges$kind[e] == "dashed"
    band <- a$bottom + (b$y - a$bottom) / 2
    gp <- gpar(col = if (acc) pal$accent else pal$muted, lwd = if (acc) 1.5 else 1,
               lty = if (dsh) "22" else "solid",
               fill = if (acc) pal$accent else pal$muted)
    grid.lines(x = c(a$cx, a$cx, b$cx, b$cx),
               y = ty(c(a$bottom, band, band, b$y)), default.units = "native",
               gp = gp, arrow = arrow(length = unit(5, "pt"), type = "closed"))
    edge_geom[[e]] <- list(a = a, b = b, acc = acc, band = band)
  }
  for (e in seq_len(nrow(edges))) {
    if (is.na(edges$label[e])) next
    g <- edge_geom[[e]]
    # CLAMPED TO THE CANVAS. Monospace at 7pt is far wider in native units
    # than it looks in the spec, and a label centred on a short horizontal run
    # near the edge silently renders off-canvas -- which is how the first
    # version of this figure lost the left half of two labels. Measured, not
    # estimated.
    gpl <- gpar(col = if (g$acc) pal$accent else pal$muted, fontsize = 12,
                fontfamily = if (is.null(pal$font)) "mono" else pal$font)
    half <- convertWidth(grobWidth(textGrob(edges$label[e], gp = gpl)),
                         "native", valueOnly = TRUE) / 2
    lx <- min(max((g$a$cx + g$b$cx) / 2, half + 4), canvas_w - half - 4)
    # HALO. A merge puts the label's midpoint directly over the vertical
    # dropping from one of its sources, and moving the text just moves the
    # collision somewhere else. Knocking the line out behind the text is what
    # a draughtsman does, and it works for every edge rather than this one.
    # 15pt (was 9pt, sized for a smaller pre-12pt-everywhere edge-label font)
    # so a 12pt glyph's ascenders/descenders are fully covered rather than
    # poking out above or below the masked band.
    grid.rect(x = lx, y = ty(g$band - 9), width = 2 * half + 8,
              height = unit(15, "pt"), default.units = "native",
              gp = gpar(fill = pal$paper, col = NA))
    grid.text(edges$label[e], x = lx, y = ty(g$band - 9),
              default.units = "native", gp = gpl)
  }

  # Unset fields fall back to the default theme's values, so a hand-built
  # theme list that predates these fields still renders as it did before.
  dflt <- fd_theme_default()
  corner_pt    <- if (is.null(pal$corner)) dflt$corner else pal$corner
  reverse_lead <- if (is.null(pal$reverse_lead)) dflt$reverse_lead else pal$reverse_lead
  dashed_drop  <- if (is.null(pal$dashed_drop)) dflt$dashed_drop else pal$dashed_drop

  for (i in seq_len(nrow(nodes))) {
    n <- nodes[i, ]
    lead_reversed <- n$kind == "lead" && reverse_lead
    fill <- if (lead_reversed) pal$ink
            else switch(n$kind, keep = pal$soft, drop = pal$paper, pal$paper)
    col  <- switch(n$kind, lead = pal$ink, keep = pal$accent, drop = pal$rule, pal$rule)
    grid.roundrect(x = n$cx, y = ty(n$y + n$h / 2), width = n$w, height = n$h,
                   r = unit(corner_pt, "pt"), default.units = "native",
                   gp = gpar(fill = fill, col = col,
                             lty = if (n$kind == "drop" && dashed_drop) "22" else "solid",
                             lwd = if (n$kind == "keep") 1.4 else 0.8))
    if (n$kind == "band")
      grid.lines(x = c(n$x, n$x + n$w), y = ty(c(n$y, n$y)),
                 default.units = "native", gp = gpar(col = pal$accent, lwd = 2.2))
    # Text/value colour reverses to `paper` only when the box itself was
    # actually fill-reversed above -- otherwise a "lead" box in the journal
    # theme (white fill, not reversed) would render white-on-white and vanish.
    txt <- if (lead_reversed) pal$paper else pal$muted
    val <- if (lead_reversed) pal$paper else pal$ink
    fam <- if (is.null(pal$font)) NULL else pal$font
    lx <- n$x + 13; y_cursor <- n$y + 17
    # Each field drawn one PHYSICAL line at a time at an explicit y, rather
    # than handing grid.text a "\n"-embedded string and trusting its default
    # vertical centring to land where this layout already reserved space for
    # it -- that mismatch (vjust = "centre" for a left-just string) is what
    # let a two-line sub print on top of the value line above it.
    .draw_lines <- function(txt_field, colour, size, family) {
      if (is.na(txt_field)) return(invisible())
      for (ln in strsplit(txt_field, "\n", fixed = TRUE)[[1]]) {
        grid.text(ln, x = lx, y = ty(y_cursor), just = "left",
                  default.units = "native",
                  gp = gpar(col = colour, fontsize = size, fontfamily = family))
        y_cursor <<- y_cursor + FD_LINE_GAP
      }
    }
    .draw_lines(n$label, txt, 12, fam)
    .draw_lines(n$value, val, 12, if (is.null(pal$font)) "mono" else pal$font)
    .draw_lines(n$sub,   txt, 12, fam)
  }
  popViewport()
}

#' Render to pdf, png and svg at one aspect ratio
#' @param theme [list] or NULL: passed through to `fd_render()`. See
#'   `fd_theme_default()` / `fd_theme_journal()`.
#' @param title [character] or NULL: caption drawn above the diagram
#'   (e.g. "The CONSORT Flowchart" in the classic template). NULL (default)
#'   reserves no extra space, so existing callers are unaffected.
#' @keywords internal
fd_write <- function(nodes, edges, base, width_in = 7.6, canvas_w = 1000,
                     canvas_h = NULL, extra = NULL, theme = NULL, title = NULL) {
  pad_top <- if (is.null(title)) 14 else 46
  lay <- fd_layout(nodes, canvas_w = canvas_w, pad_top = pad_top)
  if (is.null(canvas_h)) canvas_h <- max(lay$bottom) + 40
  h_in <- width_in * canvas_h / canvas_w
  pal <- if (is.null(theme)) fd_theme_default() else theme
  draw <- function() {
    fd_render(lay, edges, canvas_w, canvas_h, theme = theme)
    if (!is.null(title)) {
      # fd_render() has already popped its viewport by the time control
      # returns here, so the title needs its own viewport in the same
      # native (0, canvas_w) x (0, canvas_h) coordinate space -- drawing
      # directly at this point would land in the root viewport instead and
      # render in the wrong place (or off-canvas) at every device size.
      pushViewport(viewport(xscale = c(0, canvas_w), yscale = c(0, canvas_h)))
      grid.text(title, x = 12, y = canvas_h - 20, just = "left",
                default.units = "native",
                gp = gpar(col = pal$ink, fontsize = 12,
                          fontfamily = if (is.null(pal$font)) NULL else pal$font))
      popViewport()
    }
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
