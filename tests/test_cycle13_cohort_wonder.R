#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 13 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Two targets: the cohort set arithmetic in R/06-cohort-flow.R, and the
# row-span carry-down in wonder_parse().
#
# THE DISTINCTION THIS CYCLE IS ABOUT. R/06 asserted four things in one
# stopifnot():
#
#     length(added) == 2147                                    <- a data fact
#     length(removed) == 1352                                  <- a data fact
#     retained + added == final                                <- arithmetic
#     stage2 + added - removed == final                        <- arithmetic
#
# These are different kinds of claim and their failures mean opposite things.
# The identities hold for ANY three sets on ANY vintage; if one fails, the code
# is wrong. The counts hold because artifacts/frozen_stage2 and
# artifacts/frozen_cohort are the specific files this analysis was written
# against; if one fails, the data moved, which may be entirely legitimate.
#
# Conflated, both produced the same bare "length(added) == 2147 is not TRUE",
# and a reader could not tell a broken pipeline from a refrozen cohort. They are
# now separated, and this file tests the identities as PROPERTIES -- over random
# sets, not over the fixture -- which is the only way to show they are arithmetic
# rather than another pin.
#
# Run: Rscript tests/test_cycle13_cohort_wonder.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "wonder_natality.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
FLOW <- readLines(file.path(root, "R", "06-cohort-flow.R"), warn = FALSE)

# A WONDER-shaped XML fragment. Outer labels appear only on the first row of
# each group, exactly as the real service emits them.
wdoc <- function(rows) xml2::read_xml(paste0(
  "<page><data-table>",
  paste0(vapply(rows, function(r) paste0("<r>", r, "</r>"), character(1)),
         collapse = ""),
  "</data-table></page>"))
cell <- function(l = NULL, v = NULL) paste0(
  "<c", if (!is.null(l)) sprintf(' l="%s"', l) else "",
  if (!is.null(v)) sprintf(' v="%s"', v) else "", "/>")

cat("\n-- BVA --\n")

# T121 (BVA). No rows at all. An empty WONDER response is what a fully
# suppressed query returns, not an error condition.
{
  d <- wonder_parse(wdoc(character(0)), n_group = 2L)
  chk(is.data.frame(d) && nrow(d) == 0L,
      "T121 an empty data-table yields a zero-row frame, not an error")
}

# T122 (BVA). THE CARRY-DOWN EDGE. If the very FIRST row lacks outer labels
# there is nothing to carry down from, so the carried vector is still NA. The
# result must not silently present NA as a group value that later joins on.
{
  d <- wonder_parse(wdoc(c(paste0(cell(l = "2020"), cell(v = "100")))), n_group = 2L)
  chk(nrow(d) == 1L, "T122a a single row parses")
  chk(is.na(d$group1[1]),
      sprintf("T122b a missing OUTER label on the first row stays NA, never fabricated [%s]",
              d$group1[1]))
}

# T123 (BVA). A row carrying MORE labels than n_group. The carry-down indexes
# `carried[seq(n_group - k + 1L, n_group)]`, which is out of range when k
# exceeds n_group.
{
  d <- tryCatch(
    wonder_parse(wdoc(c(paste0(cell(l = "CT"), cell(l = "2020"), cell(l = "CNM"),
                               cell(v = "42")))), n_group = 2L),
    error = function(e) "error")
  chk(!identical(d, "error"),
      "T123a more labels than group-by variables does not abort the parse")
  if (!identical(d, "error")) {
    chk(ncol(d) >= 2L && !is.na(d$group1[1]),
        "T123b the outer group is still populated when extra labels appear")
  }
}

# T124 (BVA). Cohort set arithmetic at degenerate sizes.
{
  ident <- function(s2, fin) {
    added <- setdiff(fin, s2); removed <- setdiff(s2, fin)
    retained <- intersect(s2, fin)
    length(retained) + length(added) == length(fin) &&
      length(s2) + length(added) - length(removed) == length(fin)
  }
  chk(ident(character(0), character(0)), "T124a two empty cohorts satisfy the identity")
  chk(ident(character(0), "a"), "T124b an empty stage-2 with one final person holds")
  chk(ident("a", character(0)), "T124c a fully emptied cohort holds")
  chk(ident(c("a", "b"), c("a", "b")), "T124d an unchanged cohort holds")
}

cat("\n-- SEMANTIC --\n")

# T125 (semantic). The identities are ARITHMETIC, not pins. Demonstrated over
# 200 random set pairs -- if they only held for the fixture they would not be
# invariants at all.
{
  set.seed(20260810)   # fixed: a property test must be reproducible
  ok <- TRUE
  for (i in seq_len(200)) {
    universe <- sprintf("C%03d", 1:40)
    s2 <- sample(universe, sample(0:40, 1))
    fin <- sample(universe, sample(0:40, 1))
    added <- setdiff(fin, s2); removed <- setdiff(s2, fin)
    retained <- intersect(s2, fin)
    ok <- ok &&
      length(retained) + length(added) == length(fin) &&
      length(s2) + length(added) - length(removed) == length(fin)
  }
  chk(ok, "T125 both identities hold over 200 random cohort pairs, so they are invariants")
}

# T126 (semantic). Invariants and provenance pins must be distinguishable in
# the source. A failure has to say whether the code broke or the data moved.
{
  src <- paste(FLOW, collapse = "\n")
  chk(grepl("PIN_ADDED", src) && grepl("PROVENANCE", src),
      "T126a the pinned counts are named and labelled as provenance")
  # The pins must NOT sit inside the same stopifnot() as the identities.
  block <- sub(".*# --- Invariants.*?stopifnot\\((.*?)\\).*", "\\1", src)
  chk(!grepl("2147|1352", block),
      "T126b no data-dependent count sits inside the invariant assertion")
}

# T127 (semantic). added / removed / retained must PARTITION: pairwise
# disjoint, and together accounting for every person on either side.
{
  s2 <- c("a", "b", "c"); fin <- c("b", "c", "d")
  added <- setdiff(fin, s2); removed <- setdiff(s2, fin); retained <- intersect(s2, fin)
  chk(length(intersect(added, removed)) == 0L &&
        length(intersect(added, retained)) == 0L &&
        length(intersect(removed, retained)) == 0L,
      "T127a the three groups are pairwise disjoint")
  chk(setequal(union(union(added, removed), retained), union(s2, fin)),
      "T127b together they account for everyone on either side")
}

cat("\n-- ADVERSARIAL --\n")

# T128 (adversarial). THE TRAP. setdiff() and intersect() return UNIQUE values,
# but length(fin_cohort) counts ROWS. A duplicated certification_number in the
# cohort file therefore breaks the identity -- and the identity is what proves
# the accounting sound.
{
  s2 <- c("a", "b")
  fin_dup <- c("a", "b", "b")             # one person listed twice
  added <- setdiff(fin_dup, s2); removed <- setdiff(s2, fin_dup)
  retained <- intersect(s2, fin_dup)
  holds <- length(retained) + length(added) == length(fin_dup)
  chk(!holds,
      "T128a a duplicated id breaks the row-count identity, so it cannot pass unnoticed")
  chk(length(retained) + length(added) == length(unique(fin_dup)),
      "T128b the identity is about PEOPLE, so it holds against the unique count")
}

# T129 (adversarial). Ragged rows: WONDER cells vary in count between rows.
# Short rows must be padded, never recycled into a neighbour's value.
{
  d <- wonder_parse(wdoc(c(
    paste0(cell(l = "CT"), cell(l = "2020"), cell(v = "10"), cell(v = "20")),
    paste0(cell(l = "2021"), cell(v = "30")))), n_group = 2L)
  chk(nrow(d) == 2L, "T129a ragged rows both parse")
  chk(is.na(d$value2[2]),
      sprintf("T129b a short row is padded with NA, not filled from its neighbour [%s]",
              d$value2[2]))
  chk(identical(d$group1[2], "CT"),
      "T129c the outer label carries down to the continuation row")
}

# T130 (adversarial). The stage-2 cohort is defined by !is.na(npi). An empty
# string is not NA, so a blank NPI would silently enter the matched cohort.
{
  npi <- c("1234567890", NA, "", "   ")
  naive <- sum(!is.na(npi))
  strict <- sum(!is.na(npi) & nzchar(trimws(npi)))
  chk(naive == 3L && strict == 1L,
      sprintf("T130 blank and whitespace NPIs pass an is.na() test [%d vs %d truly matched]",
              naive, strict))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
