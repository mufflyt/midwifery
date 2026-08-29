#!/usr/bin/env Rscript
# =============================================================================
# A published result may be generated or it may be typed, and not both
# =============================================================================
# Three linkage figures were once in circulation across this repository -- 82.3%,
# 78.0% and 78.4% for one quantity -- because each was typed into a paragraph on
# the day it was computed and then outlived its own artifact. The stats catalog
# was built to end that, and it did, for the numbers that were moved into it.
# Nothing stopped the next one being typed.
#
# The rurality result then did it again in a subtler way: 86.5% in the
# manuscript, 89.34% implied by the composition artifact, 89.8% anchoring the
# selection bounds. Scientific law L12 now forbids the artifacts from
# disagreeing with each other. This is the manuscript-side half of the same
# claim -- that the prose agrees with the artifacts, and reaches them by
# reference rather than by transcription.
#
# WHAT THIS IS NOT. It is not a rule against digits in prose. Years, citation
# keys, RUCC bands, section numbers, a 95% confidence level, a 60% land-share
# threshold and a SHA-256 are all legitimate, and a checker that is wrong about
# most of a paper gets an exemption written for it and then protects nothing.
# The scope is manuscript/protected_results.tsv and nothing else.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "tests", "lib_manuscript_numbers.R"))
suppressPackageStartupMessages({
  source(file.path(root, "manuscript", "R", "build_stats_catalog.R"))
})

REG_PATH <- file.path(root, "manuscript", "protected_results.tsv")
ALLOW_PATH <- file.path(root, "manuscript", "allowed_literals.tsv")

reg <- mn_read_tsv(REG_PATH)
allow <- mn_read_tsv(ALLOW_PATH)
qmds <- list.files(file.path(root, "manuscript"), pattern = "[.]qmd$", full.names = TRUE)

if (is.null(reg) || !nrow(reg)) {
  ci_fail("P0: manuscript/protected_results.tsv is empty or absent. A registry\n       that protects nothing reports success, which is the defect, not the fix.")
  ci_finish()
}
if (!length(qmds)) {
  ci_fail("P0: no manuscript/*.qmd found. The scan would pass having read nothing.")
  ci_finish()
}

K <- mw_build_catalog(root)
prose <- lapply(qmds, function(q) mn_prose_lines(readLines(q, warn = FALSE)))
raw   <- lapply(qmds, function(q) readLines(q, warn = FALSE))
names(prose) <- names(raw) <- basename(qmds)
used <- unique(unlist(lapply(raw, mn_keys_used)))

allowed <- function(file, lit) {
  if (is.null(allow) || !nrow(allow)) return(FALSE)
  any((allow$file == file | allow$file == "*") & allow$literal == lit)
}

# --- P1 a protected result may not appear as a literal -----------------------
ci_section("P1 no protected result is typed into prose")
n_scanned <- 0L; typed <- character(0)
for (i in seq_len(nrow(reg))) {
  v <- mn_get(K, reg$key[i])
  if (is.null(v)) next
  lits <- mn_render(suppressWarnings(as.numeric(v[1])), reg$fmt[i])
  if (!length(lits)) next
  n_scanned <- n_scanned + 1L
  for (f in names(prose)) for (lit in lits) {
    if (allowed(f, lit)) next
    hit <- mn_find_literal(prose[[f]], lit)
    for (h in hit)
      typed <- c(typed, sprintf("%s:%d types %s, which is %s\n              %s",
                                f, h, lit, reg$key[i],
                                substr(trimws(prose[[f]][h]), 1, 72)))
  }
}
# NON-VACUITY. A registry whose keys have all been renamed out of the catalog
# would scan nothing and pass. That is the failure this file exists to prevent,
# one level up.
if (n_scanned < nrow(reg) / 2)
  ci_fail("P1: only %d of %d registered quantities resolved in the catalog. The\n       registry has drifted from the catalog and is protecting almost nothing.",
          n_scanned, nrow(reg))
if (length(typed)) {
  ci_fail("P1: %d protected result(s) typed into prose:\n%s\n       Replace with the catalog reference. If the occurrence is legitimate,\n       add it to manuscript/allowed_literals.tsv WITH A REASON.",
          length(typed), paste(sprintf("       - %s", typed), collapse = "\n"))
} else {
  ci_ok("%d protected quantities scanned across %d manuscript file(s); none typed",
        n_scanned, length(qmds))
}

# --- P2 a protected result must actually be reached for -----------------------
ci_section("P2 every protected result is generated somewhere")
unref <- setdiff(reg$key, used)
if (length(unref)) {
  ci_fail("P2: registered but never referenced: %s.\n       Either the manuscript stopped reporting it -- in which case remove it\n       from the registry -- or it is being reported some other way.",
          paste(unref, collapse = ", "))
} else {
  ci_ok("all %d registered quantities are reached by a catalog reference", nrow(reg))
}

# --- P3 every generated value is traceable ------------------------------------
ci_section("P3 every manuscript reference resolves to a real catalog value")
bad <- used[vapply(used, function(k) {
  v <- mn_get(K, k); is.null(v) || all(is.na(v))
}, logical(1))]
if (length(bad)) {
  ci_fail("P3: %d manuscript reference(s) resolve to nothing: %s.\n       The prose would render a placeholder, or the render would abort.",
          length(bad), paste(bad, collapse = ", "))
} else {
  ci_ok("all %d catalog reference(s) in the manuscript resolve", length(used))
}

# --- P4 one estimand, one value ----------------------------------------------
ci_section("P4 two representations of one quantity agree")
pairs <- reg[nzchar(reg$equals), , drop = FALSE]
off <- character(0)
for (i in seq_len(nrow(pairs))) {
  a <- suppressWarnings(as.numeric(mn_get(K, pairs$key[i])[1]))
  b <- suppressWarnings(as.numeric(mn_get(K, pairs$equals[i])[1]))
  if (!length(b) || is.na(b)) {
    off <- c(off, sprintf("%s declares equals=%s, which does not resolve",
                          pairs$key[i], pairs$equals[i]))
  } else if (!is.na(a) && abs(a - b) > 1e-6) {
    off <- c(off, sprintf("%s = %.6f but %s = %.6f", pairs$key[i], a, pairs$equals[i], b))
  }
}
if (length(off)) {
  ci_fail("P4: %d disagreement(s) between representations of one quantity:\n%s",
          length(off), paste(sprintf("       - %s", off), collapse = "\n"))
} else if (nrow(pairs)) {
  ci_ok("%d declared equality/equalities hold", nrow(pairs))
} else {
  ci_ok("no equalities declared")
}

ci_finish()
