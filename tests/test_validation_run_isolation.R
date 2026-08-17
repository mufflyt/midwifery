#!/usr/bin/env Rscript
# =============================================================================
# Two concurrent verifiers must never blend their outputs
# =============================================================================
# REGRESSION TEST FOR A REAL INCIDENT. During the osm.de full-cohort
# verification, two verifier processes ran simultaneously against the same
# worktree, both calling write_csv() on the same canonical paths from different
# revisions of the script. Nothing errored. The surviving files could have been
# file A from run 1 and file B from run 2 -- a self-inconsistent result set that
# looked completely normal and would have been committed.
#
# The property under test is NOT "the second run fails". It is stronger and more
# useful: a reader of the canonical location always sees one whole run's output,
# never a mixture, and a run that did not finish never becomes canonical.
# =============================================================================
root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "R", "lib", "validation_run.R"))

pass <- 0L; fail <- 0L
ok <- function(what, cond) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  PASS  %s\n", what)) }
  else { fail <<- fail + 1L; cat(sprintf("  FAIL  %s\n", what)) }
}
base <- file.path(tempdir(), paste0("valrun_", Sys.getpid()))
on.exit(unlink(base, recursive = TRUE), add = TRUE)

# --- 1. concurrent runs cannot collide on a directory ------------------------
cat("[1] two runs get disjoint output directories\n")
a <- validation_run_begin(base, run_id = "AAA")
b <- validation_run_begin(base, run_id = "BBB")
ok("distinct directories", !identical(a$dir, b$dir))
ok("both exist",           dir.exists(a$dir) && dir.exists(b$dir))
ok("reusing a run id is refused",
   inherits(try(validation_run_begin(base, run_id = "AAA"), silent = TRUE),
            "try-error"))

# --- 2. interleaved writes stay inside their own run -------------------------
# Written in the worst order: A, then B, then A again. Under the old scheme this
# is exactly the sequence that produced a mixed result set.
cat("\n[2] interleaved writes never touch each other\n")
writeLines("A-coverage", validation_run_path(a, "coverage.csv"))
writeLines("B-coverage", validation_run_path(b, "coverage.csv"))
writeLines("A-quality",  validation_run_path(a, "quality.csv"))
writeLines("B-quality",  validation_run_path(b, "quality.csv"))
ok("A's coverage is A's", readLines(validation_run_path(a, "coverage.csv")) == "A-coverage")
ok("A's quality is A's",  readLines(validation_run_path(a, "quality.csv"))  == "A-quality")
ok("B's coverage is B's", readLines(validation_run_path(b, "coverage.csv")) == "B-coverage")
ok("B's quality is B's",  readLines(validation_run_path(b, "quality.csv"))  == "B-quality")

# --- 3. an unpromoted run is not canonical -----------------------------------
cat("\n[3] nothing is canonical until a run promotes\n")
ok("no latest before promotion", is.na(validation_run_latest(base)))

# --- 4. promotion publishes ONE whole run ------------------------------------
cat("\n[4] promotion is all-or-nothing\n")
validation_run_promote(a)
lat <- validation_run_latest(base)
ok("latest resolves",            !is.na(lat))
ok("latest is A, coverage",      readLines(file.path(lat, "coverage.csv")) == "A-coverage")
ok("latest is A, quality",       readLines(file.path(lat, "quality.csv"))  == "A-quality")

validation_run_promote(b)
lat <- validation_run_latest(base)
consistent <- readLines(file.path(lat, "coverage.csv")) == "B-coverage" &&
              readLines(file.path(lat, "quality.csv"))  == "B-quality"
ok("after B promotes, latest is entirely B -- never a blend", consistent)

# The incident in one assertion: under the old scheme this combination was
# reachable. Under run-scoped promotion it is not representable.
mixed <- readLines(file.path(lat, "coverage.csv")) == "A-coverage" &&
         readLines(file.path(lat, "quality.csv"))  == "B-quality"
ok("a mixed A/B result set is unreachable", !mixed)

# --- 5. a failed run must not become canonical -------------------------------
cat("\n[5] a run that does not complete never promotes\n")
cc <- validation_run_begin(base, run_id = "CCC")
writeLines("C-partial", validation_run_path(cc, "coverage.csv"))
# quality.csv deliberately never written: this run "died" mid-way.
before <- validation_run_latest(base)
# No promote call is made, because the gates did not pass.
ok("latest unchanged by an abandoned run",
   identical(before, validation_run_latest(base)))
ok("latest still points at a complete run",
   file.exists(file.path(validation_run_latest(base), "quality.csv")))

# --- 6. every run remains inspectable afterwards -----------------------------
cat("\n[6] superseded runs are retained, not overwritten\n")
runs <- list.dirs(base, recursive = FALSE, full.names = FALSE)
runs <- runs[grepl("^run-", runs)]
ok("all three runs still on disk", length(runs) == 3L)
ok("A's outputs survive B's promotion",
   readLines(file.path(base, "run-AAA", "coverage.csv")) == "A-coverage")

cat(sprintf("\n%s passed, %s failed\n", pass, fail))
if (fail) quit(status = 1L)
