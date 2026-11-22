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
#' `expect` is the `full` count and `lean` defaults to it, so a caller that
#' does not care about the environment axis cannot accidentally depend on which
#' column was read. A caller testing the axis sets them APART, which is the only
#' way to prove which one the gate chose.
#'
#' sb_ prefixed throughout: ci_hygiene H4 forbids a top-level function defined
#' in two tracked files, and run_in() is already taken by
#' tests/test_manuscript_numbers_detect.R.
#' @keywords internal
#' @noRd
sb_scaffold <- function(n_skips, expect, lean = expect, needs = "", full_env = FALSE) {
  d <- file.path(tempdir(), paste0("sb_", as.integer(stats::runif(1) * 1e9)))
  dir.create(file.path(d, "tests"), recursive = TRUE, showWarnings = FALSE)
  for (f in c("ci_report.R", "lib_manuscript_numbers.R", "ci_skip_budget.R"))
    file.copy(file.path(root, "tests", f), file.path(d, "tests", f))
  writeLines(c(
    "source(file.path('tests','ci_report.R'))",
    if (n_skips > 0) sprintf("ci_skip('synthetic skip %d')", seq_len(n_skips)) else character(0),
    "ci_ok('did something')", "ci_finish()"),
    file.path(d, "tests", "ci_fake_gate.R"))
  writeLines(c("gate\tkind\twhen\tfull\tlean\treason\tneeds",
               sprintf("tests/ci_fake_gate.R\tci_skip\tpr\t%d\t%d\ta synthetic gate\t%s",
                       expect, lean, needs)),
             file.path(d, "tests", "skip_budget.tsv"))
  # git ls-files drives SB1's completeness scan, so the scratch repo needs to be
  # one. Without this the scan sees no gates and the budget passes vacuously --
  # which is the failure mode, not the test.
  # `full` IS INFERRED FROM ONE FILE'S PRESENCE, so a scaffold can claim it with
  # one line. Needed to prove the per-row axis OVERRIDES the global flag: in a
  # `lean` scaffold a row that selects `lean` for itself is indistinguishable
  # from a row that inherited it, and the case would pass with the override
  # removed (it did, until this existed).
  if (full_env) {
    dir.create(file.path(d, "artifacts"), recursive = TRUE, showWarnings = FALSE)
    writeLines("npi", file.path(d, "artifacts", "amcb_npi_linkage_FROZEN.csv"))
  }
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

cat("\n-- the other skip mechanism --\n")

#' A scratch repo whose gate skips through testthat rather than ci_skip()
#'
#' The blind spot this covers: a file CI runs via testthat::test_file() reports
#' `[ FAIL n | WARN n | SKIP n | PASS n ]`, which the `  --   ` scan never saw.
#' @keywords internal
#' @noRd
sb_tt_scaffold <- function(n_skips, expect) {
  d <- file.path(tempdir(), paste0("sbtt_", as.integer(stats::runif(1) * 1e9)))
  dir.create(file.path(d, "tests"), recursive = TRUE, showWarnings = FALSE)
  for (f in c("ci_report.R", "lib_manuscript_numbers.R", "ci_skip_budget.R"))
    file.copy(file.path(root, "tests", f), file.path(d, "tests", f))
  writeLines(c(
    "library(testthat)",
    sprintf("test_that('skipper %d', { skip('synthetic') })", seq_len(n_skips)),
    "test_that('a real assertion', { expect_true(TRUE) })"),
    file.path(d, "tests", "test_fake_tt.R"))
  writeLines(c("gate\tkind\twhen\tfull\tlean\treason",
               sprintf("tests/test_fake_tt.R\ttestthat\tpr\t%d\t%d\tsynthetic", expect, expect)),
             file.path(d, "tests", "skip_budget.tsv"))
  system2("git", c("-C", shQuote(d), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
  d
}

r <- sb_run_in(sb_tt_scaffold(2, 2))
chk(r$code == 0 && grepl("Observed skips:        2", r$text, fixed = TRUE),
    "two testthat skips, budgeted for two, pass and ARE counted")

r <- sb_run_in(sb_tt_scaffold(2, 0))
chk(r$code != 0 && grepl("Unexpected skips:      1", r$text, fixed = TRUE),
    "a testthat skip nobody budgeted for fails -- the blind spot, closed")

r <- sb_run_in(sb_tt_scaffold(0, 2))
chk(r$code != 0 && grepl("Stale expected skips:  1", r$text, fixed = TRUE),
    "a testthat skip that disappeared is stale, same as a ci_skip one")

cat("\n-- the second axis: a row's own precondition --\n")
# THE SCAFFOLD IS CLASSIFIED `lean` (a fresh git init has no person-level
# freeze), so a row that is nonetheless compared against `full` can only have
# got there through its `needs` spec. full and lean are set far apart in each
# case below for exactly that reason: if the gate ignored `needs` the count it
# compared against would be the other one and the case would fail.
#
# This axis exists because four real rows skip for the sf package and the
# ~/isochrones checkout rather than for private data, and a scratch worktree --
# `lean` on the data axis, `full` on theirs -- reported all four STALE when
# nothing was wrong with them (2026-11-22).

r <- sb_run_in(sb_scaffold(0, 0, lean = 9, needs = "pkg:stats"))
chk(r$code == 0 && grepl("full (pkg:stats present)", r$text, fixed = TRUE),
    "a SATISFIED precondition is compared against `full`, not the global flag")

r <- sb_run_in(sb_scaffold(0, 9, lean = 0, needs = "pkg:sbNoSuchPackageZZZ",
                           full_env = TRUE))
chk(r$code == 0 && grepl("lean (pkg:sbNoSuchPackageZZZ absent)", r$text, fixed = TRUE) &&
      grepl("environment: full", r$text, fixed = TRUE),
    "an ABSENT precondition is compared against `lean` even where the environment is `full`")

# NON-VACUITY, and the reason the unevaluable branch is a failure rather than a
# `next`. A row the gate cannot answer for is a row whose count was never
# checked, and with full == lean == 0 the budget would otherwise report PASS --
# the same shape as a gate that skipped its own assertions and exited 0.
r <- sb_run_in(sb_scaffold(0, 0, lean = 0, needs = "sbBogusKind:thing"))
chk(r$code != 0 && grepl("cannot evaluate", r$text, fixed = TRUE) &&
      grepl("Unevaluable rows:      1", r$text, fixed = TRUE),
    "a precondition the gate cannot evaluate FAILS rather than passing vacuously")

# The third state survives the new axis. A per-row column must not become a
# place to park a count nobody revisits.
r <- sb_run_in(sb_scaffold(0, 2, lean = 0, needs = "pkg:stats"))
chk(r$code != 0 && grepl("stale budget entry", r$text, fixed = TRUE),
    "a stale count is still stale when its row selected the column itself")

cat("\n-- completeness --\n")

# NON-EMPTY but missing the gate: an empty budget short-circuits at SB0 and
# never reaches SB1, so the first version of this fixture proved the wrong
# property. A nightly placeholder keeps the budget populated without SB2 trying
# to run it.
d <- sb_scaffold(1, 1)
writeLines(c("gate\tkind\twhen\tfull\tlean\treason",
             "tests/ci_report.R\tci_skip\tnightly\t-\t-\tplaceholder, not run in this tier"),
           file.path(d, "tests", "skip_budget.tsv"))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("not in the budget", r$text, fixed = TRUE),
    "a gate that can skip but is undeclared fails")

# THE SECOND SPELLING, added 2026-11-13 with the ci_require_files() mechanism.
# A gate can now skip without the word ci_skip appearing anywhere in it, which
# is a blind spot of exactly the shape the testthat SKIP count was. SB1's scan
# was widened to both spellings, so the widening gets its own fixture: without
# it, seven work-site tests would skip on every CI run and the budget would
# have no way to notice.
d <- sb_scaffold(0, 0)
writeLines(c("source(file.path('tests','ci_report.R'))",
             "ci_require_files('definitely/absent.csv', what = 'a synthetic private input')",
             "ci_ok('never reached')", "ci_finish()"),
           file.path(d, "tests", "ci_fake_requirer.R"))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("ci_fake_requirer.R", r$text, fixed = TRUE) &&
      grepl("not in the budget", r$text, fixed = TRUE),
    "a gate that skips via ci_require_files() and is undeclared also fails")

d <- sb_scaffold(1, 1)
writeLines(c("gate\tkind\twhen\tfull\tlean\treason",
             "tests/ci_fake_gate.R\tci_skip\tpr\t1\t1\ta synthetic gate",
             "tests/ci_gate_that_never_existed.R\tci_skip\tpr\t0\t0\tnothing"),
           file.path(d, "tests", "skip_budget.tsv"))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("do not exist", r$text, fixed = TRUE),
    "a budget naming a gate that does not exist fails")

d <- sb_scaffold(1, 1)
writeLines("gate\tkind\twhen\tfull\tlean\treason", file.path(d, "tests", "skip_budget.tsv"))
invisible(file.remove(file.path(d, "tests", "ci_fake_gate.R")))
system2("git", c("-C", shQuote(d), "add", "-A", "-f"), stdout = FALSE, stderr = FALSE)
r <- sb_run_in(d)
chk(r$code != 0 && grepl("SB0|empty or absent", r$text),
    "an empty budget refuses rather than passing vacuously")

cat(sprintf("\n%d passed, %d failed\n", pass, length(failed)))
if (length(failed)) { for (f in failed) cat(sprintf("  - %s\n", f)); quit(status = 1) }
cat("PASS (0 failures)\n")
