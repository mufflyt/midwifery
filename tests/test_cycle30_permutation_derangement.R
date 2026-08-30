#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 30 (session-cycle 7 of 24) -- 4 BVA / 3 semantic / 3 adversarial
# =============================================================================
# Target: link_theses_to_amcb.R's permutation-based negative control (the
# false-positive-rate baseline reported per institution, e.g. "Frontier ran
# 9%, Seattle ran 38%"). A different validation/backtesting question than
# cycles 27/29's row-position sampling: does the permutation actually
# produce a clean null, or can it silently retain real signal? Zero prior
# tests existed for this control.
fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# The SHIPPED derange(), not a copy of it. A test that mirrors its target
# passes while the target regresses, so this sources the canonical file that
# link_theses_to_amcb.R also sources. The script itself is not sourceable
# here: it reads CSVs at top level, so the function was extracted instead.
root <- if (dir.exists("../.git") || file.exists("../.git")) ".." else "."
source(file.path(root, "R", "lib", "derangement.R"))

cat("\n-- BVA --\n")

chk(identical(derange(character(0)), character(0)),
    "T30-1: length-0 input returns character(0) immediately, no error")

chk(identical(derange("solo"), "solo"),
    "T30-2: length-1 input returns itself (a derangement is undefined for one element; must not hang)")

pathological <- c("John", "John")
res_path <- withCallingHandlers(
  derange(pathological, max_tries = 50L),
  warning = function(w) invokeRestart("muffleWarning")
)
chk(identical(sort(res_path), sort(pathological)) && length(res_path) == 2L,
    "T30-3: two identical values (mathematically impossible to derange) terminates within max_tries rather than hanging")

set.seed(1)
big <- paste0("name_", seq_len(500))
chk(!any(derange(big) == big),
    "T30-4: 500 distinct names achieve a true zero-fixed-point derangement (the realistic-scale case)")

cat("\n-- semantic --\n")

set.seed(2)
fp_plain <- replicate(3000, sum(sample(1:30) == 1:30))
chk(abs(mean(fp_plain) - 1) < 0.15,
    sprintf("T30-5: a plain sample() permutation has ~1 expected fixed point regardless of size (measured: %.2f over 3000 trials) -- the statistical property the fix exists to correct", mean(fp_plain)))

set.seed(3)
x_dup <- rep(c("A", "B", "C", "D", "E"), 4)  # realistic repeats, 20 rows
d <- derange(x_dup)
chk(identical(sort(d), sort(x_dup)),
    "T30-6: derange() returns a genuine permutation of the input multiset -- same names, same counts, no name silently dropped or duplicated")

set.seed(4)
institution_like <- c(paste0("first_", 1:15), sample(c("Mary", "John", "Sarah"), 10, replace = TRUE))
chk(!any(derange(institution_like) == institution_like),
    "T30-7: a realistic institutional cohort (some repeated first names, not a pathological all-identical case) achieves exactly zero fixed points, a clean null")

cat("\n-- adversarial --\n")

set.seed(5)
plain_has_fp <- replicate(500, any(sample(1:30) == 1:30))
chk(mean(plain_has_fp) > 0.5,
    sprintf("T30-8 (anti-ceremony): the RETIRED plain sample() has at least one fixed point more than half the time (measured: %.1f%%) -- confirms T30-5/T30-7 fix something real, not vacuous", 100 * mean(plain_has_fp)))

chk({
  triggered <- FALSE
  withCallingHandlers(
    derange(c("X", "X", "X"), max_tries = 20L),
    warning = function(w) { triggered <<- TRUE; invokeRestart("muffleWarning") }
  )
  triggered
}, "T30-9: an impossible derangement (dominant repeated value) raises a warning rather than silently returning contaminated output")

root <- if (basename(getwd()) == "tests") ".." else "."
src_lines_all <- readLines(file.path(root, "link_theses_to_amcb.R"), warn = FALSE)
src_lines <- src_lines_all[!grepl("^\\s*#", src_lines_all)]
src_txt <- paste(src_lines, collapse = "\n")
chk(!grepl("given_tokens\\s*=\\s*sample\\(given_tokens\\)", src_txt) &&
      grepl("derange\\(given_tokens\\)", src_txt),
    "T30-10: the bare sample(given_tokens) permutation no longer survives -- the control is built via derange(), not a plain shuffle")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
