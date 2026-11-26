#!/usr/bin/env Rscript
# =============================================================================
# Gate-of-gates for tests/ci_workflow_contracts.R W2
# =============================================================================
# W2 says every tests/ci_*.R gate is named by some job, on a line that can
# actually run. It was written because tests/ci_denominator_contracts.R had
# reached exactly that state: wired in 62d24e9, deliberately red while DEBT D14
# was open, steps lost in a later merge resolution, then D14 closed and the gate
# went green -- reporting PASS from no job at all.
#
# A check that cannot fail is worse than a missing one, and this repository has
# shipped four of those. So each case below builds a throwaway tree, plants one
# defect, runs the REAL gate in it as a subprocess, and requires the exit status
# to match. The near misses matter as much as the kills: a W2 that flagged
# ci_report.R, or that could not tell a run: line from a comment, would be
# turned off within a week.
#
# Run: Rscript tests/test_workflow_contracts_detect.R   (exit 1 on any failure)
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
SAB_PREFIX <- "W"

GATE <- file.path(root, "tests", "ci_workflow_contracts.R")
REPORT <- file.path(root, "tests", "ci_report.R")

# A workflow that W1 is happy with: it installs R before running Rscript. Every
# case keeps W1 green, so a non-zero exit is attributable to W2 and not to the
# check that happens to live above it.
# TWO jobs, not one: W1 treats a single job as evidence that its scanner has
# stopped understanding the file and fails rather than passing vacuously, so a
# one-job fixture fails for a reason that has nothing to do with W2.
#
# It must also name ci_workflow_contracts.R itself. The scaffold copies the gate
# into tests/, so W2 sees it as a gate like any other and is RIGHT to flag it
# when nothing runs it -- a detector whose fixture leaves the gate unwired is
# testing the fixture, not the gate.
wf_ok <- function(extra = character(0)) {
  c("jobs:",
    "  checks:",
    "    name: Checks",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "      - uses: r-lib/actions/setup-r@v2",
    "      - name: Workflow contracts",
    "        run: Rscript tests/ci_workflow_contracts.R",
    "      - name: A real step",
    "        run: Rscript tests/ci_wired.R",
    extra,
    # FOUR jobs. W1's non-vacuity floor is `n_jobs < 4L` -- a number tuned to
    # the real repository (17 jobs), on the reasoning that a scan matching
    # almost nothing has stopped understanding the file and must not report
    # success. The side effect is that W1 cannot run in a minimal tree at all,
    # so any fixture for anything in this file has to carry four jobs whether
    # or not the law under test cares. Recorded rather than worked around: if
    # that floor is ever made relative instead of absolute, this padding goes.
    "  second:",
    "    name: Second job",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "  third:",
    "    name: Third job",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "  fourth:",
    "    name: Fourth job",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4")
}

wc_scaffold <- function(dir, gates, workflow) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE, file.path(dir, "tests", "ci_workflow_contracts.R"))
  file.copy(REPORT, file.path(dir, "tests", "ci_report.R"))
  # The gate sources this helper since the #333 refactor; a scaffold without
  # it crashes the gate, which reads as a refusal and inverts every case.
  helper <- file.path(root, "tests", "helper-workflow-scan.R")
  if (file.exists(helper))
    file.copy(helper, file.path(dir, "tests", "helper-workflow-scan.R"))
  for (g in gates)
    writeLines("quit(status = 0L)", file.path(dir, "tests", g))
  if (!is.null(workflow)) {
    dir.create(file.path(dir, ".github", "workflows"), recursive = TRUE,
               showWarnings = FALSE)
    writeLines(workflow, file.path(dir, ".github", "workflows", "ci.yml"))
  }
}

# TRUE when the gate refused. The `cd` is load-bearing: the gate resolves its
# own root from the working directory, so without it every case would run
# against the real repository, where W2 passes and every assertion below would
# hold for the wrong reason.
wc_fails <- function(dir) {
  st <- suppressWarnings(system2(
    "sh", c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_workflow_contracts.R",
                                  shQuote(dir)))),
    stdout = NULL, stderr = NULL))
  !identical(as.integer(st), 0L)
}

wc_case <- function(label, gates, workflow, expect_fail = TRUE) {
  dir <- file.path(tempdir(), paste0("wc", sample.int(1e6, 1)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  wc_scaffold(dir, gates, workflow)
  chk(identical(wc_fails(dir), expect_fail), label)
}

sab(0, "the clean scaffold passes, so a failure below means the defect")
# Built FIRST and from the fixed shape. A scaffold copied from a broken tree
# fails on construction and makes every perturbation above it vacuous -- the
# mistake this repository already made once building a detector.
wc_case("W0 a gate named on a run: line -> gate passes",
        gates = "ci_wired.R", workflow = wf_ok(), expect_fail = FALSE)

sab(1, "SABOTEUR: a gate no job mentions at all")
# tests/ci_denominator_contracts.R, reproduced. The gate file exists, it would
# pass if run, and nothing runs it.
wc_case("W1 an unmentioned gate -> W2 refuses",
        gates = c("ci_wired.R", "ci_orphan.R"), workflow = wf_ok())

sab(2, "SABOTEUR: a gate named ONLY in a comment")
# The weakness in the nightly's equivalent check, which greps the whole file:
# a commented-out step reads as wiring and runs never.
wc_case("W2 a gate named only in a YAML comment -> W2 refuses",
        gates = c("ci_wired.R", "ci_commented.R"),
        workflow = wf_ok("      # - run: Rscript tests/ci_commented.R"))

sab(3, "NEAR MISS: the same name, on a line that runs")
wc_case("W3 the same gate moved onto a run: line -> passes",
        gates = c("ci_wired.R", "ci_commented.R"),
        workflow = wf_ok("      - run: Rscript tests/ci_commented.R"),
        expect_fail = FALSE)

sab(4, "NEAR MISS: ci_report.R is sourced, never run")
# It defines the shared reporter. Flagging it would make W2 unsatisfiable, and
# the only repair anyone would reach for is switching W2 off.
wc_case("W4 an unnamed ci_report.R -> passes, it is excluded by design",
        gates = c("ci_wired.R", "ci_report.R"), workflow = wf_ok(),
        expect_fail = FALSE)

sab(5, "NEAR MISS: a gate named in a DIFFERENT workflow file still counts")
# Most gates here are nightly-only on purpose. W2's law is "some job", not
# "the per-push job", and tightening it would orphan half the suite by fiat.
{
  dir <- file.path(tempdir(), paste0("wc", sample.int(1e6, 1)))
  dir.create(file.path(dir, ".github", "workflows"), recursive = TRUE,
             showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  wc_scaffold(dir, c("ci_wired.R", "ci_nightly_only.R"), wf_ok())
  writeLines(c("jobs:", "  n:", "    name: Nightly", "    steps:",
               "      - uses: r-lib/actions/setup-r@v2",
               "      - run: Rscript tests/ci_nightly_only.R"),
             file.path(dir, ".github", "workflows", "nightly.yml"))
  chk(identical(wc_fails(dir), FALSE),
      "W5 a gate named only in nightly.yml -> passes")
}

saboteur_report(6)
