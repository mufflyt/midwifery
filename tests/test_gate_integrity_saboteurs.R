#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the gates themselves
# =============================================================================
# Six checks written in this session could not have failed when they were
# written. Every one reported "ok" against a working tree where the defect it
# was meant to catch was still present, and every one was found by mutating it
# rather than by reading it. The four shapes, each of which gets a gate here:
#
#   Q1 A REGEX THAT DOES NOT COMPILE. "[^:.a-zA-Z_]here(" is invalid -- the
#      paren is unescaped -- and `&&` short-circuited past it for every file
#      the scan reached, so it never once ran. An invalid pattern inside a
#      condition that is rarely evaluated is indistinguishable from a passing
#      check.
#   Q2 A SCAN THAT CLAIMS MORE THAN IT READS. `git ls-files "*.R"` does not
#      cross directory boundaries: 267 paths where the repository tracks 645.
#      Three scans were reading the root scripts and reporting "no tracked R
#      file".
#   Q3 A GENERATED FILE SWEPT INTO A COMMIT. Running the suite rewrites
#      provenance sidecars -- timestamps, code hashes, and in one case a
#      content sha256, which is a claim about data -- and `git add -A` carried
#      seven of them into a refactor.
#   Q4 A CONDITION THAT CANNOT BE FALSE. `|| TRUE`, a literal, or a needle a
#      scanner would find in its own source.
#
# Each saboteur mutates the thing it guards. A gate in this file that cannot
# fail is the joke writing itself, so every one is checked in both directions:
# it fires on the defect AND stays quiet on the legitimate case next to it.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "Q"

git_out <- function(...) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(root), ...),
                                  stdout = TRUE, stderr = FALSE))
  if (!length(out)) character(0) else out
}
ALL_R <- grep("\\.R$", git_out("ls-files"), value = TRUE)

# --- Q1 every regex literal in a tracked file compiles -------------------------
sab(1, "a pattern that cannot compile is not a check that passed")
RX_FNS <- c("grepl", "grep", "sub", "gsub", "regexpr", "gregexpr", "regexec")

#' Literal regex patterns in a file, tagged with the engine they are used with
#'
#' Skips `fixed = TRUE` calls, which are not patterns, and records `perl =
#' TRUE` so a lookbehind is compiled by the engine that accepts it rather than
#' reported as broken.
#' @param path [character(1)] file to read.
#' @return [character] each entry "T<pattern>" or "P<pattern>".
regex_literals <- function(path) {
  exprs <- tryCatch(parse(path), error = function(e) NULL)
  if (is.null(exprs)) return(character(0))
  found <- character(0)
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    fn <- tryCatch(as.character(e[[1]])[1], error = function(...) "")
    if (fn %in% RX_FNS) {
      args <- as.list(e)[-1]
      nm <- names(args); if (is.null(nm)) nm <- rep("", length(args))
      flag <- function(which_arg) any(nm == which_arg &
        vapply(args, function(a) isTRUE(a), logical(1)))
      if (!flag("fixed") && length(args)) {
        i <- if (any(nm == "pattern")) which(nm == "pattern")[1] else which(nm == "")[1]
        if (!is.na(i)) {
          p <- args[[i]]
          if (is.character(p) && length(p) == 1L)
            found <<- c(found, paste0(if (flag("perl")) "P" else "T", p))
        }
      }
    }
    # VIA lapply, NOT a for loop. An empty argument (`x[, 1]`) is the empty
    # symbol, and `el <- kids[[i]]` errors on assignment -- before any
    # predicate can skip it. Passing it as a function argument forces it
    # harmlessly, so the recursion goes through lapply and the guard runs.
    invisible(lapply(as.list(e), function(el) {
      if (is.name(el) && !nzchar(as.character(el))) return(invisible(NULL))
      walk(el)
    }))
  }
  for (ex in exprs) walk(ex)
  unique(found)
}
compiles <- function(tagged) {
  pl <- substr(tagged, 1, 1) == "P"
  tryCatch({ regexpr(substring(tagged, 2), "", perl = pl); TRUE },
           error = function(e) FALSE, warning = function(w) FALSE)
}
bad_rx <- unlist(lapply(ALL_R, function(f) {
  b <- Filter(Negate(compiles), regex_literals(file.path(root, f)))
  if (length(b)) paste0(f, ": ", substring(b, 2)) else character(0)
}))
chk(length(ALL_R) > 500L,
    sprintf("Q1a the scan reads the whole tree (%d tracked .R files), so a clean result means clean and not empty",
            length(ALL_R)))
chk(!length(bad_rx),
    sprintf("Q1b every literal regex in a tracked file compiles%s",
            if (length(bad_rx)) paste0(" [", paste(utils::head(bad_rx, 3), collapse = "; "), "]") else ""))
chk(!compiles(paste0("T", "[^:.a-zA-Z_]here(")),
    "Q1c KILLED: the exact unescaped-paren pattern that never ran is rejected")
chk(compiles("P(?<=Figure )[0-9]+"),
    "Q1d a perl lookbehind is compiled by the engine that accepts it, not reported as broken")

# --- Q2 a scan reads as much as it claims ---------------------------------------
sab(2, "a pathspec that stops at the root is not a whole-tree scan")
#' Is this a `git ls-files` call with a bare "*.ext" pathspec?
#'
#' A directory-qualified glob ("tests/*.R") is honest about its scope; a bare
#' one reads only the top level while the message beside it usually says
#' "every tracked file".
root_only_pathspec <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  lines <- lines[!grepl("^\\s*#", lines)]
  grep('ls-files[^#]*"\\*\\.[A-Za-z]+"', lines, value = TRUE)
}
narrow <- unlist(lapply(grep("^tests/", ALL_R, value = TRUE), function(f) {
  h <- root_only_pathspec(slurp(f))
  if (length(h)) paste0(f) else character(0)
}))
chk(!length(narrow),
    sprintf("Q2a no gate scans with a bare \"*.ext\" pathspec, which reads only the repository root%s",
            if (length(narrow)) paste0(" [", paste(basename(narrow), collapse = ", "), "]") else ""))
# Assembled, not spelled: Q2a reads every tracked gate including this one.
.bare <- paste0("\"*", ".R\"")
chk(length(root_only_pathspec(sprintf('out <- system2("git", c("ls-files", %s))', .bare))) == 1L,
    "Q2b KILLED: the bare pathspec that read 267 of 645 files is caught")
chk(length(root_only_pathspec('out <- system2("git", c("ls-files", "tests/*.R"))')) == 0L,
    "Q2c a directory-qualified glob is honest about its scope and is not flagged")

# --- Q3 a generated sidecar is not a code change --------------------------------
sab(3, "a provenance sidecar does not travel alone")
base_ref <- if (length(git_out("rev-parse", "--verify", "-q", "origin/main"))) {
  "origin/main"
} else NA_character_
#' Sidecars changed without the artifact they describe
#'
#' @param changed [character] paths changed against the base.
#' @return [character] offending sidecar paths.
lonely_sidecars <- function(changed) {
  side <- grep("\\.provenance\\.json$", changed, value = TRUE)
  Filter(function(s) !(sub("\\.provenance\\.json$", "", s) %in% changed), side)
}
if (is.na(base_ref)) {
  # A check that could not run has not passed: say which ref is missing
  # rather than reporting a clean diff nobody computed.
  chk(FALSE, "Q3a origin/main is not in this clone, so no diff can be taken -- give this job fetch-depth: 0 rather than reading a pass here")
} else {
  changed <- git_out("diff", "--name-only", paste0(base_ref, "...HEAD"))
  lonely <- lonely_sidecars(changed)
  chk(!length(lonely),
      sprintf("Q3a no provenance sidecar is changed without the artifact it describes%s",
              if (length(lonely)) paste0(" [", paste(basename(lonely), collapse = ", "), "]") else ""))
}
chk(length(lonely_sidecars(c("artifacts/x.csv.provenance.json", "tests/a.R"))) == 1L,
    "Q3b KILLED: a sidecar rewritten by a test sweep and committed alone is caught")
chk(length(lonely_sidecars(c("artifacts/x.csv", "artifacts/x.csv.provenance.json"))) == 0L,
    "Q3c a sidecar changed beside its own artifact is a real data change, not a sweep")

# --- Q4 a condition that can be false -------------------------------------------
sab(4, "an assertion that cannot fail is not an assertion")
#' Conditions wired so they cannot be false
#'
#' ACROSS LINES, NOT WITHIN THEM. The first draft matched line by line and
#' missed `cond ||\n      TRUE`, which is exactly how the real one was
#' written -- the operator ended one line and the constant began the next. The
#' comment-stripped source is rejoined before matching so \s spans the break.
unfailable <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  joined <- paste(lines[!grepl("^\\s*#", lines)], collapse = "\n")
  m <- gregexpr("\\|\\|\\s*TRUE|chk\\(\\s*TRUE\\s*,", joined)[[1]]
  if (identical(as.integer(m), -1L)) character(0) else
    regmatches(joined, gregexpr("\\|\\|\\s*TRUE|chk\\(\\s*TRUE\\s*,", joined))[[1]]
}
# KNOWN, AWAITING THEIR OWNERS -- not forgiven, and the list may only shrink.
# Four assertions that predate this gate cannot be false. Rewriting them is a
# decision about what each suite is asserting, which belongs to whoever wrote
# it; what this gate refuses is a FIFTH appearing unnoticed. Baselined the way
# ci_science_nightly.R baselines SCN2, including the staleness check: fix one
# and this gate fails until the entry is removed.
#
#   test_borrowed_isochrones_saboteurs.R:84  chk(TRUE, "C7 skipped: ...")
#       -- a skip printed as a pass, which is the exact defect this file is
#          named for.
#   test_metamorphic_invariance.R:257        chk(TRUE, "D1 ... is REJECTED")
#       -- claims a rejection happened without checking that it did.
#   test_cross_vintage_pairing_saboteurs.R:126  chk(cond || TRUE, ...)
#       -- the condition is computed and then discarded.
#   test_amcb_gates.R:101                    chk(TRUE, sprintf(... %d ...))
#       -- reports a count dressed as an assertion; `checked > 0L` is the
#          assertion it looks like it is making.
Q4_BASELINE <- c("tests/test_amcb_gates.R",
                 "tests/test_borrowed_isochrones_saboteurs.R",
                 "tests/test_cross_vintage_pairing_saboteurs.R",
                 "tests/test_metamorphic_invariance.R")
tautologies <- unlist(lapply(grep("^tests/", ALL_R, value = TRUE), function(f) {
  h <- unfailable(slurp(f)); if (length(h)) f else character(0)
}))
new_taut <- setdiff(tautologies, Q4_BASELINE)
chk(!length(new_taut),
    sprintf("Q4a no NEW assertion is wired to a condition that cannot be false (%d baselined)%s",
            length(Q4_BASELINE),
            if (length(new_taut)) paste0(" [", paste(basename(new_taut), collapse = ", "), "]") else ""))
stale <- setdiff(Q4_BASELINE, tautologies)
chk(!length(stale),
    sprintf("Q4a2 every baselined file still contains the assertion it was baselined for, so the list shrinks rather than rots%s",
            if (length(stale)) paste0(" -- remove: ", paste(basename(stale), collapse = ", ")) else ""))
# Likewise: writing the tautology out in full would make Q4a flag this file.
.taut <- paste0("|", "| TRUE")
chk(length(unfailable(sprintf('chk(any(grepl("x", y)) %s, "always ok")', .taut))) >= 1L,
    "Q4b KILLED: the `||`-TRUE that made a real check unfailable is caught")
chk(length(unfailable('chk(nrow(d) > 0L, "the frame has rows")')) == 0L,
    "Q4c an ordinary assertion is not flagged")
# A scanner must not be able to find its own needle. Both existing suites
# assemble theirs; this holds that fix rather than trusting it.
PONY <- "tests/test_ponytail_cuts_saboteurs.R"
if (file.exists(file.path(root, PONY))) {
  src <- slurp(PONY)
  chk(!grepl(paste0("library", "(here)"), src, fixed = TRUE) &&
        !grepl(paste0("@", "archive/experiment"), src, fixed = TRUE),
      "Q4d the cut saboteurs still assemble the needles that would otherwise match their own source")
}

cat(sprintf("\n%s (%d failure(s) across 4 gate-integrity saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS", fails))
quit(status = if (fails == 0L) 0L else 1L)
