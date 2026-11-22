#!/usr/bin/env Rscript
# =============================================================================
# Repo hygiene: things that were true defects here, checked mechanically
# =============================================================================
# Every check below exists because the thing it forbids actually happened and
# cost real time. None of them read data, so this runs in CI in seconds.
#
#   H1  Every tracked .R file parses. A syntax error in a script nobody ran
#       this week is invisible until the day you need it -- an apostrophe
#       inside a single-quoted sprintf() broke the map render exactly that way.
#   H2  No absolute path into another account's home. Six CABC parsers read
#       /Users/tmuffly/.gemini/... and none of them could run on this machine,
#       so the committed provenance for two artifacts pointed at nothing.
#   H3  No duplicate .gitignore entries.
#   H5  No file:/// or absolute-path link in tracked markdown. H2 scans R and
#       Python, so an absolute link in DOCUMENTATION went unseen -- and that is
#       where it does most damage, because a reader clicks it.
#   H4  No function defined at top level in more than one tracked .R file.
#       norm_addr existed four times with divergent behaviour, zip5 three,
#       and a test shadowed the canonical pad5. Two scripts keying the same
#       address produced different keys with nothing saying so.
#   H6  No name bound to a function more than once WITHIN ONE SCOPE. H4 reads
#       top-level definitions across files; this reads every scope, which is
#       where the same defect hides. mw_build_catalog() bound `g` three times
#       in one 913-line function body -- and because `if (...) { }` is not a
#       scope in R, all three landed in the one environment. Two of the three
#       took the same arity with incompatible first-argument types (a data
#       frame at one binding, a character stratum key at the next), 41 lines
#       apart, in the function that produces every number in the manuscript.
#       Nothing was wrong at the time: every call sat inside its own
#       `if (!is.null(x))` block. That is the point -- the next edit to move a
#       statement across a block boundary would have been silent.
#
#   H6  No name bound to a function more than once WITHIN ONE SCOPE. H4 reads
#       top-level definitions across files; this reads every scope, which is
#       where the same defect hides. mw_build_catalog() bound `g` three times
#       in one 913-line function body -- and because `if (...) { }` is not a
#       scope in R, all three landed in the one environment. Two of the three
#       took the same arity with incompatible first-argument types (a data
#       frame at one binding, a character stratum key at the next), 41 lines
#       apart, in the function that produces every number in the manuscript.
#       Nothing was wrong at the time: every call sat inside its own
#       `if (!is.null(x))` block. That is the point -- the next edit to move a
#       statement across a block boundary would have been silent.
#
# H4 carries an allowlist. Some repeats are legitimate -- a test's local `chk`
# harness, or a genuinely private one-liner -- and an allowlist that must be
# edited deliberately is the point: adding a name here is a decision someone
# makes on purpose, not a check quietly weakening.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

tracked <- system2("git", c("ls-files"), stdout = TRUE)
r_files <- grep("[.]R$", tracked, value = TRUE)
fails <- 0L
note <- function(ok, msg, detail = character(0)) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else {
    fails <<- fails + 1L
    cat(sprintf("  FAIL %s\n", msg))
    for (d in utils::head(detail, 20)) cat("         ", d, "\n", sep = "")
    if (length(detail) > 20)
      cat(sprintf("          ... and %d more\n", length(detail) - 20))
  }
}

cat("\n-- H1 every tracked R file parses --\n")
bad <- character(0)
for (f in r_files) {
  e <- tryCatch({ parse(f); NULL }, error = function(e) conditionMessage(e))
  if (!is.null(e)) bad <- c(bad, sprintf("%s: %s", f, sub("\n.*", "", e)))
}
note(length(bad) == 0, sprintf("%d R files parse", length(r_files)), bad)

cat("\n-- H2 no absolute path into a foreign home directory --\n")
# This machine's own home is fine; another account's is not, and neither is a
# path under a tool's scratch directory that no clone will ever have.
hits <- character(0)
for (f in c(r_files, grep("[.]py$", tracked, value = TRUE))) {
  ln <- readLines(f, warn = FALSE)
  i <- grep('"/Users/(?!tylermuffly)[A-Za-z0-9._-]+/', ln, perl = TRUE)
  if (length(i)) hits <- c(hits, sprintf("%s:%d", f, i))
}
note(length(hits) == 0, "no hardcoded path into another user's home", hits)

cat("\n-- H5 no absolute filesystem link in tracked documentation --\n")
# H2 above scans R and Python, so an absolute path in a MARKDOWN link went
# unseen -- and documentation is where such a link does the most damage,
# because a reader clicks it. Two cases, both broken for everyone but the
# machine that wrote them:
#   file:///...            resolves on one filesystem and nowhere else, even
#                          when the home directory happens to be this one.
#                          Three slashes: `git clone file://$(pwd)` in a
#                          documented shell command is a relative URL and fine.
#   ](/Users/... or ](/Volumes/...   an absolute link target.
# Found by #232: the hospital-linkage appendix carried three file:/// links,
# and the panel appendix one into an account (/Users/tmuffly) that does not
# exist on the machine holding the freeze. Repo-relative links (../artifacts/x)
# work in the rendered site, on GitHub, and in an editor.
md_files <- grep("[.]md$", tracked, value = TRUE)
md_hits <- character(0)
for (f in md_files) {
  ln <- readLines(f, warn = FALSE)
  i <- grep("file:///|\\]\\((/Users/|/Volumes/)", ln, perl = TRUE)
  if (length(i)) md_hits <- c(md_hits, sprintf("%s:%d: %s", f, i, trimws(substr(ln[i], 1, 100))))
}
note(length(md_hits) == 0, "no file:/// or absolute-path link in tracked markdown", md_hits)

cat("\n-- H3 .gitignore has no duplicate entries --\n")
gi <- readLines(".gitignore", warn = FALSE)
gi <- trimws(gi[nzchar(trimws(gi)) & !grepl("^#", trimws(gi))])
dup <- unique(gi[duplicated(gi)])
note(length(dup) == 0, "no duplicated ignore rules", dup)

cat("\n-- H4 no function defined at top level in two files --\n")
# Allowlisted repeats. Each is a private helper whose duplication is harmless
# because it is never a JOIN KEY or a normalisation -- the two categories where
# divergence silently changes results.
# `ok`, `bad`, `chk` and `skip` are the four members of the standalone-test
# harness this repository writes over and over: print a pass, count a failure,
# assert, note a skip. `ok` and `chk` were already listed -- and are the most
# duplicated names in the tree, 8 files and 49 files respectively -- so listing
# the other two completes a set rather than opening a new hole. All four are
# console output. None is a join key or a normalisation, which is the line H4
# actually polices.
# `kills` is the mutation-harness verb -- plant a defect, require the gate to
# die on it -- and it now appears in two harnesses with a third and fourth
# coming as more laws are registered. Same category as ok/bad/chk/skip above:
# console plumbing around a subprocess, never a join key or a normalisation.
# Its partner `survives` is not listed because it is not yet duplicated; add it
# when it is, deliberately, rather than in anticipation.
# `raises` and `err_msg` are the same category again: run an expression, say
# whether/how it failed, used only inside standalone test files. `mk_cand` is
# a synthetic test-fixture row builder (two independent test files each build
# their own candidate rows for their own scenarios) -- not a join key or a
# normalisation either, since it never touches real data.
# 2026-11-16: as_lgl, disagree, drop_zip, error, nonascii and sel removed --
# none is duplicated any more, and an allowlist entry for a name that no longer
# repeats is a hole kept open for nothing. drop_zip in particular was listed as
# "never a join key", which was wrong: it exists to build key_nozip, so it now
# lives once in R/lib/geocode_conflicts.R with the collapse that follows it.
# `scaffold` and `gate_fails` are the gate-of-gates pair -- build a throwaway
# git repo that passes, then run the gate in it as a subprocess and report
# whether it exited non-zero. Same category as `kills` directly above: console
# and subprocess plumbing in a standalone harness, never a join key and never
# touching real data. They became duplicated when ci_denominator_contracts.R
# got the detector that ci_science_contracts.R already had, and divergence
# between the two is harmless by construction -- each builds the fixtures its
# own gate reads, so a shared definition would be the wrong thing.
ALLOW <- c("chk", "xchk", "pick", "f", "ok", "bad", "skip", "kills",
           "scaffold", "gate_fails",
           "rd", "fmt", "mk",
           "main", "code", "rate", "key_of", "fetch_one",
           "assign_cd", "centroid_counts", "assign_county_from_points",
           "raises", "err_msg", "mk_cand")
defs <- list()
for (f in r_files) {
  ln <- readLines(f, warn = FALSE)
  m <- regmatches(ln, regexpr("^[.A-Za-z_][A-Za-z0-9_.]*(?= *<- *function)", ln,
                              perl = TRUE))
  for (nm in unique(m)) defs[[nm]] <- unique(c(defs[[nm]], f))
}
multi <- Filter(function(v) length(v) > 1, defs)
multi <- multi[!names(multi) %in% ALLOW]

# BASELINE. Nine duplicates already existed when this check was written, all in
# the license-resolution work, which was under active development at the time.
# Refactoring live code to make a new lint pass is how a lint gets reverted, so
# they are grandfathered: the check fails on anything NEW or on an existing
# duplicate that SPREADS to another file, and reports the rest as debt.
#
# This file should only ever shrink. Deleting a line is the fix; adding one is a
# decision to accept a duplicated definition, and needs the same justification
# any other duplication would.
BASE <- "tests/ci_hygiene_baseline.txt"
baseline <- if (file.exists(BASE)) {
  b <- readLines(BASE, warn = FALSE)
  b <- trimws(b[nzchar(trimws(b)) & !grepl("^#", trimws(b))])
  stats::setNames(lapply(strsplit(b, "\\s*:\\s*"), function(p)
    sort(trimws(strsplit(p[2], ",")[[1]]))),
    vapply(strsplit(b, "\\s*:\\s*"), `[`, character(1), 1))
} else list()

known <- new <- character(0)
for (n in names(multi)) {
  line <- sprintf("%s defined in %d files: %s", n, length(multi[[n]]),
                  paste(multi[[n]], collapse = ", "))
  if (!is.null(baseline[[n]]) && identical(sort(multi[[n]]), baseline[[n]]))
    known <- c(known, line) else new <- c(new, line)
}
note(length(new) == 0,
     sprintf("no NEW duplicate definitions (%d grandfathered in %s)",
             length(known), BASE), new)
if (length(known))
  cat(sprintf("       note: %d known duplicate%s still outstanding; see %s\n",
              length(known), if (length(known) == 1L) "" else "s", BASE))

# A baseline entry that no longer duplicates is debt that was PAID. Say so, so
# the file gets trimmed instead of quietly outliving the problem.
stale <- setdiff(names(baseline), names(multi))
if (length(stale))
  cat(sprintf("       note: %s no longer duplicated -- remove from %s\n",
              paste(stale, collapse = ", "), BASE))

cat("\n-- H6 no name bound to a function twice in one scope --\n")
# Only a function body and local() open a scope in R. `if`, `for`, `while` and
# a bare `{` DO NOT, so a helper defined inside an if-block belongs to the
# enclosing function's environment and a second binding of that name silently
# replaces the first for every statement after it. H4 cannot see this: its
# pattern is anchored at ^, so it reads top-level definitions only.
#
# Scopes are numbered as the walk descends. A file's top level is ONE scope
# (the script's evaluation environment), not one per expression.
H6_SID <- 0L
H6_SWALLOWED <- 0L
h6_is_fn_assign <- function(e)
  is.call(e) && length(e) == 3L && deparse(e[[1]])[1] %in% c("<-", "=", "<<-") &&
    is.call(e[[3]]) && deparse(e[[3]][[1]])[1] == "function"
h6_opens_scope <- function(e)
  is.call(e) && length(e) >= 1L && deparse(e[[1]])[1] %in% c("function", "local")
# Every child step is wrapped: R carries a special EMPTY SYMBOL for an omitted
# argument (the blank in `df[, "col"]`), and merely binding it to a variable
# raises "argument is missing" before any check in the loop body can run.
h6_walk <- function(e, sid) {
  out <- list()
  if (!is.recursive(e)) return(out)
  if (h6_is_fn_assign(e)) out <- list(data.frame(sid = sid, nm = deparse(e[[2]])[1]))
  for (i in seq_along(e)) {
    out <- tryCatch({
      x <- e[[i]]
      if (!is.recursive(x)) out else {
        s2 <- if (h6_opens_scope(x)) { H6_SID <<- H6_SID + 1L; H6_SID } else sid
        c(out, h6_walk(x, s2))
      }
    }, error = function(z) {
      # Swallowing the empty symbol is intended. Swallowing anything ELSE means
      # a subtree went unwalked, so this check silently covered less of the tree
      # than it claims -- the same blind spot this review flagged in
      # duckdb_scan_for_raw_connections()'s walker. Tell the two apart and COUNT
      # the other one, so a known limit never becomes a silent one.
      if (!grepl("argument .* is missing", conditionMessage(z)))
        H6_SWALLOWED <<- H6_SWALLOWED + 1L
      out
    })
  }
  out
}

# ALLOWLISTED, keyed on file AND name so it stays narrow: a NEW rebinding in
# one of these same files still fails. All three are test files that use a
# top-level `{ ... }` block per scenario and rebind a scenario helper in the
# next block. Each is harmless TODAY only because every assertion using a
# binding precedes the next one -- `disagree` in particular goes from
# (a, b) vectorised to (d) taking a data frame, which is the same shape as the
# catalog defect this check was written for. The fix when one of these files is
# next touched is `local({ ... })` per block, which makes the convention a
# guarantee and lets the entry here be deleted. This list should only shrink.
H6_ALLOW <- c("tests/test-step2-npi-dedup-bug.R::npi_valid",
              "tests/test_amcb_gates.R::passthrough",
              "tests/test_cycle19_address_provenance.R::disagree")

h6_hits <- character(0)
for (f in r_files) {
  ex <- tryCatch(parse(f, keep.source = FALSE), error = function(e) NULL)
  if (is.null(ex)) next
  H6_SID <- H6_SID + 1L
  top <- H6_SID
  rows <- list()
  for (e in ex) rows <- c(rows, h6_walk(e, top))
  if (!length(rows)) next
  d <- do.call(rbind, rows)
  for (s in unique(d$sid)) {
    tb <- table(d$nm[d$sid == s])
    tb <- tb[tb > 1L]
    for (nm in names(tb)) {
      if (paste0(f, "::", nm) %in% H6_ALLOW) next
      h6_hits <- c(h6_hits, sprintf("%s: %s bound %d times in one scope",
                                    f, nm, as.integer(tb[[nm]])))
    }
  }
}
note(length(h6_hits) == 0,
     sprintf("no name bound twice in one scope (%d allowlisted)", length(H6_ALLOW)),
     h6_hits)
# Reported, not fatal: an unwalkable subtree lowers this check's COVERAGE
# without itself being a duplicate-binding defect. It is 0 today.
#
# Cost note, measured not guessed: H6 adds ~29s over 657 files against H1's 3s.
# Left as is. The obvious suspects are not the cause -- replacing every
# deparse() with a symbol comparison changed nothing -- and a rewrite that
# dropped the per-node handler aborted on every file while LOOKING 19x faster.
# If this job needs the time back, profile it first.
if (H6_SWALLOWED > 0L)
  cat(sprintf("       note: %d subtree(s) could not be walked -- H6 saw less than the whole tree\n",
              H6_SWALLOWED))

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAIL",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
