#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the /ponytail-audit cuts, so none of them grows back
# =============================================================================
# A deletion is not finished when the code is gone -- it is finished when the
# repository refuses to let it come back. Every finding below was found by a
# whole-tree scan nobody runs on a schedule, so each one gets a gate that does.
#
# WHAT EACH SABOTEUR PROTECTS, and why it is not merely a style rule:
#
#   A1-A3  Twenty-two tracked Python scripts were referenced by nothing at
#          all -- no code, no doc, no workflow, no string. Two of them were
#          duplicate ports of live code (artifact_provenance.py beside the
#          imported tools/provenance.py; match_ohio_voter_ages.py beside the
#          executable match_ohio_voter_ages.R). The contract is that a tracked
#          .py must be reachable SOME way: imported, documented, run by a
#          workflow, or collected by pytest.
#   A4-A5  CI ran pytest against two named FILES, so 107 of 134 Python tests
#          gated nothing while passing. A filename list cannot notice a new
#          test file; a directory can.
#   A6-A7  Fourteen files defined `%||%` identically to base R's, which has
#          shipped it since 4.4.0. Four others define it DIFFERENTLY and must
#          keep their local versions -- the saboteur has to tell those apart,
#          or "no local %||%" would be a rule that breaks working code.
#   A8-A9  flow_diagram.R had a `theme` parameter whose only alternative value
#          nothing ever passed, plus NULL-fallbacks that became unreachable
#          once the parameter went.
#   A10    assert_vintage_gap()'s side labels defaulted to "source A"/"source
#          B", naming neither the source nor the file.
#   A11    THE RETRACTION, pinned. The audit also claimed trilliant_identity's
#          `variant` was an abstraction with one implementation. It is not:
#          both variants are computed, ranked, decided and REPORTED as a
#          scientific comparison, and the callers pass the argument
#          POSITIONALLY, which is why a scan for `variant =` missed them. This
#          saboteur exists so the wrong finding cannot be "fixed" later.
# =============================================================================

.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
SAB_PREFIX <- "A"

tracked <- system2("git", "ls-files", stdout = TRUE)
# read_tracked, not read_if: compare_all_sources_mysteryroster.R
# defines read_if() at top level and ci_hygiene H4 refuses the same
# name in two tracked files. H4 reads `git ls-files`, so this
# collision was invisible until the file was staged -- which is the
# second time that has caught me in one session.
read_tracked <- function(p) if (file.exists(p)) paste(readLines(p, warn = FALSE),
                                                collapse = "\n") else ""
workflows <- paste(vapply(Sys.glob(".github/workflows/*.yml"), read_tracked,
                          character(1)), collapse = "\n")

sab(1, "every tracked Python file is reachable some way")
{
  py <- grep("[.]py$", tracked, value = TRUE)
  # EVERY TRACKED TEXT FILE, not just the code. The first draft scanned only
  # .R/.py/.qmd/.md/.yml and flagged eight live files -- three BON harvesters
  # named in config/state_source_audit_sources.csv, two named only in
  # .gitignore, and the artifact builder itself. A manifest entry IS a
  # reference, and so is a leak-guard exception.
  #
  # Counted against the file's OWN text rather than compared file by file:
  # one corpus pass instead of 72 x 1,300, and a name that appears only as
  # many times as the file itself contains it is a self-reference. useBytes
  # because a tracked file in this repository is not valid in the C locale,
  # and an encoding error must not masquerade as unreachability.
  textish <- grep("[.](png|jpg|jpeg|pdf|svg|zip|xlsx|duckdb|rds|gz|parquet)$",
                  tracked, value = TRUE, invert = TRUE)
  corpus <- paste(vapply(textish, read_tracked, character(1)), collapse = "\n")
  hits <- function(needle, haystack, fixed = TRUE) {
    m <- gregexpr(needle, haystack, fixed = fixed, useBytes = TRUE)[[1]]
    if (length(m) == 1L && m[1] == -1L) 0L else length(m)
  }
  unreachable <- character(0)
  for (f in py) {
    # Collected by pytest: tests/ is the pytest root, so tests/test_*.py runs
    # whether or not anything names it.
    if (startsWith(f, "tests/") && startsWith(basename(f), "test_")) next
    own <- read_tracked(f)
    base_name <- basename(f)
    elsewhere <- hits(base_name, corpus) - hits(base_name, own)
    if (elsewhere <= 0L) {
      module <- sub("[.]py$", "", base_name)
      rx <- sprintf("(^|[^A-Za-z0-9_])%s([^A-Za-z0-9_]|$)", module)
      elsewhere <- hits(rx, corpus, fixed = FALSE) - hits(rx, own, fixed = FALSE)
    }
    if (elsewhere <= 0L) unreachable <- c(unreachable, f)
  }
  chk(length(unreachable) == 0,
      sprintf("no tracked .py is referenced by nothing [%s]",
              if (length(unreachable)) paste(unreachable, collapse = ", ")
              else sprintf("all %d reachable", length(py))))
}

sab(2, "a cross-language twin has to say it is one")
{
  # match_ohio_voter_ages.py sat beside match_ohio_voter_ages.R for three
  # months with nothing stating the relationship. The R one is executable,
  # documented in README and asserted against its Florida twin by
  # tests/ci_science_laws.R; the .py was the superseded original.
  #
  # But a shared stem is NOT by itself a defect: tools/provenance.py and
  # R/lib/provenance.R are the same job in two languages because harvesters
  # are written in both, and address_keys exists twice so the two languages
  # can be shown to build the SAME join key. The rule is therefore not "no
  # twins" -- it is that one of the pair must name the other, so a reader
  # finding one cannot miss that the other exists and must agree with it.
  py <- grep("[.]py$", tracked, value = TRUE)
  r <- grep("[.]R$", tracked, value = TRUE)
  stems <- intersect(sub("[.]py$", "", basename(py)), sub("[.]R$", "", basename(r)))
  silent <- character(0)
  for (st in stems) {
    pf <- py[basename(py) == paste0(st, ".py")][1]
    rf <- r[basename(r) == paste0(st, ".R")][1]
    mutual <- grepl(basename(rf), read_tracked(pf), fixed = TRUE) ||
      grepl(basename(pf), read_tracked(rf), fixed = TRUE)
    if (!mutual) silent <- c(silent, sprintf("%s <-> %s", pf, rf))
  }
  chk(length(silent) == 0L,
      sprintf("every .py/.R twin names its counterpart [%s]",
              if (length(silent)) paste(silent, collapse = "; ") else "all do"))
}

sab(3, "one provenance writer per language, not two")
{
  py_prov <- grep("provenance[.]py$", tracked, value = TRUE)
  chk(length(py_prov) == 1L,
      sprintf("exactly one Python provenance module [%s]",
              paste(py_prov, collapse = ", ")))
  chk(identical(py_prov, "tools/provenance.py"),
      "and it is tools/provenance.py, the one 14 harvesters import")
}

sab(4, "CI points pytest at the DIRECTORY, not a list of filenames")
{
  # The defect: `pytest tests/test_scrape.py tests/test_fetch_npi_candidates.py`
  # ran 27 of 134 tests. Everything else passed and gated nothing.
  pytest_lines <- grep("pytest", strsplit(workflows, "\n")[[1]], value = TRUE)
  invocations <- grep("python -m pytest|python3 -m pytest", pytest_lines,
                      value = TRUE)
  chk(length(invocations) > 0L, "a workflow invokes pytest at all")
  named_files <- grep("pytest[^|&]*tests/[A-Za-z0-9_]+[.]py", invocations,
                      value = TRUE)
  chk(length(named_files) == 0L,
      sprintf("no pytest invocation names individual test files [%s]",
              if (length(named_files)) trimws(named_files[1]) else "none"))
  chk(any(grepl("pytest\\s+tests\\b", invocations)),
      "and one of them runs the whole tests directory")
}

sab(5, "INVERTED: every Python test file is still collectable")
{
  # Pointing pytest at a directory is only an improvement if the directory's
  # contents actually run. A file that fails to IMPORT makes pytest exit
  # non-zero for a reason unrelated to any assertion, which is how a broadened
  # gate gets narrowed again.
  py_tests <- grep("^tests/test_.*[.]py$", tracked, value = TRUE)
  chk(length(py_tests) >= 10L,
      sprintf("tests/ holds the Python suites [%d files]", length(py_tests)))
  bad <- py_tests[!vapply(py_tests, function(f) {
    out <- suppressWarnings(system2("python3", c("-m", "py_compile", f),
                                    stdout = TRUE, stderr = TRUE))
    is.null(attr(out, "status")) || attr(out, "status") == 0L
  }, logical(1))]
  chk(length(bad) == 0L,
      sprintf("and every one compiles [%s]",
              if (length(bad)) paste(bad, collapse = ", ") else "all"))
}

sab(6, "nothing redefines base R's %||%")
{
  # Base R has shipped %||% since 4.4.0 and CI runs r-version: release.
  chk(exists("%||%", where = baseenv()),
      sprintf("base R supplies %%||%% [R %s]", getRversion()))
  BASE_EQUIVALENT <- c(
    "function(a, b) if (is.null(a)) b else a",
    "function(x, y) if (is.null(x)) y else x",
    "function(lhs, rhs) if (is.null(lhs)) rhs else lhs")
  redundant <- character(0)
  for (f in grep("[.]R$", tracked, value = TRUE)) {
    for (ln in grep("`%\\|\\|%`\\s*<-", readLines(f, warn = FALSE),
                    value = TRUE)) {
      body <- trimws(sub(".*<-\\s*", "", ln))
      if (body %in% BASE_EQUIVALENT) redundant <- c(redundant, paste0(f, ": ", body))
    }
  }
  chk(length(redundant) == 0L,
      sprintf("no file redefines it with base's exact body [%s]",
              if (length(redundant)) redundant[1] else "none"))
}

sab(7, "INVERTED: a DIFFERENT %||% is still allowed to exist")
{
  # Four copies diverge on purpose -- one treats length-0 as null, one treats
  # NA as null, one returns a[1]. "No local %||%" would delete working code,
  # so A6 must key on the BODY and not the name. If this ever reports zero,
  # A6 has stopped being able to tell the two cases apart.
  divergent <- 0L
  for (f in grep("[.]R$", tracked, value = TRUE)) {
    for (ln in grep("`%\\|\\|%`\\s*<-", readLines(f, warn = FALSE), value = TRUE)) {
      body <- trimws(sub(".*<-\\s*", "", ln))
      if (!body %in% c("function(a, b) if (is.null(a)) b else a",
                       "function(x, y) if (is.null(x)) y else x",
                       "function(lhs, rhs) if (is.null(lhs)) rhs else lhs"))
        divergent <- divergent + 1L
    }
  }
  chk(divergent > 0L,
      sprintf("the body-aware check still permits divergent copies [%d present]",
              divergent))
}

sab(8, "the flow diagram has one theme, and no switch to select it")
{
  fd <- read_tracked("R/lib/flow_diagram.R")
  # The DEFINITION, not the name: flow_diagram.R's own docblock explains the
  # removal and names the function, and a saboteur that greps for the bare
  # name fails on the comment that documents its absence.
  chk(!grepl("fd_theme_journal\\s*<-\\s*function", fd),
      "fd_theme_journal() is no longer defined, not merely unused")
  chk(!grepl("theme\\s*=\\s*NULL", fd),
      "and no function still takes a theme = NULL parameter")
  chk(grepl("fd_theme_default <- function", fd, fixed = TRUE),
      "while the one palette that is used remains")
}

sab(9, "the single theme supplies every field the renderer reads unguarded")
{
  # Removing `theme` made three NULL-fallbacks unreachable, so they went too.
  # That is only safe while fd_theme_default() actually sets all three; if a
  # field is dropped from the palette, pal$corner becomes NULL and grid draws
  # with a NULL radius instead of falling back.
  source(file.path(root, "R", "lib", "flow_diagram.R"))
  pal <- fd_theme_default()
  needed <- c("ink", "muted", "rule", "accent", "soft", "paper",
              "corner", "reverse_lead", "dashed_drop")
  absent <- needed[!needed %in% names(pal)]
  chk(length(absent) == 0L,
      sprintf("fd_theme_default() sets every field [%s]",
              if (length(absent)) paste(absent, collapse = ", ") else "all 9"))
  nulls <- needed[vapply(needed, function(k) is.null(pal[[k]]), logical(1))]
  chk(length(nulls) == 0L,
      sprintf("and none of them is NULL [%s]",
              if (length(nulls)) paste(nulls, collapse = ", ") else "none"))
}

sab(10, "a vintage refusal has to name both sides")
{
  source(file.path(root, "R", "lib", "source_vintage.R"))
  unnamed <- tryCatch({
    assert_vintage_gap(as.Date("2019-07-01"), as.Date("2026-07-01"), 6)
    "ACCEPTED"
  }, error = function(e) conditionMessage(e))
  chk(grepl("what_a", unnamed, fixed = TRUE),
      "calling it without naming side A fails rather than printing 'source A'")
  named <- tryCatch(assert_vintage_gap(as.Date("2019-07-01"),
                                       as.Date("2026-07-01"), 6,
                                       "pecos 2019", "nppes 2026"),
                    error = function(e) conditionMessage(e))
  chk(grepl("pecos 2019", named, fixed = TRUE) &&
        grepl("nppes 2026", named, fixed = TRUE),
      "and a named call puts both names in the refusal")
}

sab(11, "INVERTED: the identity scorer's two variants are BOTH real")
{
  # THE AUDIT GOT THIS ONE WRONG. It reported `variant` as an abstraction with
  # one implementation because no caller passed `variant =` by name. The
  # callers pass it POSITIONALLY -- trl_rank_candidates(scored,
  # "identity_only") -- and both variants are scored, ranked, decided and
  # reported against each other. This saboteur fails if someone "simplifies"
  # the second variant away, and it is here because a wrong finding that was
  # merely retracted in prose would be rediscovered and acted on.
  source(file.path(root, "R", "lib", "trilliant_identity.R"))
  variants <- names(formals(trl_rank_candidates)$variant)
  arg <- eval(formals(trl_rank_candidates)$variant)
  chk(identical(arg, c("full", "identity_only")),
      sprintf("trl_rank_candidates() still offers both variants [%s]",
              paste(arg, collapse = ", ")))
  chk(all(c("full", "identity_only") %in% names(TRL_DECISION_RULES)),
      "and TRL_DECISION_RULES carries thresholds for each")
  caller <- read_tracked("experiment_trilliant_identity_linkage.R")
  chk(grepl('"identity_only"', caller, fixed = TRUE),
      "and a production script still asks for the identity_only variant")
}

saboteur_report(11)
