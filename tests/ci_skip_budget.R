#!/usr/bin/env Rscript
# =============================================================================
# A new skipped test is a regression until someone writes down why
# =============================================================================
# `  ok  ` and `  --  ` differ by two characters and exit the same way. A gate
# that stops evaluating anything -- because an artifact moved, a package went
# missing, or a condition quietly went false -- prints a slightly different line
# and still reports success. Nobody reads for that.
#
# This is the same defect the aggregate scientific gate catches between JOBS,
# caught between TESTS. There, a required check reported success in six seconds
# three times running because its steps were skipped by an `if:`. Here, a gate
# reports success because its assertions were skipped by an `if`.
#
# It is a BUDGET rather than a ban because some skips are correct and permanent:
# a check on person-level data cannot run on a bare checkout, and pretending
# otherwise would mean either deleting the check or lying about it. What is
# forbidden is a skip nobody declared, and -- equally -- a declaration nobody
# revisited after the reason expired.
#
# TWO SKIP MECHANISMS, because there are two. ci_skip() prints `  --   `; a file
# CI runs through testthat::test_file() reports `[ FAIL n | WARN n | SKIP n |
# PASS n ]`. The first version of this budget counted only the first, so a suite
# could have converted every assertion into a testthat skip and the summary
# would still have read `Observed skips: 4`. test_invariants_midwifery.R skips
# three assertions on a runner today and none of them were counted.
#
# FEEDS THE SCIENTIFIC GATE by running inside a job that gate already requires.
# A skip-budget failure fails that job, and the aggregate gate refuses to call
# the pull request green. There is no separate wiring to fall out of date.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "tests", "lib_manuscript_numbers.R"))   # mn_read_tsv

BUDGET <- file.path(root, "tests", "skip_budget.tsv")
PERSON_LEVEL <- file.path(root, "artifacts", "amcb_npi_linkage_FROZEN.csv")

bud <- mn_read_tsv(BUDGET)
if (is.null(bud) || !nrow(bud)) {
  ci_fail("SB0: tests/skip_budget.tsv is empty or absent. A budget over nothing\n       reports success, which is the defect rather than the fix.")
  ci_finish()
}

env_full <- file.exists(PERSON_LEVEL)
env_name <- if (env_full) "full" else "lean"
col <- if (env_full) "full" else "lean"
cat(sprintf("\nenvironment: %s (%s)\n", env_name,
            if (env_full) "person-level artifacts present"
            else "bare checkout, as CI runs"))

# --- SB1 every gate that can skip is declared --------------------------------
# Static, and the reason this is not merely a count check: a NEW gate that
# skips would otherwise be invisible here, because a budget can only compare
# what it already knows about.
ci_section("SB1 every gate that can skip is in the budget")
# SELF-EXCLUDED, and it caught itself first time out: this file contains the
# literal `ci_skip(` inside the pattern it searches for, so it reported itself
# as an undeclared skipping gate. It never calls ci_skip; it looks for callers.
# Named rather than pattern-dodged, because a cleverer regex would be one more
# thing to be subtly wrong about.
# THE MACHINERY EXCLUDES ITSELF, and both entries were found by the check
# firing rather than by foresight. This file carries the literal `ci_skip(`
# inside the pattern it searches for; the detector WRITES that literal into its
# synthetic fixtures. Neither calls it. Named explicitly rather than dodged with
# a cleverer regex, because a regex that has to distinguish a call from a string
# containing a call is one more thing to be subtly wrong about.
NOT_GATES <- c("tests/ci_skip_budget.R", "tests/test_skip_budget_detect.R")
skippers <- Filter(function(f) {
  !(f %in% NOT_GATES) &&
    any(grepl("ci_skip\\(", readLines(file.path(root, f), warn = FALSE)))
}, ci_tracked("tests/*.R"))
# testthat targets are named in ci.yml rather than discoverable from the source,
# because a file only skips through testthat when CI chooses to run it that way.
# Absent in the synthetic repositories the detector builds, and absent is not a
# failure there -- a scratch repo with no workflow has no testthat targets to
# declare. Guarded rather than assumed, because an unguarded readLines() here
# crashes the checker instead of reporting anything.
ciyml_path <- file.path(root, ".github", "workflows", "ci.yml")
ciyml <- if (file.exists(ciyml_path)) readLines(ciyml_path, warn = FALSE) else character(0)
tt_targets <- unique(sub('.*testthat::test_file\\("([^"]+)".*', "\\1",
                         grep('testthat::test_file\\("', ciyml, value = TRUE)))
skippers <- unique(c(skippers, tt_targets))
undeclared <- setdiff(skippers, bud$gate)
orphaned <- setdiff(bud$gate, ci_tracked("tests/*.R"))
if (length(undeclared)) {
  ci_fail("SB1: gate(s) that can skip but are not in the budget: %s.\n       Add them with an expected count and a reason.",
          paste(undeclared, collapse = ", "))
}
if (length(orphaned)) {
  ci_fail("SB1: budget names gate(s) that do not exist: %s.", paste(orphaned, collapse = ", "))
}
if (!length(undeclared) && !length(orphaned)) {
  ci_ok("all %d gate(s) that can skip are declared (%d via ci_skip, %d via testthat)",
        length(skippers), length(skippers) - length(tt_targets), length(tt_targets))
}

# --- SB2 the counts ----------------------------------------------------------
ci_section("SB2 observed skips match the budget")
rows <- bud[bud$when == "pr", , drop = FALSE]
obs_total <- 0L; exp_total <- 0L
unexpected <- character(0); stale <- character(0); detail <- character(0)

for (i in seq_len(nrow(rows))) {
  g <- rows$gate[i]
  expect <- suppressWarnings(as.integer(rows[[col]][i]))
  if (is.na(expect)) next
  kind <- if ("kind" %in% names(rows)) rows$kind[i] else "ci_skip"
  if (identical(kind, "testthat")) {
    out <- suppressWarnings(system2("Rscript",
      c("-e", shQuote(sprintf('testthat::test_file("%s", stop_on_failure = FALSE)', g))),
      stdout = TRUE, stderr = TRUE))
    # The progress display prints a running summary; the last one is the total.
    sums <- grep("SKIP [0-9]+", out, value = TRUE)
    if (!length(sums)) {
      # NON-VACUITY. No summary means the file did not run, and a file that did
      # not run has zero skips in exactly the way a deleted test does.
      unexpected <- c(unexpected, sprintf("%s: produced no testthat summary line, so its skips could not be counted", g))
      n <- NA_integer_
    } else {
      n <- as.integer(sub(".*SKIP ([0-9]+).*", "\\1", sums[length(sums)]))
    }
  } else {
    out <- suppressWarnings(system2("Rscript", c(shQuote(file.path(root, g))),
                                    stdout = TRUE, stderr = TRUE))
    n <- sum(grepl("^  --   ", out))
  }
  if (is.na(n)) next
  obs_total <- obs_total + n; exp_total <- exp_total + expect
  mark <- if (n == expect) "ok" else if (n > expect) "NEW" else "STALE"
  detail <- c(detail, sprintf("| `%s` | %d | %d | %s |", g, n, expect, mark))
  if (n > expect) {
    lines <- if (identical(kind, "testthat")) grep("SKIP [0-9]+", out, value = TRUE)
             else sub("^  --   ", "", out[grepl("^  --   ", out)])
    unexpected <- c(unexpected, sprintf("%s: %d skip(s), budget allows %d\n              %s",
                                        g, n, expect,
                                        paste(substr(lines, 1, 90), collapse = "\n              ")))
  }
  if (n < expect)
    stale <- c(stale, sprintf("%s: %d skip(s), budget still expects %d -- the reason has expired",
                              g, n, expect))
}

summary_txt <- paste(c(
  "## Skip budget", "",
  sprintf("Environment: **%s**", env_name), "",
  "| gate | observed | expected | |", "|---|---|---|---|", detail, "",
  "```",
  sprintf("Observed skips:        %d", obs_total),
  sprintf("Expected skips:        %d", exp_total),
  sprintf("Unexpected skips:      %d", length(unexpected)),
  sprintf("Stale expected skips:  %d", length(stale)),
  "",
  if (!length(unexpected) && !length(stale)) "PASS" else "FAIL",
  "```"), collapse = "\n")
cat("\n", summary_txt, "\n", sep = "")
if (nzchar(Sys.getenv("GITHUB_STEP_SUMMARY")))
  cat(summary_txt, "\n", file = Sys.getenv("GITHUB_STEP_SUMMARY"), append = TRUE)

if (length(unexpected))
  ci_fail("SB2: %d gate(s) skipped more than the budget allows:\n%s\n       Something stopped being checked. Fix it, or add it to\n       tests/skip_budget.tsv with a reason.",
          length(unexpected), paste(sprintf("       - %s", unexpected), collapse = "\n"))
if (length(stale))
  ci_fail("SB2: %d stale budget entry/entries:\n%s\n       The skip no longer happens. Lower the count, so the budget stays a\n       record of what is actually unchecked rather than of what once was.",
          length(stale), paste(sprintf("       - %s", stale), collapse = "\n"))
if (!length(unexpected) && !length(stale))
  ci_ok("%d observed skip(s) across %d gate(s), all budgeted", obs_total, nrow(rows))

ci_finish()
