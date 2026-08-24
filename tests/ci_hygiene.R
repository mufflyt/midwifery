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
#   H4  No function defined at top level in more than one tracked .R file.
#       norm_addr existed four times with divergent behaviour, zip5 three,
#       and a test shadowed the canonical pad5. Two scripts keying the same
#       address produced different keys with nothing saying so.
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
ALLOW <- c("chk", "xchk", "error", "pick", "f", "ok", "bad", "skip",
           "rd", "fmt", "mk", "sel",
           "main", "code", "as_lgl", "rate", "key_of", "nonascii", "fetch_one",
           "assign_cd", "centroid_counts", "assign_county_from_points",
           "drop_zip", "disagree")
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

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAIL",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
