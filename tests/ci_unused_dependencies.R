#!/usr/bin/env Rscript
# =============================================================================
# U1 a library() call whose package is never used
# =============================================================================
# `library(janitor)` sat in R/01-build-county-base.R without a single janitor
# function being called, and `library(lubridate)` did the same in
# analyze_address_lead_lag_and_freshness.R. Neither is a runtime error: R
# attaches the package, nothing calls it, the script works. The cost is paid
# somewhere else -- every runner and every collaborator installs a dependency
# the pipeline does not use, and a reader of the header believes the script
# does date arithmetic or name cleaning when it does neither.
#
# WHY A GATE RATHER THAN A ONE-OFF SWEEP. The attachment and the use are in
# different places and drift apart silently: the last call to a package gets
# refactored away and its library() line stays, because nothing connects them.
# That is the same shape as a gate wired below a failing step -- an artifact of
# the past that reads as a present fact.
#
# HOW IT DECIDES. For each attached package, every token used as a function
# call in the file is intersected with that package's exported names. A
# package is unused when the intersection is empty AND the file never
# qualifies it with `::`. That is deliberately generous:
#
#   - `pkg::fn()` counts, so a file may attach nothing and still be clean.
#   - A package used only for its DATA (state.name-style) or only for S3
#     methods it registers (dbplyr's collect() over a DBI table, scales'
#     labels inside ggplot) has no call token of its own, which is why
#     ALLOW below exists and why each entry needs a reason.
#   - A package that is not installed here cannot be judged, so it is skipped
#     rather than guessed at. On a runner that installs the tidyverse stack
#     this means the stack is checked and the rest is declared.
#
# Scope: tracked .R files. Not tests/ -- a test may attach a package to probe
# it without calling it.
# =============================================================================
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

ci_section("U1 every attached package is actually used")

# A package whose use is invisible to a call-token scan. Each entry is a claim
# that the package earns its attachment some other way, and says how.
ALLOW <- c(
  dbplyr   = "registers the dplyr methods that make collect()/tbl() work over a DBI connection; the call tokens belong to dplyr",
  scales   = "supplies labels/transform objects consumed inside ggplot2 layers, often as bare symbols rather than calls",
  sf       = "registers S3 methods for geometry columns; a script may rely on them without naming an sf function",
  methods  = "attached for S4 dispatch, which is never a call token",
  stats    = "base-distribution package; attaching it is a no-op and never a dependency cost",
  utils    = "base-distribution package; attaching it is a no-op and never a dependency cost"
)

files <- setdiff(ci_tracked("*.R"), ci_tracked("tests/*.R"))
files <- files[!grepl("^tests/", files)]

offenders <- character(0)
unjudged <- 0L
checked <- 0L

for (f in files) {
  txt <- tryCatch(readLines(file.path(root, f), warn = FALSE),
                  error = function(e) character(0))
  if (!length(txt)) next
  code <- txt[!grepl("^\\s*#", txt)]
  # ANYWHERE ON THE LINE, not just at its start. Several scripts chain
  # attachments with semicolons -- `library(readr); library(stringr)` -- and an
  # anchored pattern sees only the first, so the gate under-reported for
  # exactly the files that attach the most.
  attached <- unique(unlist(regmatches(code,
    gregexpr("(?<=\\blibrary\\()[A-Za-z0-9._]+(?=\\))", code, perl = TRUE))))
  attached <- setdiff(unique(attached), names(ALLOW))
  if (!length(attached)) next

  # A FILE'S OWN TOKENS ARE NOT THE WHOLE STORY. Six R/lib files call
  # read_csv() and friends UNQUALIFIED, so a script that source()s one of them
  # must attach readr for code it never names itself. Judging the file alone
  # would have reported 29 scripts as carrying an unused readr and breaking
  # every one of them at runtime. The sourced files' tokens are folded in,
  # one level deep, which is as far as this repository's source() chains go.
  sourced <- unique(unlist(regmatches(code,
    gregexpr("(?<=\\bsource\\()[^)]*", code, perl = TRUE))))
  extra <- character(0)
  for (sx in sourced) {
    nm <- unlist(regmatches(sx, gregexpr('"[^"]+"', sx)))
    nm <- gsub('"', "", nm)
    if (!length(nm)) next
    cand <- file.path(root, do.call(file.path, as.list(nm)))
    if (!file.exists(cand)) cand <- file.path(root, utils::tail(nm, 1))
    if (!file.exists(cand)) next
    st <- tryCatch(readLines(cand, warn = FALSE), error = function(e) character(0))
    st <- st[!grepl("^\\s*#", st)]
    extra <- c(extra, unlist(regmatches(st,
      gregexpr("[A-Za-z_.][A-Za-z0-9_.]*(?=\\s*\\()", st, perl = TRUE))))
  }

  joined <- paste(c(code, extra), collapse = " ")
  calls <- unique(c(unlist(regmatches(code,
    gregexpr("[A-Za-z_.][A-Za-z0-9_.]*(?=\\s*\\()", code, perl = TRUE))), extra))

  for (p in attached) {
    if (!requireNamespace(p, quietly = TRUE)) { unjudged <- unjudged + 1L; next }
    checked <- checked + 1L
    if (grepl(paste0(p, "::"), joined, fixed = TRUE)) next
    exports <- tryCatch(getNamespaceExports(p), error = function(e) character(0))
    # library() itself is not evidence that the package is used.
    if (length(intersect(setdiff(calls, "library"), exports))) next
    # OPERATORS ARE USE, AND THEY ARE NOT CALL TOKENS. `df %>% filter(x)` never
    # writes `%>%(`, so a call-token scan cannot see it -- and several packages
    # re-export the pipe, so stringr can be carrying `%>%` for a file that names
    # no stringr function. Dropping its library() line there would break the
    # script. Checked literally rather than as a regex: operator names are full
    # of characters that mean something else in one.
    if (any(vapply(Filter(function(e) grepl("%", e, fixed = TRUE), exports),
                   function(e) grepl(e, joined, fixed = TRUE), logical(1)))) next
    offenders <- c(offenders, sprintf("%s: library(%s) attaches a package no call in the file uses", f, p))
  }
}

cat(sprintf("  [CONTROL] U1 judged %d attachment(s); %d not installed here and skipped\n",
            checked, unjudged))

if (length(offenders)) {
  ci_fail("U1: %d unused package attachment(s):\n%s\n       Drop the library() line, or qualify the one call that needs it with\n       `pkg::`. If the package earns its place invisibly (S3/S4 methods, data),\n       add it to ALLOW in this file WITH A REASON.",
          length(offenders), paste(sprintf("       %s", offenders), collapse = "\n"))
} else {
  ci_ok("every attached package is called, qualified, or declared in ALLOW")
}

ci_finish()
