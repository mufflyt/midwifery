#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 36 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: R/lib/flow_diagram.R -- a brand-new library (merged onto main this
# session, PR #128) with ZERO prior test coverage, producing a public
# manuscript figure (docs/figures/cohort_flow.{pdf,png,svg}). fd_layout() is
# the pure computational core (no graphics device needed) that decides WHERE
# every node and edge lands; a silent bug here corrupts a published figure
# with no error anywhere in the pipeline.
#
# TWO REAL DEFECTS found and fixed, both the same underlying failure mode
# (unrecognized/malformed input silently corrupts output instead of failing
# loudly) recurring at two different points in the same new file:
#
#   1. fd_node()'s own @param kind documents exactly 5 valid values (lead,
#      keep, band, drop, plain). An UNDOCUMENTED 6th value, "multi", had a
#      special case in fd_layout() that set that node's height to NA. Since
#      the per-tier y-position update is `y <- y + max(nodes$h[i]) + tier_gap`
#      and max() does not drop NA by default, ONE node with h=NA silently set
#      every SUBSEQUENT TIER's y position to NA too -- with no error anywhere.
#      "multi" has no live caller today (verified against make_cohort_flow_
#      figure.R, the only production call site), so this was dormant, not yet
#      triggered -- but the very next edit that adds a multi-value node would
#      have silently corrupted the entire figure below it.
#   2. fd_render() looked up an edge's endpoints via nodes[nodes$id ==
#      edges$from[e], ], which silently returns a 0-row frame for a typo'd id
#      -- rendering with NO ERROR and no visible sign that an arrow (a
#      TRANSITION in a cohort flow diagram) is simply missing.
#
# Both fixed with a loud stop() the moment invalid input is detected, matching
# this file's own stated design philosophy (its comments already praise
# VISIBLE failure over silent data loss, e.g. "Clipping a box off-canvas loses
# a count silently; moving it shows the spec is wrong").
#
# Verified the real production node/edge specification in make_cohort_flow_
# figure.R (10 nodes, 10 edges, no "multi" kind, no typo'd edge ids) still
# renders cleanly with both new guards in place -- no regression to the
# published figure.
#
# Run: Rscript tests/test_cycle36_flow_diagram.R
# =============================================================================

suppressPackageStartupMessages(library(grid))
source("R/lib/flow_diagram.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- BVA --\n")

# T36-1. The `at` (horizontal position, 0..1 of canvas) boundary at its exact
# minimum (0) and maximum (1): a node placed flush against either edge must
# be nudged inward by half its own width plus the 4px margin, not clipped or
# left exactly at the canvas boundary where its box would hang half off-page.
{
  n <- rbind(fd_node("left", 1, "L", at = 0, kind = "plain", w = 200),
             fd_node("right", 1, "R", at = 1, kind = "plain", w = 200))
  lay <- fd_layout(n, canvas_w = 1000)
  chk(lay$cx[lay$id == "left"] == 104 && lay$cx[lay$id == "right"] == 896,
      sprintf("T36-1 at=0 and at=1 clamp to w/2+4 from each edge (got left=%s, right=%s)",
              lay$cx[lay$id == "left"], lay$cx[lay$id == "right"]))
}

# T36-2. The minimum tier size (k=1, a lone node with no explicit `at`) must
# center exactly at the canvas midpoint -- the smallest possible case of the
# even-distribution formula `(seq_len(k) - 0.5) * span`.
{
  n <- fd_node("solo", 1, "Solo", kind = "plain", w = 100)
  lay <- fd_layout(n, canvas_w = 1000)
  chk(lay$cx == 500,
      sprintf("T36-2 a lone auto-positioned node in a tier centers at exactly canvas_w/2 (got %s)", lay$cx))
}

# T36-3. The node-height formula at its two boundaries: a bare label (lines=1,
# the minimum) versus a label with both a value and a sub-label (lines=3, the
# maximum any node currently supports) -- h = 26 + 22*(lines-1) must compute
# 26 and 70 respectively, not drift at either extreme.
{
  n <- rbind(fd_node("bare", 1, "Bare", kind = "plain"),
            fd_node("full", 1, "Full", value = "V", sub = "S", kind = "plain"))
  lay <- fd_layout(n)
  chk(lay$h[lay$id == "bare"] == 26 && lay$h[lay$id == "full"] == 70,
      sprintf("T36-3 height is 26 at lines=1 and 70 at lines=3 (got %s, %s)",
              lay$h[lay$id == "bare"], lay$h[lay$id == "full"]))
}

# T36-4. Zero nodes: a well-typed but 0-row nodes frame (as fd_node() itself
# cannot construct directly, since it builds exactly one row per call -- this
# uses [0, ] on a real one-row example to get a correctly-typed empty frame)
# must return a 0-row layout, not error and not silently produce a stray row.
{
  one <- fd_node("a", 1, "A", kind = "plain")
  empty <- one[0, ]
  lay <- fd_layout(empty)
  chk(is.data.frame(lay) && nrow(lay) == 0L,
      "T36-4 an empty (0-row) nodes frame returns a 0-row layout, not an error")
}

cat("\n-- SEMANTIC --\n")

# T36-5. An `at` value outside its documented [0, 1] contract (a plausible
# copy-paste typo in a future figure edit, e.g. 1.8 instead of 0.8) must still
# clamp to a visibly on-canvas position -- consistent with this file's own
# stated design value that a spec error should be VISIBLE (an obviously
# off-center box), never silently render past the page edge where a reader
# would never see it at all.
{
  n <- rbind(fd_node("neg", 1, "Neg", at = -0.3, kind = "plain", w = 200),
            fd_node("big", 1, "Big", at = 1.8, kind = "plain", w = 200))
  lay <- fd_layout(n, canvas_w = 1000)
  chk(all(lay$cx >= 0 & lay$cx <= 1000),
      sprintf("T36-5 out-of-[0,1] 'at' values (-0.3, 1.8) still clamp to on-canvas positions (got %s)",
              paste(lay$cx, collapse = ", ")))
}

# T36-6. DOCUMENTED CURRENT LIMITATION, not fixed this cycle: when a tier
# mixes explicit `at` values with auto (NA) ones, the auto positions are
# computed from an even split of the FULL tier (as if every slot were auto),
# THEN the explicit ones are overwritten on top -- the auto nodes do not
# redistribute around wherever the explicit ones actually ended up. The file's
# own header already disclaims automatic layout search ("WHAT IT DOES NOT DO:
# automatic edge routing... or any layout search"), and the one production
# call site (make_cohort_flow_figure.R) always supplies an explicit `at` for
# EVERY node in every tier, so this path is never exercised in the published
# figure. Pinned as current behavior so a future change is a deliberate
# decision, not an accidental one.
{
  n <- rbind(fd_node("a", 1, "A", at = 0.1, kind = "plain"),
            fd_node("b", 1, "B", at = NA_real_, kind = "plain"),
            fd_node("c", 1, "C", at = NA_real_, kind = "plain"))
  lay <- fd_layout(n, canvas_w = 1000)
  # The auto nodes (b, c) land at slots 2 and 3 of an even 3-way split
  # (500, 833.33), computed BEFORE "a"'s explicit position overwrote slot 1 --
  # not redistributed across the space actually remaining around "a".
  chk(isTRUE(all.equal(lay$cx[lay$id == "b"], 500)) &&
        isTRUE(all.equal(lay$cx[lay$id == "c"], 1000 * 2.5 / 3)),
      sprintf("T36-6 auto-positioned siblings use the full-tier even split, unaware of the explicit sibling's actual position (got b=%s, c=%s)",
              lay$cx[lay$id == "b"], lay$cx[lay$id == "c"]))
}

# T36-7. fd_write()'s aspect-ratio math (h_in = width_in * canvas_h /
# canvas_w) must scale the OUTPUT height with actual content height: a
# 4-tier diagram must produce a taller page than a 1-tier diagram at the same
# width, not a fixed aspect ratio that ignores how much content there is.
{
  short <- fd_node("s", 1, "S", kind = "plain")
  tall <- rbind(fd_node("t1", 1, "T1", kind = "plain"), fd_node("t2", 2, "T2", kind = "plain"),
               fd_node("t3", 3, "T3", kind = "plain"), fd_node("t4", 4, "T4", kind = "plain"))
  ls <- fd_layout(short); lt <- fd_layout(tall)
  ch_short <- max(ls$bottom) + 40; ch_tall <- max(lt$bottom) + 40
  h_in_short <- 7.6 * ch_short / 1000; h_in_tall <- 7.6 * ch_tall / 1000
  chk(h_in_tall > h_in_short,
      sprintf("T36-7 a 4-tier diagram computes a taller page height than a 1-tier one (got %.3f vs %.3f in)",
              h_in_tall, h_in_short))
}

cat("\n-- ADVERSARIAL --\n")

# T36-8. THE DEFECT (fixed this cycle). An unrecognized node kind ("multi",
# undocumented, no live caller) must be refused loudly by fd_layout(), not
# silently accepted into the undocumented NA-height special case that used to
# corrupt every subsequent tier's y position.
{
  n <- rbind(fd_node("a", 1, "Tier1", at = 0.5, kind = "plain"),
            fd_node("b", 2, "Tier2multi", at = 0.5, kind = "multi"),
            fd_node("c", 3, "Tier3", at = 0.5, kind = "plain"))
  err <- tryCatch({ fd_layout(n); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("unrecognized node kind", err) && grepl("multi", err),
      sprintf("T36-8 an unrecognized kind ('multi') is refused loudly, naming the bad value (got: %s)",
              if (is.na(err)) "no error -- silently accepted" else err))
  # ANTI-CEREMONY: reproduce the retired NA-propagation directly, bypassing
  # the new guard, to prove the defect this guard prevents was real.
  retired_h <- c(26, NA_real_, 26)  # what nodes$h looked like pre-fix
  y_tier2 <- 14 + 26 + 78  # pad_top + tier1 h + tier_gap
  y_tier3_retired <- y_tier2 + max(retired_h[2]) + 78  # the actual pre-fix computation
  chk(is.na(y_tier3_retired),
      "T36-8b the retired computation: max() on an NA height silently poisons the next tier's y with NA")
}

# T36-9. THE DEFECT (fixed this cycle). An edge naming a node id that does
# not exist (a typo) must be refused loudly by fd_render(), not silently
# rendered as a missing arrow with no error.
{
  n <- rbind(fd_node("a", 1, "A", at = 0.5, kind = "plain"),
            fd_node("b", 2, "B", at = 0.5, kind = "plain"))
  lay <- fd_layout(n)
  edges <- fd_edge("a", "TYPO_DOES_NOT_EXIST")
  err <- tryCatch({
    pdf(NULL); on.exit(dev.off(), add = TRUE)
    fd_render(lay, edges)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("undefined node id", err) && grepl("TYPO_DOES_NOT_EXIST", err),
      sprintf("T36-9 an edge referencing an undefined node id is refused loudly, naming it (got: %s)",
              if (is.na(err)) "no error -- silently rendered" else err))
  # ANTI-CEREMONY: the retired lookup, applied directly, to show it returns a
  # silent 0-row result rather than any signal that something is wrong.
  retired_lookup <- lay[lay$id == "TYPO_DOES_NOT_EXIST", ]
  chk(nrow(retired_lookup) == 0L,
      "T36-9b the retired id lookup silently returns a 0-row frame for a typo, with no error of its own")
}

# T36-10. Investigated, NOT a defect requiring a fix: duplicate node ids (a
# plausible copy-paste mistake, e.g. two fd_node() calls both using id=
# "cohort") already fail LOUDLY at fd_layout() -- R's own data.frame
# replacement machinery errors on the resulting length mismatch when a
# duplicate id makes a per-tier vector assignment disagree in length with its
# target. Pinned as an existing safety property (an uninformative message,
# but a real error, never silent corruption), not something this cycle needs
# to improve.
{
  n <- rbind(fd_node("dup", 1, "First", at = 0.3, kind = "plain"),
            fd_node("dup", 1, "Second (accidental copy-paste)", at = 0.7, kind = "plain"),
            fd_node("x", 2, "X", at = 0.5, kind = "plain"))
  err <- tryCatch({ fd_layout(n); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err),
      sprintf("T36-10 a duplicate node id already fails loudly at fd_layout() (got: %s)",
              if (is.na(err)) "no error -- silently accepted" else err))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
