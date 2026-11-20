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
#   P4 A test's root resolver matches how CI invokes it. The audit called
#      `here` a redundant second mechanism; it is the only one that works
#      under testthat::test_file(), which supplies no --file= and runs from
#      tests/. Converting eight files off it broke CI; this gate is the record.
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
# EVERY tracked .R file, not just the ones at the top level. A git pathspec of
# "*.R" returns 267 paths here and the repository has 645: it does not cross
# directory boundaries, so three of the scans below were reading the root
# scripts and calling the result "no tracked R file". Listing once and
# filtering in R makes the scope the message already claimed.
tracked_r <- function() grep("\\.R$", tracked("."), value = TRUE)

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

# AND THE SOURCE PATH HAS TO BE ONE ci_repo_integrity.R CAN RESOLVE. That gate
# builds a source() closure and keeps only the LITERAL TAIL of a file.path(),
# so the adopter idiom file.path(<computed dir>, "helper-saboteur.R") resolves
# to <root>/helper-saboteur.R and fails with "Missing source() target". The 15
# files that already used it never tripped the gate because none was a CI
# entrypoint -- it was armed, not harmless, and converting 67 more set it off.
unresolvable <- Filter(function(f) {
  txt <- slurp(f)
  grepl("helper-saboteur", txt, fixed = TRUE) &&
    !grepl('file.path(root, "tests", "helper-saboteur.R")', txt, fixed = TRUE)
}, tracked("tests/*.R"))
chk(!length(unresolvable),
    sprintf("P1e every file sources the helper by a path the integrity gate can resolve%s",
            if (length(unresolvable)) paste0(" [", paste(basename(unresolvable), collapse = ", "), "]") else ""))

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
hits <- unlist(lapply(tracked_r(), function(f) {
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
# Assembled, not spelled: P2a reads every tracked .R file including this one,
# and a fixture written out in full would make this suite its own offender.
.gone <- paste0("@", "archive/experiment_external_org_sources.R")
chk(length(exec_archive(sprintf('source("%s")', .gone))) == 1L,
    "P2d KILLED: a restored source() of a deleted script is caught")
chk(length(exec_archive(sprintf("# see %s for the assessment", .gone))) == 0L,
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
dups <- Filter(function(f) dup_reader(slurp(f)), tracked_r())
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

# --- P4 the root resolver matches how the test is invoked --------------------
sab(4, "a test's root resolver matches how CI invokes it")
# THIS SABOTEUR EXISTS BECAUSE THE AUDIT GOT IT BACKWARDS. `here` was called a
# redundant second root mechanism and eight test files were converted off it,
# onto the commandArgs idiom the other 240 use. CI then failed with
#
#   cannot open file '.../midwifery/tests/tests/helper-saboteur.R'
#
# because ci.yml runs those eight through testthat::test_file(), which sets the
# working directory to tests/ and passes no --file=. With no --file= the
# commandArgs idiom falls back to normalizePath("."), which under test_file()
# is tests/, not the repository root -- so every path built on it gains a
# second "tests". here::here() finds the project root whatever the working
# directory is, which is exactly the case it was there to handle. It was not a
# duplicate mechanism; it was the right one for a different invocation.
COMMANDARGS_ROOT <- "--file="
test_file_invoked <- local({
  yml <- slurp(".github/workflows/ci.yml")
  m <- regmatches(yml, gregexpr('test_file\\("tests/[^"]+"', yml))[[1]]
  # BOTH ends. The first draft stripped only the prefix, left the closing
  # quote on every path, and every file.exists() below was therefore FALSE --
  # so P4b scanned an empty list and could not fail. That is the same shape as
  # the defects this suite was written to catch, written into the suite.
  sub('"$', "", sub('test_file\\("', "", m))
})
chk(length(test_file_invoked) > 0L,
    sprintf("P4a ci.yml still invokes %d test(s) through testthat::test_file()",
            length(test_file_invoked)))
unresolved <- Filter(function(f) !file.exists(file.path(root, f)), test_file_invoked)
chk(!length(unresolved),
    sprintf("P4a2 every path P4b is about to scan actually resolves, so an empty scan means a clean tree and not a broken parser%s",
            if (length(unresolved)) paste0(" [", paste(unresolved, collapse = ", "), "]") else ""))
mismatched <- Filter(function(f) {
  if (!file.exists(file.path(root, f))) return(FALSE)
  grepl(COMMANDARGS_ROOT, slurp(f), fixed = TRUE)
}, test_file_invoked)
chk(!length(mismatched),
    sprintf("P4b no test_file()-invoked test resolves its root from commandArgs, which test_file does not supply%s",
            if (length(mismatched)) paste0(" [", paste(basename(mismatched), collapse = ", "), "]") else ""))
chk(grepl(COMMANDARGS_ROOT,
          'root <- if (length(.sb)) normalizePath(dirname(sub("--file=", "", .sb[1])))',
          fixed = TRUE),
    "P4c KILLED: converting such a test onto the commandArgs idiom is caught")
chk(!grepl(COMMANDARGS_ROOT, 'source(here::here("R", "safe_divide.R"))', fixed = TRUE),
    "P4d a here::here() resolver is not an offender -- it is the fix, not the defect")

# The one part of the original finding that survived: a dependency loaded and
# never called is still dead. geocode_midwives.R loaded `here` and made no call.
HERE_CALL <- paste0("library(", "here)")
dead_here <- Filter(function(f) {
  txt <- slurp(f)
  grepl(HERE_CALL, txt, fixed = TRUE) &&
    !grepl("here::here(", txt, fixed = TRUE) &&
    # The paren is escaped. It was not, which is an invalid regex -- and the
    # `&&` above short-circuited past it for every file until the scan was
    # widened past the root scripts, so this condition had never once run.
    !grepl("[^:.a-zA-Z_]here\\(", txt)
}, tracked_r())
chk(!length(dead_here),
    sprintf("P4e no file loads `here` without calling it%s",
            if (length(dead_here)) paste0(" [", paste(basename(dead_here), collapse = ", "), "]") else ""))

cat(sprintf("\n%s (%d failure(s) across 4 over-engineering saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS", fails))
quit(status = if (fails == 0L) 0L else 1L)
