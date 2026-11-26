#!/usr/bin/env Rscript
# =============================================================================
# Does ci_read_width.R actually detect anything?
# =============================================================================
# A gate built on a parse walk fails silently in two ways, and this file exists
# because both of them happened while it was being written:
#
#   1. The path-variable resolver used regmatches() against a mask built from
#      the unfiltered line vector. regmatches() drops non-matching elements, so
#      the mask and the names were off by however many lines did not assign
#      anything -- and the gate quietly missed four files that reach the panel
#      through PANEL / PANEL_PATH / Sys.getenv().
#   2. Run from inside tests/, ci_tracked() listed only tests/ paths, the
#      "^tests/" exclusion removed every one of them, and the gate reported
#      PASS having scanned zero files.
#
# Both are the same failure: a smaller number than the truth, reported as
# success. RW5 and RW8 below are those two cases, planted deliberately, so
# neither can come back.
#
# Each case builds a minimal GIT repository -- git, because the gate asks
# `git ls-files` what to scan, so an untracked fixture is invisible to it --
# plants exactly one thing, and runs the real gate as a subprocess. The near
# misses (RW3, RW4, RW6, RW7) are the half that keeps the gate from hardening
# into "any mention of midwife_panel.csv is a finding", which would make the
# fix impossible to land.
#
# ~15 subprocess runs, about 20s. That is the whole reason the gate is
# trustworthy.
# =============================================================================

# The shared harness, not a fourth copy of it: test_repo_root(), chk(), sab()
# and saboteur_report() all live in tests/helper-saboteur.R, and ci_hygiene.R's
# H4 refuses a second top-level definition of any of them -- which it did, on
# this file's first run, for `sab`.
root <- local({
  from_rscript <- grep("--file=", commandArgs(), value = TRUE)
  if (length(from_rscript))
    normalizePath(file.path(dirname(sub("--file=", "", from_rscript[1])), ".."))
  else if (dir.exists(".git")) "." else ".."
})
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "RW"

GATE   <- file.path(root, "tests", "ci_read_width.R")
REPORT <- file.path(root, "tests", "ci_report.R")
WALK   <- file.path(root, "R", "lib", "ast_walk.R")
stopifnot(file.exists(GATE), file.exists(REPORT), file.exists(WALK))

# --- the scaffold ------------------------------------------------------------
# PADDING IS LOAD-BEARING. The gate refuses a scan of fewer than 50 non-test R
# files, because that is how it tells "the habit is fixed" from "the listing
# broke". A two-file fixture would therefore fail for a reason that has nothing
# to do with the case under test -- the same trap tests/ci_workflow_contracts.R
# W1's four-job floor sets -- so the scaffold pads to 60 and RW8 is the case
# that exercises the floor on purpose.
PAD_N <- 60L

# One baselined reader: the shape the live tree is full of.
READER_FULL <- c(
  'library(readr)',
  'nppes <- read_csv("midwife_panel.csv", col_types = cols(.default = "c"),',
  '                  progress = FALSE)',
  'print(nrow(nppes))')

BASELINE <- c(
  "# fixture baseline",
  "reader_one.R\t1\tgrandfathered for the fixture")

scaffold <- function(extra = list(), baseline = BASELINE) {
  d <- file.path(tempdir(), paste0("rw", as.integer(runif(1, 1, 1e9))))
  dir.create(file.path(d, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(d, "R", "lib"), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE,   file.path(d, "tests", "ci_read_width.R"))
  file.copy(REPORT, file.path(d, "tests", "ci_report.R"))
  file.copy(WALK,   file.path(d, "R", "lib", "ast_walk.R"))
  writeLines(baseline, file.path(d, "tests", "ci_read_width_baseline.txt"))
  writeLines(READER_FULL, file.path(d, "reader_one.R"))
  for (i in seq_len(PAD_N))
    writeLines(sprintf("f%d <- function() %d", i, i), file.path(d, sprintf("pad%02d.R", i)))
  for (rel in names(extra)) {
    dir.create(dirname(file.path(d, rel)), recursive = TRUE, showWarnings = FALSE)
    writeLines(extra[[rel]], file.path(d, rel))
  }
  # Tracked, not merely present: the gate reads `git ls-files`, so an untracked
  # fixture is a fixture the gate cannot see, and every case would pass.
  system2("git", c("-C", shQuote(d), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(d), "add", "-A"), stdout = FALSE, stderr = FALSE)
  d
}

# Rscript inherits the caller's working directory, so the gate has to be run
# FROM the fixture, not merely pointed at it. Done with a subshell so this
# process never changes directory -- a cd here would leave the harness in a
# temp tree if a case threw.
run_read_width_gate <- function(d, from = ".") {
  cmd <- sprintf("cd %s && Rscript --vanilla %s/tests/ci_read_width.R 2>&1",
                 shQuote(file.path(d, from)),
                 if (from == ".") "." else "..")
  out <- suppressWarnings(system(cmd, intern = TRUE))
  list(out = out, failed = any(grepl("^FAILED", out)))
}

# =============================================================================
sab(0, "CONTROL: the clean scaffold passes")
d <- scaffold()
r <- run_read_width_gate(d)
chk(!r$failed, "a tree whose only full-width read is baselined -> passes")
if (r$failed) cat(paste0("       ", r$out, "\n"))
chk(any(grepl("1 grandfathered", r$out)), "and it reports the baselined read as grandfathered")

sab(1, "SABOTEUR: a NEW file reads the panel full-width")
r <- run_read_width_gate(scaffold(list("new_reader.R" = READER_FULL)))
chk(r$failed, "a new full-width literal read -> refused")
chk(any(grepl("new_reader\\.R", r$out)), "and the refusal names the file")

sab(2, "SABOTEUR: a baselined file grows a SECOND read")
r <- run_read_width_gate(scaffold(list("reader_one.R" = c(READER_FULL, READER_FULL))))
chk(r$failed, "a baselined file going from 1 read to 2 -> refused")
chk(any(grepl("full-width 2 time", r$out)), "and the refusal reports 2 against a baseline of 1")

sab(3, "NEAR MISS: col_select names the columns")
r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
  'library(readr)',
  'x <- read_csv("midwife_panel.csv",',
  '              col_select = c("npi", "snapshot_year", "practice_state"),',
  '              col_types = cols(.default = "c"), progress = FALSE)'))))
chk(!r$failed, "a narrowed read -> passes")

sab(4, "NEAR MISS: a col_skip() spec excludes the rest")
r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
  'library(readr)',
  'x <- read_csv("midwife_panel.csv",',
  '              col_types = cols(npi = col_character(),',
  '                               last_name = col_skip()), progress = FALSE)'))))
chk(!r$failed, "a spec that skips columns -> passes")

sab(5, "SABOTEUR: the path arrives through a variable")
# The bug this case exists for let all of PANEL, PANEL_PATH and panel_path
# through. All three spellings are planted, in the three forms the live tree
# uses, so fixing one spelling cannot pass this case.
for (v in c("PANEL", "PANEL_PATH", "panel_path")) {
  r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
    'library(readr)',
    sprintf('%s <- "midwife_panel.csv"', v),
    sprintf('x <- read_csv(%s, col_types = cols(.default = "c"), progress = FALSE)', v)))))
  chk(r$failed, sprintf("a full-width read through `%s` -> refused", v))
}
r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
  'library(readr)',
  'PANEL <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")',
  'x <- read_csv(PANEL, col_types = cols(.default = "c"), progress = FALSE)'))))
chk(r$failed, "a full-width read through Sys.getenv()'s default -> refused")

sab(6, "NEAR MISS: the panel variable exists, the read is of something else")
r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
  'library(readr)',
  'PANEL <- "midwife_panel.csv"   # named, documented, not read here',
  'other <- read_csv("artifacts/small.csv", col_types = cols(.default = "c"))'))))
chk(!r$failed, "naming the panel without reading it -> passes")

sab(7, "NEAR MISS: a fixture under tests/ is out of scope")
r <- run_read_width_gate(scaffold(list("tests/test_fixture_reader.R" = READER_FULL)))
chk(!r$failed, "a full-width read inside tests/ -> passes (not a 544 MB read)")

sab(8, "SABOTEUR: the file listing breaks")
# The floor. A tree with almost no R files is indistinguishable, to a gate
# without a floor, from a tree where the habit was fixed -- and that is exactly
# what running from tests/ produced.
d <- file.path(tempdir(), paste0("rwmin", as.integer(runif(1, 1, 1e9))))
dir.create(file.path(d, "tests"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(d, "R", "lib"), recursive = TRUE, showWarnings = FALSE)
invisible(file.copy(GATE,   file.path(d, "tests", "ci_read_width.R")))
invisible(file.copy(REPORT, file.path(d, "tests", "ci_report.R")))
invisible(file.copy(WALK,   file.path(d, "R", "lib", "ast_walk.R")))
writeLines(BASELINE, file.path(d, "tests", "ci_read_width_baseline.txt"))
writeLines("x <- 1", file.path(d, "only.R"))
system2("git", c("-C", shQuote(d), "init", "-q"), stdout = FALSE, stderr = FALSE)
system2("git", c("-C", shQuote(d), "add", "-A"), stdout = FALSE, stderr = FALSE)
r <- run_read_width_gate(d)
chk(r$failed, "a tree with 1 non-test R file -> refused as a broken listing")
chk(any(grepl("floor", r$out)), "and the refusal says the listing is broken, not that the tree is clean")

sab(9, "NEAR MISS: a paid-down baseline is a note, not a failure")
r <- run_read_width_gate(scaffold(list(), baseline = c(
  "# fixture baseline",
  "reader_one.R\t1\tgrandfathered",
  "already_fixed.R\t2\tnarrowed in a later commit; this row is stale")))
chk(!r$failed, "a baseline row whose file no longer reads full-width -> passes")
chk(any(grepl("already_fixed\\.R", r$out)),
    "and the gate names the stale row so the baseline gets shrunk")

sab(10, "SABOTEUR: the path is assigned ACROSS LINES")
# The third way this gate failed silently, and the one that hid the two
# most expensive reads in the repository: the panel's own producer assigns
# out_path over five lines, so a resolver that grepped one line at a time
# never learned the name and never counted read.csv(out_path). Both forms
# are planted -- the wrapped Sys.getenv() and a wrapped if/else default --
# because the live assignment is both at once.
r <- run_read_width_gate(scaffold(list("new_reader.R" = c(
  'out_path <- Sys.getenv(',
  '  "MIDWIFE_PANEL_OUT",',
  '  # the scope is in the filename',
  '  if (SCOPE == "wide") "midwife_panel_wide.csv" else "midwife_panel.csv")',
  'panel <- read.csv(out_path, colClasses = "character")'))))
chk(r$failed, "a full-width read through a multi-line assignment -> refused")
chk(any(grepl("new_reader\\.R", r$out)), "and the refusal names the file")

sab(11, "NEAR MISS + SABOTEUR: the measurement harness, and only it")
# The gate exempts tools/measure_panel_read_cost.R by name, because timing a
# full-width read requires performing one. An exclusion of all of tools/
# would hide the next script that reads the panel badly, so both halves are
# planted: the instrument passes, its neighbour does not.
r <- run_read_width_gate(scaffold(list(
  "tools/measure_panel_read_cost.R" = READER_FULL)))
chk(!r$failed, "a full-width read in the measurement harness -> passes")
r <- run_read_width_gate(scaffold(list(
  "tools/measure_something_else.R" = READER_FULL)))
chk(r$failed, "a full-width read in ANOTHER tools/ file -> refused")
chk(any(grepl("measure_something_else\\.R", r$out)),
    "and the refusal names it, so the exemption cannot be read as covering tools/")

# =============================================================================
saboteur_report(12)
