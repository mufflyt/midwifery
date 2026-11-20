#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-20 complexity-audit fixes
# =============================================================================
# The audit (Review_AI_complexity.qmd, ropensci-skills `run-complexity`) made
# four cuts. Each is the kind a later edit undoes by doing the convenient
# thing -- copy a wrapper back from the upstream copy, "tidy away" a parameter
# that looks redundant, put a scanner next to the thing it scans, write a
# second tree walker because the first one is in another file. None of those
# would fail anything on its own, so each gets a gate that mutates itself to
# prove it bites.
#
#   C1 THE THREE UNUSED JOIN WRAPPERS STAY DELETED, AND THE USED ONE STAYS
#      REACHABLE. safe_inner_join(), safe_semi_join() and safe_anti_join() had
#      zero production call sites -- tests only -- and were one function
#      written four times (semi vs anti: 0.78 structural similarity).
#      assert_unique_keys() moved to its own file because 17 scripts were
#      sourcing all 1,892 lines of R/join_safety.R to reach those 69.
#   C2 THE UNREACHABLE DELEGATION IS GONE AND THE REFUSAL IS NOT. 54 lines
#      delegated to safe_left_join_with_metrics() and log_join_integrity(),
#      neither of which is defined anywhere here. The PARAMETER stays: the
#      upstream copy at ~/isochrones/R/join_safety.R defaults it to TRUE and
#      does have the metrics module, which is why six call sites pass FALSE.
#   C3 THE CI-ONLY SCANNER STAYS OUT OF THE PIPELINE LIBRARY.
#      duckdb_scan_for_raw_connections() (cyclomatic complexity 98, the worst
#      function in the pipeline's source closure) has no production caller and
#      sat in a file 30-odd scripts source.
#   C4 ONE CALL-TREE WALKER. Two were written independently, both reachable
#      from the same pipeline script, each with its own paragraph about R's
#      empty symbol.
#
# SCOPED TO WHAT WAS ACTUALLY CUT. C4 covers the two walkers the audit named,
# not every tree walk in the tree: regex_literals() in
# tests/test_gate_integrity_saboteurs.R walks a parse tree too, but it visits
# call HEADS as well as arguments, and Q1's scan set is calibrated to that
# traversal. Converting it would change what that gate reads, which is a
# decision about Q1 and not a duplicate to remove. The same reasoning P1 used
# when it declined to police 33 files under a different root idiom.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "C"

ALL_R <- tracked_r()
# The repository's own walker does the code-shaped scanning below. A grep for
# `name(` cannot tell a call from the same name inside a string, and this
# suite's first run proved it: C2a accused R/join_safety.R because the error
# message it now raises NAMES the function it refuses to call.
source(file.path(root, "R", "lib", "ast_walk.R"))

noncomment <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  lines[!grepl("^\\s*#", lines)]
}
#' Files whose text satisfies a predicate
#' @param pred [function] character(1) file text -> logical(1).
#' @return [character] repository-relative paths.
files_where <- function(pred) Filter(function(f) isTRUE(pred(slurp(f))), ALL_R)

#' Every function name actually CALLED in some R code
#'
#' Parsed, not grepped: a name inside a string literal is not a call, and a
#' name in a comment is not even a token. Returns `NA_character_` when the
#' text does not parse, so an unreadable file reports as unknown rather than
#' as clean -- C0b asserts there are none.
#' @param txt [character(1)] R source.
#' @return [character] callee names, `"pkg::fn"` for namespaced calls.
called_names <- function(txt) {
  ex <- tryCatch(parse(text = txt), error = function(e) NULL)
  if (is.null(ex)) return(NA_character_)
  out <- character(0)
  for (e in as.list(ex)) walk_call_tree(e, function(node) {
    fn <- node[[1L]]
    nm <- if (is.name(fn)) as.character(fn)
          else if (is.call(fn) && length(fn) == 3L &&
                   identical(fn[[1L]], as.symbol("::")))
            paste0(as.character(fn[[2L]]), "::", as.character(fn[[3L]]))
          else NA_character_
    if (!is.na(nm)) out <<- c(out, nm)
  })
  unique(out)
}

# Every scan below reads this list, so an empty one would make all of them
# report a clean tree. Shape 3 of docs/APPENDIX_checks_that_cannot_fail.
chk(length(ALL_R) > 500L,
    sprintf("C0 the scans read the whole tree (%d tracked .R files), so a clean result means clean and not empty",
            length(ALL_R)))
unparseable <- files_where(function(t) identical(called_names(t), NA_character_))
chk(!length(unparseable),
    sprintf("C0b every one of them parses, so the call scans below read code rather than skipping it%s",
            if (length(unparseable)) paste0(" [", paste(basename(unparseable), collapse = ", "), "]") else ""))

# --- C1 the deleted join wrappers stay deleted --------------------------------
sab(1, "three join wrappers with no caller stay deleted, and the one with callers stays reachable")
# Assembled, not spelled: C1b reads every tracked .R file including this one,
# and a definition written out in full would make this suite its own offender.
GONE <- paste0("safe_", c("inner", "semi", "anti"), "_join")

#' Top-level definitions of the deleted wrappers
#'
#' LINE-ANCHORED. A substring test would match this suite's own header, the
#' NEWS entry quoted in a comment, and the roxygen note in R/join_safety.R
#' that tells a reader where the wrappers went -- none of which is a
#' definition. Shape 2: when the subject is code, anchor it.
defines_gone <- function(txt) {
  lines <- noncomment(txt)
  unlist(lapply(GONE, function(nm)
    grep(sprintf("^%s\\s*(<-|=)\\s*function", nm), lines, value = TRUE)))
}
#' Call sites of the deleted wrappers
#'
#' A call with no definition is the worse failure of the two: it fails at run
#' time, in a script, on data.
calls_gone <- function(txt) intersect(called_names(txt), GONE)
redefined <- files_where(function(t) length(defines_gone(t)) > 0L)
chk(!length(redefined),
    sprintf("C1a no tracked file redefines a join wrapper the audit deleted for having no caller%s",
            if (length(redefined)) paste0(" [", paste(basename(redefined), collapse = ", "), "]") else ""))
recalled <- files_where(function(t) length(calls_gone(t)) > 0L)
chk(!length(recalled),
    sprintf("C1b nothing calls one either -- a call with no definition fails at run time, on data%s",
            if (length(recalled)) paste0(" [", paste(basename(recalled), collapse = ", "), "]") else ""))
chk(length(defines_gone(paste0(GONE[1], " <- function(left, right, by) left"))) == 1L,
    "C1c KILLED: a wrapper copied back from the upstream copy is caught")
chk(length(calls_gone(sprintf("out <- %s(a, b, by = 'npi')", GONE[2]))) == 1L,
    "C1d KILLED: a restored call site is caught")
chk(length(defines_gone(sprintf("#' %s() moved upstream; see ~/isochrones", GONE[3]))) == 0L &&
      length(calls_gone(sprintf("# %s() was deleted on 2026-11-20", GONE[3]))) == 0L,
    "C1e a comment naming a deleted wrapper is neither a definition nor a call -- this file's own header is one")

# The 69 lines those 17 scripts were really after, defined once and reachable
# both ways: directly, and through the module that used to hold it.
AUK <- "assert_unique_keys"
auk_defs <- files_where(function(t)
  any(grepl(sprintf("^%s\\s*(<-|=)\\s*function", AUK), noncomment(t))))
chk(identical(auk_defs, "R/assert_unique_keys.R"),
    sprintf("C1f assert_unique_keys() is defined exactly once, in its own file [%s]",
            paste(auk_defs, collapse = ", ")))
chk(any(grepl('source\\(file\\.path\\("R", "assert_unique_keys\\.R"\\)\\)',
              noncomment(slurp("check_npi_deactivation.R")))) &&
      !any(grepl("join_safety", noncomment(slurp("check_npi_deactivation.R")))),
    "C1g pipeline stage 5 sources the 69 lines it uses, not the 2,195 it used to")
chk(any(grepl('source\\(here::here\\("R", "assert_unique_keys\\.R"\\)\\)',
              noncomment(slurp("R/join_safety.R")))),
    "C1h ... and R/join_safety.R still reaches it, so the other 16 callers keep working unchanged")

# --- C2 the dead branch is gone, the refusal is not ----------------------------
sab(2, "an unreachable delegation is deleted without deleting the refusal it guarded")
PHANTOMS <- c(paste0("safe_left_join_", "with_metrics"), paste0("log_join_", "integrity"))
calls_phantom <- function(txt) intersect(called_names(txt), PHANTOMS)
phantom_callers <- files_where(function(t) length(calls_phantom(t)) > 0L)
chk(!length(phantom_callers),
    sprintf("C2a nothing calls a function no file in this repository defines%s",
            if (length(phantom_callers)) paste0(" [", paste(basename(phantom_callers), collapse = ", "), "]") else ""))
chk(length(calls_phantom(sprintf("result <- %s(left = left, right = right)", PHANTOMS[1]))) == 1L,
    "C2b KILLED: the delegation, restored, is caught")
chk(length(calls_phantom(sprintf("#' delegates to %s() when enhanced", PHANTOMS[1]))) == 0L,
    "C2c a docstring naming it is not a call -- R/join_safety.R documents why it refuses")
# THE ARGUMENT IS LOAD-BEARING. R/01-build-county-base.R's load_join_safety()
# sources the vendored copy OR ~/isochrones/R/join_safety.R, and upstream
# defaults use_enhanced_metrics to TRUE with R/join_metrics.R present. Strip
# the argument from these call sites and the upstream load path silently turns
# the enhanced path on; strip it from the signature and every one of them
# becomes an "unused argument" error. The audit's first draft recommended
# exactly that, on the evidence of the vendored copy alone.
county_base <- noncomment(slurp("R/01-build-county-base.R"))
left_join_sites <- grep("safe_left_join\\(", county_base, value = TRUE)
enhanced_args <- grep("use_enhanced_metrics\\s*=\\s*FALSE", county_base, value = TRUE)
chk(length(left_join_sites) >= 6L && length(enhanced_args) >= 6L,
    sprintf("C2d the county-base call sites still pin use_enhanced_metrics (%d calls, %d pins) -- upstream defaults it to TRUE",
            length(left_join_sites), length(enhanced_args)))

# AT RUN TIME, because no text scan can prove a stop() still fires. Sourcing
# the module is also what makes this suite worth following in
# tests/ci_repo_integrity.R's package closure: it needs checkmate and dplyr.
suppressPackageStartupMessages(library(dplyr))
suppressMessages(source(file.path(root, "R", "join_safety.R")))
try_join <- function(...) tryCatch(suppressMessages(safe_left_join(...)),
                                   error = function(e) structure(conditionMessage(e), class = "refusal"))
JL <- data.frame(k = c("a", "b"), x = 1:2, stringsAsFactors = FALSE)
JR <- data.frame(k = c("a", "b"), y = 3:4, stringsAsFactors = FALSE)
asked <- try_join(JL, JR, by = "k", use_enhanced_metrics = TRUE, write_report = FALSE)
chk(refused(asked) && grepl("join_metrics", asked, fixed = TRUE),
    "C2e the refusal still fires when enhanced metrics are REQUESTED, and still names the module that is absent")
pinned <- try_join(JL, JR, by = "k", use_enhanced_metrics = FALSE, write_report = FALSE)
chk(!refused(pinned) && nrow(pinned) == 2L,
    "C2f ... and the argument those six call sites pass is still accepted -- without it in the signature, every one of them is an \"unused argument\" error")

# --- C3 the CI-only scanner stays with the gates --------------------------------
sab(3, "a scanner with no production caller stays out of a library 30 scripts source")
SCAN_FN <- paste0("duckdb_scan_for_", "raw_connections")
REGISTRY <- paste0("DUCKDB_RAW_CONNECTION_", "EXCEPTIONS")
defines_scanner <- function(txt)
  any(grepl(sprintf("^%s\\s*(<-|=)\\s*function", SCAN_FN), noncomment(txt)))
scanner_homes <- files_where(defines_scanner)
chk(identical(scanner_homes, "tests/duckdb_architecture_scan.R"),
    sprintf("C3a the raw-connection scanner is defined exactly once, beside the gates that are its only callers [%s]",
            paste(scanner_homes, collapse = ", ")))
lib_txt <- noncomment(slurp("R/lib/medicare_duckdb.R"))
chk(!defines_scanner(slurp("R/lib/medicare_duckdb.R")) &&
      !any(grepl(sprintf("^%s\\s*(<-|=)", REGISTRY), lib_txt)),
    "C3b the pipeline's DuckDB library defines neither the scanner nor its exception registry")
GATES <- c("tests/ci_duckdb_architecture_gate.R", "tests/ci_duckdb_exception_provenance.R",
           "tests/ci_duckdb_ingestion_bootstrap.R", "tests/ci_duckdb_mutation_tests.R")
unwired <- Filter(function(g) !any(grepl('duckdb_architecture_scan\\.R', noncomment(slurp(g)))), GATES)
chk(!length(unwired),
    sprintf("C3c every gate that calls the scanner sources it%s",
            if (length(unwired)) paste0(" [", paste(basename(unwired), collapse = ", "), "]") else ""))

# AND IT STILL BITES. Moving a 156-line scanner is the kind of change that
# passes every text check and scans nothing. Written to tempdir(), never the
# repository: the gates scan every tracked file, and a fixture tracked here
# would be a real unregistered raw connection.
source(file.path(root, "tests", "duckdb_architecture_scan.R"))
fixture <- function(lines) {
  p <- tempfile(fileext = ".R"); writeLines(lines, p); p
}
raw_site <- fixture(c("library(DBI)", paste0("con <- dbConnect(duckdb::", "duckdb(), ':memory:')")))
hit <- duckdb_scan_for_raw_connections(raw_site)
chk(is.data.frame(hit) && nrow(hit) >= 1L &&
      all(c("file", "line", "tag", "symbol") %in% names(hit)),
    sprintf("C3d KILLED: the moved scanner still finds a raw connection and still returns file/line/tag/symbol (%d row(s))",
            if (is.data.frame(hit)) nrow(hit) else 0L))
routed <- fixture(c("source('R/lib/medicare_duckdb.R')", "con <- duckdb_connect(':memory:')"))
chk(is.null(duckdb_scan_for_raw_connections(routed)) ||
      nrow(duckdb_scan_for_raw_connections(routed)) == 0L,
    "C3e a file routing through duckdb_connect() is not flagged -- the chokepoint is the point, not the word duckdb")

# AND IT IS NOT NAMED helper-*. `testthat::test_file()` auto-sources every
# tests/helper-*.R, from the tests directory, so a shared library under that
# name is sourced into all ten test_file()-invoked suites in ci.yml -- and any
# path it resolves from the working directory lands in tests/. This file spent
# an hour as tests/helper-duckdb-scan.R and broke all ten on
# `tests/R/lib/ast_walk.R`. The gate is narrow on purpose: sourcing a
# working-directory-relative path from an auto-sourced file, not every root
# idiom in tests/ (tests/helper-saboteur.R resolves a root it never uses under
# test_file(), which is latent, not broken, and rewriting it is a decision
# about that harness).
wd_relative_source <- function(txt) {
  lines <- noncomment(txt)
  grep('source\\s*\\(\\s*(file\\.path\\(\\s*)?"[^/"]+[/"]', lines, value = TRUE)
}
auto_sourced <- tracked("tests/helper-*.R")
coupled <- Filter(function(f) length(wd_relative_source(slurp(f))) > 0L, auto_sourced)
chk(length(auto_sourced) > 0L && !length(coupled),
    sprintf("C3f no auto-sourced tests/helper-*.R (%d of them) sources a working-directory-relative path, which testthat resolves from tests/%s",
            length(auto_sourced),
            if (length(coupled)) paste0(" [", paste(basename(coupled), collapse = ", "), "]") else ""))
chk(length(wd_relative_source('source(file.path("R", "lib", "ast_walk.R"))')) == 1L,
    "C3g KILLED: the relative source() that broke all ten test_file() suites is caught")
chk(length(wd_relative_source('source(file.path(root, "R", "lib", "ast_walk.R"))')) == 0L &&
      length(wd_relative_source('source(here::here("R", "lib", "ast_walk.R"))')) == 0L,
    "C3h a root-anchored or here::here() source is not an offender -- those are the two forms that work from either directory")

# --- C4 one call-tree walker -----------------------------------------------------
sab(4, "the two tree walkers that were the same walker are one")
WALKER <- "walk_call_tree"
walker_homes <- files_where(function(t)
  any(grepl(sprintf("^%s\\s*(<-|=)\\s*function", WALKER), noncomment(t))))
chk(identical(walker_homes, "R/lib/ast_walk.R"),
    sprintf("C4a the shared walker is defined exactly once [%s]", paste(walker_homes, collapse = ", ")))
LOCAL_WALKERS <- paste0("walk", c("_calls", ""))
consumers <- c("R/lib/artifact_provenance.R", "tests/duckdb_architecture_scan.R")
relapsed <- Filter(function(f) {
  lines <- noncomment(slurp(f))
  any(unlist(lapply(LOCAL_WALKERS, function(nm)
    grepl(sprintf("^\\s+%s\\s*(<-|=)\\s*function", nm), lines))))
}, consumers)
chk(!length(relapsed),
    sprintf("C4b neither consumer carries a local walker any more%s",
            if (length(relapsed)) paste0(" [", paste(basename(relapsed), collapse = ", "), "]") else ""))
chk(all(vapply(consumers, function(f) any(grepl(WALKER, noncomment(slurp(f)))), logical(1))),
    "C4c both consumers call the shared walker")

# THE GUARD IS LOAD-BEARING, NOT DECORATION. Both originals carried a
# paragraph about R's empty symbol -- the blank in `df[, "col"]` -- because a
# walker without that guard dies on it. A naive walker beside the real one
# shows the difference rather than asserting it.
source(file.path(root, "R", "lib", "ast_walk.R"))
subject <- quote(f(g(1), df[, "col"], function(x = 2) h(x)))
seen <- character(0)
walk_call_tree(subject, function(n) seen <<- c(seen, deparse(n[[1]])[1]))
chk(all(c("f", "g", "h") %in% seen),
    sprintf("C4d the shared walker reaches a call nested in an argument and inside a function body [%s]",
            paste(seen, collapse = " ")))
# THE FOR-EACH BINDING IS THE FORM THAT DIES, and it is the one both
# originals' comments describe: "even a `for` loop's own element-binding step
# can raise 'argument is missing' before any check in the loop body runs".
# Indexing with `[[` survives the same input, which is why the shared walker
# indexes and compares a one-element SUBLIST instead of binding -- stated here
# because a guard whose necessity is not reproducible invites its own removal.
naive_bind <- function(node) {
  if (!is.call(node)) return(invisible(NULL))
  for (el in as.list(node)[-1L]) naive_bind(el)
  invisible(NULL)
}
chk(inherits(tryCatch(naive_bind(subject),
                      error = function(e) structure(conditionMessage(e), class = "refusal")),
             "refusal"),
    "C4e KILLED: the same walk written with a for-each binding and no guard dies on the same input -- which is why both originals had one")

saboteur_report(4)
