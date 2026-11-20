#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-20 over-engineering cuts
# =============================================================================
# Four cuts, each of which a future edit can quietly undo by doing the
# convenient thing: copy a harness from the file next door, re-add a reader,
# reach for here::here(), restore a script from git. None of those would fail
# anything, which is why each gets a gate that mutates itself to prove it
# bites.
#
#   P1 The standalone-test harness is sourced, not copied. 66 files carried a
#      byte-identical root resolver + `fails` + `chk`; helper-saboteur.R
#      exports all three and was adopted in 15 of ~247 files.
#   P2 Deleted code stays deleted -- nothing EXECUTES an @archive path.
#      Comments may still discuss one; a comment is not a dependency.
#   P3 One name, one behaviour for the all-character CSV reader. `rd` had
#      drifted into four different functions, one of which returned SQL.
#   P4 One root mechanism in tests. `here` was a second one.
#
# SCOPED TO WHAT WAS ACTUALLY CUT. P1 polices the exact idiom that was
# removed, not every harness in the tree: 33 files still carry the same `chk`
# under a different root idiom (`basename(getwd()) == "tests"`), and choosing
# between those idioms is a separate decision from removing a byte-identical
# copy. A gate that failed on them would be asserting a cut nobody made.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "P"

tracked <- function(pattern) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(root), "ls-files", pattern),
                                  stdout = TRUE, stderr = FALSE))
  if (!length(out)) character(0) else out
}
slurp <- function(rel) paste(readLines(file.path(root, rel), warn = FALSE), collapse = "\n")

HELPER <- "tests/helper-saboteur.R"
ROOT_IDIOM <- paste(
  'root <- {',
  '  a <- grep("--file=", commandArgs(), value = TRUE)',
  '  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))',
  '  else normalizePath(".")',
  '}', sep = "\n")
CHK_IDIOM <- paste(
  'chk <- function(cond, m) {',
  '  if (isTRUE(cond)) cat(sprintf("  ok   %s\\n", m))',
  '  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\\n", m)) }',
  '}', sep = "\n")
FAILS_IDIOM <- "\nfails <- 0L\n"

# --- P1 the harness is sourced, not copied -------------------------------------
sab(1, "the standalone-test harness is sourced, not copied")
copies_harness <- function(txt)
  !grepl("helper-saboteur", txt, fixed = TRUE) &&
  grepl(ROOT_IDIOM, txt, fixed = TRUE) &&
  grepl(CHK_IDIOM, txt, fixed = TRUE) &&
  grepl(FAILS_IDIOM, txt, fixed = TRUE)

offenders <- Filter(function(f) copies_harness(slurp(f)), tracked("tests/*.R"))
chk(!length(offenders),
    sprintf("P1a no test file copies the exact root+fails+chk harness instead of sourcing it%s",
            if (length(offenders)) paste0(" [", paste(basename(offenders), collapse = ", "), "]") else ""))
chk(grepl("test_repo_root", slurp(HELPER), fixed = TRUE) &&
      grepl("chk <- function", slurp(HELPER), fixed = TRUE),
    "P1b helper-saboteur.R still exports the harness those files now depend on")
# SABOTEUR: paste the harness back into a file and the same predicate must fire.
chk(copies_harness(paste(ROOT_IDIOM, FAILS_IDIOM, CHK_IDIOM, sep = "\n")),
    "P1c KILLED: a file that pastes the harness back in is caught by the predicate that clears the tree")
chk(!copies_harness(paste('source("helper-saboteur.R")', ROOT_IDIOM, FAILS_IDIOM,
                          CHK_IDIOM, sep = "\n")),
    "P1d a file that sources the helper is not an offender even if it keeps a local root line")

# --- P2 deleted code stays deleted ---------------------------------------------
sab(2, "nothing executes a path that was deleted")
# EXECUTION, not mention. compare_pecos_to_doximity_address.R still quotes the
# removed experiment's conclusion in a comment, deliberately, so the caveat it
# supports does not depend on a file. That is not a dependency.
exec_archive <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  lines <- lines[!grepl("^\\s*#", lines)]
  grep("(source|system2|file\\.exists|readLines)\\([^)]*@archive/[^)]*\\.R", lines,
       value = TRUE, perl = TRUE)
}
hits <- unlist(lapply(tracked("*.R"), function(f) {
  h <- exec_archive(slurp(f)); if (length(h)) paste0(basename(f), ": ", h[1]) else character(0)
}))
chk(!length(hits),
    sprintf("P2a no tracked R file executes an @archive path%s",
            if (length(hits)) paste0(" [", paste(hits, collapse = "; "), "]") else ""))
chk(!length(tracked("@archive/*.R")),
    "P2b @archive carries no R scripts; the one survivor is the Python model that still has a test")
chk(length(tracked("@archive/run_midwifery_microsimulation.py")) == 1L,
    "P2c ... and that survivor is still tracked, because tests/test_run_midwifery_microsimulation.R runs it")
# SABOTEUR: restore an execution and the scanner must see it.
chk(length(exec_archive('source("@archive/experiment_external_org_sources.R")')) == 1L,
    "P2d KILLED: a restored source() of a deleted script is caught")
chk(length(exec_archive('# see @archive/experiment_external_org_sources.R for the assessment')) == 0L,
    "P2e a comment discussing the removed script is not a dependency")

# --- P3 one name, one behaviour for the reader ---------------------------------
sab(3, "the all-character CSV reader is defined once")
# A COMPLETE LINE, NOT A PREFIX. The first draft of this predicate used a
# substring test and flagged audit_linkage_arms_3way.R, whose `rd` continues
# `%>% transmute(...)` on the next line -- it reads AND projects, so it is a
# different function that happens to start the same way. Matching the whole
# line is what separates a duplicate from a relative.
DUP_READER_LINE <-
  'rd <- function(p) read_csv(p, col_types = cols(.default = "c"), progress = FALSE)'
dup_reader <- function(txt)
  any(trimws(strsplit(txt, "\n", fixed = TRUE)[[1]]) == DUP_READER_LINE)
dups <- Filter(function(f) dup_reader(slurp(f)), tracked("*.R"))
chk(!length(dups),
    sprintf("P3a no file redefines the all-character reader that R/lib/common_helpers.R already exports as chr()%s",
            if (length(dups)) paste0(" [", paste(basename(dups), collapse = ", "), "]") else ""))
chk(grepl("chr <- function", slurp("R/lib/common_helpers.R"), fixed = TRUE),
    "P3b chr() is still the one definition those call sites now reach")
chk(!grepl("\nrd <- function", slurp("build_pecos_organization_affiliations.R"), fixed = TRUE),
    "P3c the DuckDB scan builder no longer answers to the name of a CSV reader")
chk(dup_reader(DUP_READER_LINE),
    "P3d KILLED: the exact duplicate definition is caught when added back")
chk(!dup_reader(paste0(DUP_READER_LINE, " %>%\n  transmute(npi)")),
    "P3e a reader that goes on to project is a different function, not a duplicate")

# --- P4 one root mechanism in tests ---------------------------------------------
sab(4, "tests resolve the repository root one way")
loads_here <- function(txt) grepl("library(here)", txt, fixed = TRUE)
here_tests <- Filter(function(f) loads_here(slurp(f)), tracked("tests/*.R"))
chk(!length(here_tests),
    sprintf("P4a no test file loads `here` as a second root mechanism%s",
            if (length(here_tests)) paste0(" [", paste(basename(here_tests), collapse = ", "), "]") else ""))
chk(loads_here("library(testthat)\nlibrary(here)\n"),
    "P4b KILLED: re-adding library(here) to a test is caught")

cat(sprintf("\n%s (%d failure(s) across 4 over-engineering saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS", fails))
quit(status = if (fails == 0L) 0L else 1L)
