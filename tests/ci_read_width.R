#!/usr/bin/env Rscript
# =============================================================================
# RW1 -- a read of the 4.7-million-row panel must say which columns it wants
# =============================================================================
# midwife_panel.csv is 544 MB, 4,735,546 rows, 13 columns. Measured on this
# tree (Review_AI_performance.qmd, 2026-11-21), one process per arm, peak taken
# from /usr/bin/time -l:
#
#   read_csv(cols(.default = "c"))                60.8s   534 MB held
#   read_csv(col_select = <the 3 used>)           12.1s   137 MB held
#
# Five times the wall-clock for columns the next statement throws away, and the
# answer is byte-identical -- proved with identical() over all 4,728,364 rows of
# build_truth_fusion_predictions.R's own reduction, not on a sample.
#
# NOT a memory check. The intuitive claim is false and was measured: peak RSS is
# 1,186 MB full-width against 1,197 MB narrowed, because readr streams all
# 544 MB through its parse buffer whichever columns it keeps. This gate is about
# latency only, and the number that matters is the multiplier: fourteen of the
# twenty-four reader scripts are named in rebuild_frozen_dependents.R's plan and
# two of them read the panel three times each, so a rebuild pays it 18 times.
#
# WHY A GATE AND NOT JUST THE FIX. The cheap idiom was already in the tree --
# compare_all_sources_mysteryroster.R:159 has narrowed its read since it was
# written -- and twenty-eight reads were written the expensive way anyway. One
# correct example sitting in a neighbouring file demonstrably does not hold a
# habit closed; a baseline that cannot grow does.
#
# SHRINK-ONLY, keyed on the FILE and a COUNT, not on file:line. Line numbers
# move whenever anything above them is edited, which would turn every unrelated
# commit into a baseline churn and train people to regenerate the file instead
# of reading it. A count per file is stable under edits and still refuses both
# of the things worth refusing: a new file that reads the panel full-width, and
# an existing file that grows another such read.
# =============================================================================

root <- if (file.exists("tests/ci_report.R")) "." else ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "ast_walk.R"))   # walk_call_tree()

PANEL <- "midwife_panel.csv"
BASE  <- "tests/ci_read_width_baseline.txt"

ci_section("RW1 every read of midwife_panel.csv names its columns")

# --- what counts as a read of the panel --------------------------------------
# The reader is named four ways across the tree (bare and namespaced, readr and
# base), and the path arrives either as a literal or through a variable the
# script assigned earlier -- PANEL, PANEL_PATH, panel_path are all in use. Both
# forms are resolved, because a gate that only saw the literal would be passed
# by moving the string into a variable, which is not a fix.
READERS <- c("read_csv", "read.csv", "readr::read_csv", "utils::read.csv")

# A read NARROWS if it says which columns it wants: col_select names them, and
# a col_types/colClasses spec containing col_skip() or NULL excludes the rest.
# Anything else -- cols(.default = "c"), colClasses = "character", or no spec at
# all -- parses all thirteen.
narrowing_arg <- function(e) {
  nms <- names(e)
  if (is.null(nms)) nms <- rep("", length(e))
  if ("col_select" %in% nms) return(TRUE)
  txt <- paste(vapply(as.list(e)[-1L], function(a)
    paste(deparse(a), collapse = " "), character(1)), collapse = " ")
  grepl("col_skip\\(|\"NULL\"|'NULL'", txt)
}

# sub(), not regmatches(): regmatches() drops the non-matching elements, so its
# result is shorter than `lines` and cannot be indexed with a mask built from
# `lines`, and subsetting regexpr()'s result to fix that drops the
# `match.length` attribute it needs. Both mistakes were made here in turn; the
# first silently missed four files -- the PANEL, PANEL_PATH and panel_path
# spellings that assign through Sys.getenv() -- and a gate reporting a smaller
# number than the truth is the worst failure mode a gate has.
# Resolve the local names that hold the panel's path. This walks the parse
# tree; the single-line regex it replaces could only see an assignment whose
# value sat on the same line as its name. build_midwife_panel.R assigns
# out_path across five lines (a Sys.getenv() whose default carries a comment),
# so the two read.csv(out_path) calls in the panel's OWN PRODUCER -- 283 s of
# measured cost, F1 and F5 -- sat in this gate's blind spot while it reported
# a clean tree. An assignment is a call, so the walker already reaches it.
panel_vars <- function(ex) {
  v <- character(0)
  walk_call_tree(ex, function(e) {
    if (!paste(deparse(e[[1L]]), collapse = "") %in% c("<-", "<<-", "=")) return(invisible(NULL))
    if (length(e) < 3L || !is.symbol(e[[2L]])) return(invisible(NULL))
    if (grepl(PANEL, paste(deparse(e[[3L]]), collapse = " "), fixed = TRUE))
      v <<- c(v, as.character(e[[2L]]))
    invisible(NULL)
  })
  unique(v)
}

reads_panel <- function(e, vars) {
  arg <- if ("file" %in% names(e)) e[["file"]] else
         if (length(e) >= 2L) e[[2L]] else return(FALSE)
  if (is.character(arg)) return(any(grepl(PANEL, arg, fixed = TRUE)))
  if (is.symbol(arg)) return(as.character(arg) %in% vars)
  FALSE
}

# --- scan --------------------------------------------------------------------
# tests/ is excluded: a fixture that plants the defect for the detector below is
# not a slow read of a 544 MB file, and including it would make this gate
# self-tripping -- the same reason ci_denominator_contracts.R scopes itself.
# `git -C root`, NOT ci_tracked(): ci_tracked() shells out from the working
# directory, so running this gate from inside tests/ listed only tests/ paths
# (already relative to tests/), the "^tests/" filter below removed all of them,
# and the gate reported PASS having scanned nothing. It did exactly that on its
# first run here. Asking git for the repo-relative list makes the answer
# independent of where the gate was invoked, and the floor below makes the
# empty-scan failure mode impossible to reach silently again.
all_r <- suppressWarnings(system2("git", c("-C", shQuote(root), "ls-files", "'*.R'"),
                                  stdout = TRUE, stderr = FALSE))
r_files <- grep("^tests/", all_r, invert = TRUE, value = TRUE)
r_files <- r_files[file.exists(file.path(root, r_files))]

# A FLOOR, NOT A COMMENT. This repository has ~400 tracked R files outside
# tests/. Any number anywhere near zero means the listing broke, not that the
# habit was fixed, and a gate that cannot tell those two apart is worse than no
# gate. 50 is low enough to let the detector's minimal fixtures through and high
# enough that a broken listing cannot pass.
MIN_FILES <- 50L
if (length(r_files) < MIN_FILES)
  ci_fail(paste("RW1 scanned only %d non-test R file(s) (floor %d):",
                "the tracked-file listing is broken, so a PASS here would mean",
                "nothing. Run from the repository root or a worktree of it."),
          length(r_files), MIN_FILES)

# An absent name is zero, not an error: `v[["x"]]` on an atomic vector raises
# "subscript out of bounds", and "this file has no full-width read" is the
# common case, not an exception.
cnt <- function(v, f) if (f %in% names(v)) v[[f]] else 0L

found <- integer(0)
unparsed <- character(0)
for (f in r_files) {
  p <- file.path(root, f)
  ex <- tryCatch(parse(p, keep.source = FALSE), error = function(e) NULL)
  if (is.null(ex)) { unparsed <- c(unparsed, f); next }
  vars <- panel_vars(ex)
  n <- 0L
  walk_call_tree(ex, function(e) {
    fn <- paste(deparse(e[[1L]]), collapse = "")
    if (!fn %in% READERS) return(invisible(NULL))
    if (reads_panel(e, vars) && !narrowing_arg(e)) n <<- n + 1L
    invisible(NULL)
  })
  if (n > 0L) found[[f]] <- n
}

# H1 already proves every tracked R file parses, so an unparsed file here means
# this gate and that one disagree -- report it rather than silently scanning a
# smaller tree than the baseline was built from.
if (length(unparsed))
  ci_fail("RW1 could not parse %d file(s), so the scan is incomplete: %s",
          length(unparsed), paste(unparsed, collapse = ", "))

# --- compare against the baseline --------------------------------------------
baseline <- integer(0)
if (file.exists(file.path(root, BASE))) {
  b <- readLines(file.path(root, BASE), warn = FALSE)
  b <- b[nzchar(trimws(b)) & !grepl("^\\s*#", b)]
  for (line in b) {
    p <- strsplit(line, "\t")[[1L]]
    if (length(p) >= 2L) baseline[[trimws(p[1L])]] <- as.integer(trimws(p[2L]))
  }
}

over <- character(0)
for (f in names(found)) {
  was <- cnt(baseline, f)
  if (found[[f]] > was)
    over <- c(over, sprintf(
      "%s reads %s full-width %d time(s); baseline allows %d. Pass col_select = c(<the columns used>).",
      f, PANEL, found[[f]], was))
}

paid <- setdiff(names(baseline), names(found))
if (length(unparsed) == 0L)
  for (f in names(baseline)) {
    now <- cnt(found, f)
    if (now < baseline[[f]])
      paid <- unique(c(paid, f))
  }

if (length(over)) {
  ci_fail("RW1 %d new full-width read(s) of %s:\n         %s",
          length(over), PANEL, paste(over, collapse = "\n         "))
} else {
  ci_ok("no NEW full-width read of %s (%d grandfathered across %d file(s) in %s)",
        PANEL, sum(found), length(found), BASE)
}

# A baseline that has been paid down and not edited is debt that looks like
# debt forever, so say so out loud. Not a failure: the fix landed.
if (length(paid))
  cat(sprintf(paste0("       note: %d baseline entr%s now narrower than recorded;",
                     " shrink %s: %s\n"),
              length(paid), if (length(paid) == 1L) "y is" else "ies are",
              BASE, paste(paid, collapse = ", ")))

ci_finish()
