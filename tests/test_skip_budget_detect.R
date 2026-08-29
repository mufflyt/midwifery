#!/usr/bin/env Rscript
# =============================================================================
# Does the skip budget refuse a new skip, and a stale one?
# =============================================================================
# The third state is the one budgets usually lack. A budget that only catches
# NEW skips accumulates entries whose reasons expired years ago, and reading it
# tells you what used to be unchecked rather than what is. So a disappeared skip
# fails here too, and the fixture proves it.
#
# Synthetic gates rather than the real ones: the real counts differ between a
# bare checkout and a machine that has run the pipeline, which is a property
# worth having and a terrible thing to build a fixture on.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
CHECKER <- file.path(root, "tests", "ci_skip_budget.R")
stopifnot(file.exists(CHECKER))

pass <- 0L; failed <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) { pass <<- pass + 1L; cat(sprintf("  ok   %s\n", m)) }
  else { failed <<- c(failed, m); cat(sprintf("  FAIL %s\n", m)) } }

#' A scratch repo whose only gate emits `n` skips, budgeted at `expect`
#'
#' sb_ prefixed throughout: ci_hygiene H4 forbids a top-level function defined
#' in two tracked files, and run_in() is already taken by
#' tests/test_manuscript_numbers_detect.R.
#' @keywords internal
#' @noRd
sb_scaffold <- function(n_skips, expect) {
  d <- file.path(tempdir(), paste0("sb_", as.integer(stats::runif(1) * 1e9)))
  dir.create(file.path(d, "tests"), recursive = TRUE, showWarnings = FALSE)
  for (f in c("ci_report.R", "lib_manuscript_numbers.R", "ci_skip_budget.R"))
    file.copy(file.path(root, "tests", f), file.path(d, "tests", f))
  writeLines(c(
    "source(file.path('tests','ci_report.R'))",
    if (n_skips > 0) sprintf("ci_skip('synthetic skip %d')", seq_len(n_skips)) else character(0),
    "ci_ok('did something')", "ci_finish()"),
    file.path(d, "tests", "ci_fake_gate.R"))
  writeLines(c("gate\twhen\tfull\tlean\treason",
               sprintf("tests/ci_fake_gate.R\tpr\t%d\t%d\ta synthetic gate", expect, expect)),
             file.path(d, "tests", "skip_budget.tsv"))
  # git ls-files drives SB1's completeness scan, so the scratch repo needs to be
  # one. Without this the scan sees no gates and the budget passes vacuously --
  # which is the failure mode, not the test.
  system2("git", c("-C", shQuote(d), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
  d
}

sb_run_in <- function(dir) {
  wd <- getwd(); on.exit(setwd(wd), add = TRUE); setwd(dir)
  out <- tempfile()
  code <- suppressWarnings(system2("Rscript", c(file.path("tests", "ci_skip_budget.R")),
                                   stdout = out, stderr = out))
  txt <- paste(readLines(out, warn = FALSE), collapse = "\n")
  unlink(out)
  list(code = code, text = txt)
}

cat("\n-- the three states --\n")

r <- sb_run_in(sb_scaffold(2, 2))
chk(r$code == 0 && grepl("Unexpected skips:      0", r$text, fixed = TRUE),
    "observed == expected passes")

r <- sb_run_in(sb_scaffold(3, 2))
chk(r$code != 0 && grepl("skipped more than the budget allows", r$text, fixed = TRUE) &&
      grepl("Unexpected skips:      1", r$text, fixed = TRUE),
    "a NEW skip fails, and is reported as unexpected rather than as an error")

r <- sb_run_in(sb_scaffold(0, 2))
chk(r$code != 0 && grepl("stale budget entry", r$text, fixed = TRUE) &&
      grepl("Stale expected skips:  1", r$text, fixed = TRUE),
    "an expected skip that DISAPPEARED fails, so the budget cannot become a graveyard")

cat("\n-- completeness --\n")

# NON-EMPTY but missing the gate: an empty budget short-circuits at SB0 and
# never reaches SB1, so the first version of this fixture proved the wrong
# property. A nightly placeholder keeps the budget populated without SB2 trying
# to run it.
d <- sb_scaffold(1, 1)
writeLines(c("gate\twhen\tfull\tlean\treason",
             "tests/ci_report.R\tnightly\t-\t-\tplaceholder, not run in this tier"),
           file.path(d, "tests", "skip_budget.tsv"))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("not in the budget", r$text, fixed = TRUE),
    "a gate that can skip but is undeclared fails")

d <- sb_scaffold(1, 1)
writeLines(c("gate\twhen\tfull\tlean\treason",
             "tests/ci_fake_gate.R\tpr\t1\t1\ta synthetic gate",
             "tests/ci_gate_that_never_existed.R\tpr\t0\t0\tnothing"),
           file.path(d, "tests", "skip_budget.tsv"))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("do not exist", r$text, fixed = TRUE),
    "a budget naming a gate that does not exist fails")

d <- sb_scaffold(1, 1)
writeLines("gate\twhen\tfull\tlean\treason", file.path(d, "tests", "skip_budget.tsv"))
invisible(file.remove(file.path(d, "tests", "ci_fake_gate.R")))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("SB0|empty or absent", r$text),
    "an empty budget refuses rather than passing vacuously")

cat(sprintf("\n%d passed, %d failed\n", pass, length(failed)))
if (length(failed)) { for (f in failed) cat(sprintf("  - %s\n", f)); quit(status = 1) }
cat("PASS (0 failures)\n")
