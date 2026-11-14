#!/usr/bin/env Rscript
# =============================================================================
# Does the nightly registry check detect an exception that should not exist?
# =============================================================================
# ci_nightly_registry_check.R's N5 refuses an exception whose stated reason it
# cannot find. A detector proves the refusal is real: the same discipline
# test_skip_budget_detect.R and test_science_contracts_detect.R apply to their
# gates.
#
# WHY N5 NEEDS ONE MORE THAN THE OTHER SECTIONS. N5 passed vacuously on its
# first run. It read e$file where parse_entry() provides e$path; sprintf() on a
# NULL returns character(0) instead of erroring, so every append was a silent
# no-op and the section reported "all 0 exception(s) still reach the dependency
# they claim" -- a green tick over nothing examined. The accounting guard now
# refuses that, and T3 below is the case that would have caught it.
#
# THE REGISTRY IS RESTORED VIA on.exit(), which covers a normal exit, a failed
# assertion and an R-level error. A hard kill is beyond its reach, so the file
# it touches is deliberately a small tracked one: a `git diff` shows immediately
# if a killed run left it modified. A detector that silently leaves the
# repository changed is worse than no detector.
#
# No race with the nightly: it reads the registry once into /tmp/exceptions.txt
# before its sequential test loop, and ci_nightly_registry_check.R runs in a
# different step.
#
# Run: Rscript tests/test_nightly_registry_detect.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
GATE <- file.path(root, "tests", "ci_nightly_registry_check.R")
REG  <- file.path(root, "tests", "ci_nightly_exceptions.txt")
ORIGINAL <- readLines(REG, warn = FALSE)
on.exit(writeLines(ORIGINAL, REG), add = TRUE)

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# NAMED FOR THIS GATE, not `run_gate`. H4 refuses one function defined at top
# level in two files, and tests/test_aggregate_gate.R already has a run_gate()
# that does something else entirely (it sets NEEDS_JSON/REQUIRED for the
# aggregate gate). The first version of this file called it run_gate and H4
# caught it -- which it could only do once the file was TRACKED, so running the
# hygiene gate on an untracked new file proves nothing.
run_registry_gate <- function() {
  out <- suppressWarnings(system2("Rscript", shQuote(GATE), stdout = TRUE, stderr = TRUE))
  list(txt = paste(out, collapse = "\n"),
       failed = any(grepl("^FAILED", out)))
}

# A test with no external dependency of any kind, used as the bogus subject.
INNOCENT <- "tests/test_safe_divide_types.R"
stopifnot(file.exists(file.path(root, INNOCENT)))

cat("\n-- the registry as committed --\n")
base <- run_registry_gate()
chk(!base$failed, "T1 the committed registry passes")
chk(grepl("all 8 exception\\(s\\) still reach|all [0-9]+ exception\\(s\\) still reach", base$txt),
    "T2 ...and N5 reports a non-zero number of exceptions examined")

# The vacuous-pass shape, stated as a property rather than by breaking the gate:
# N5 must account for every declared entry, so the number it reports examined
# cannot be zero while entries exist.
n_declared <- length(Filter(function(l) nzchar(trimws(l)) && !startsWith(trimws(l), "#"),
                            ORIGINAL))
examined <- suppressWarnings(as.integer(
  sub(".*all ([0-9]+) exception\\(s\\) still reach.*", "\\1",
      grep("still reach", strsplit(base$txt, "\n")[[1]], value = TRUE)[1])))
chk(!is.na(examined) && examined == n_declared,
    sprintf("T3 N5 examined every declared exception [%s of %d]",
            if (is.na(examined)) "NA" else examined, n_declared))

cat("\n-- a stale exception is detected, in both classes --\n")
for (cls in c("external-private", "external-network")) {
  writeLines(c(ORIGINAL, paste(INNOCENT, cls, "# planted by the detector", sep = "\t")), REG)
  r <- run_registry_gate()
  chk(r$failed && grepl("N5:", r$txt),
      sprintf("T4 an exception claiming %s for a test with no such dependency fails", cls))
  writeLines(ORIGINAL, REG)
}

cat("\n-- and the detector left the registry as it found it --\n")
chk(identical(readLines(REG, warn = FALSE), ORIGINAL),
    "T5 the committed registry is restored")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
