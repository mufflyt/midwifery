#!/usr/bin/env Rscript
# =============================================================================
# The measurement behind Review_AI_complexity_2026-11-21.qmd
# =============================================================================
# A report whose numbers cannot be re-derived is an assertion, not a
# measurement. This is the script that produced that report's tables, kept so
# the next round can be compared against this one rather than restarted.
#
# Three passes, because each sees something the others cannot:
#
#   1. PER-FUNCTION COMPLEXITY. cyclomatic complexity, LOC, max nesting depth,
#      if/loop counts and arity for every top-level function in every tracked
#      .R file. midwifery is a pipeline of numbered scripts, not a package, so
#      there is no namespace to load: functions are read from source by parsing
#      each file and evaluating only its `name <- function(...)` assignments. A
#      closure's body does not run at definition time, so this is safe, and it
#      reaches script-local functions that devtools::load_all() never would.
#
#   2. OWN vs HOUSED COMPLEXITY. cyclocomp() scores a closure's WHOLE body,
#      nested closures included, so a function that merely holds six helpers
#      inherits all six scores. Pass 2 re-measures with every nested
#      `function(...)` replaced by NULL. The gap between the two columns is the
#      point: it is what separates a god-function from a module with private
#      parts. On the 2026-11-21 run it changed two verdicts --
#      duckdb_scan_for_raw_connections() scored 98 total and 3 of its own.
#
#   3. DUPLICATION. Cyclomatic complexity is blind to it: 85 copies of a 3-line
#      body all score 1. Bodies are normalised and grouped, which finds the copy
#      that was also RENAMED -- the shape ci_hygiene.R H4 cannot see, because H4
#      compares names.
#
# Needs: cyclocomp (pass 1 and 2 only). Not run by CI; this is a dev tool.
# Run:   Rscript tools/measure_code_complexity.R [output_dir]
# =============================================================================

mcc_root <- function() {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

#' Tracked .R files worth measuring: production code, not tests or archives.
mcc_files <- function(include_tests = FALSE) {
  f <- grep("[.]R$", system2("git", c("ls-files"), stdout = TRUE), value = TRUE)
  f <- grep("^(@archive/|scratch/)", f, value = TRUE, invert = TRUE)
  if (!include_tests) f <- grep("^tests/", f, value = TRUE, invert = TRUE)
  f
}

#' Max nesting depth of branch/loop/function constructs in an expression.
mcc_depth <- function(e, d = 0L) {
  if (!is.recursive(e)) return(d)
  hd <- if (length(e)) deparse(e[[1]])[1] else ""
  nd <- if (hd %in% c("if", "for", "while", "repeat", "function")) d + 1L else d
  max(nd, vapply(as.list(e),
                 function(x) tryCatch(mcc_depth(x, nd), error = function(z) nd),
                 integer(1)), na.rm = TRUE)
}

#' How many times a call to one of `what` appears.
mcc_count_call <- function(e, what) {
  if (!is.recursive(e)) return(0L)
  hd <- if (length(e)) deparse(e[[1]])[1] else ""
  (hd %in% what) + sum(vapply(as.list(e),
    function(x) tryCatch(mcc_count_call(x, what), error = function(z) 0L), integer(1)))
}

#' Replace every nested `function(...)` with NULL, leaving the caller's own
#' branching behind.
mcc_strip_closures <- function(e) {
  if (!is.recursive(e)) return(e)
  if (is.call(e) && length(e) && identical(deparse(e[[1]])[1], "function"))
    return(NULL)
  for (i in seq_along(e))
    e[[i]] <- tryCatch(mcc_strip_closures(e[[i]]), error = function(z) e[[i]])
  e
}

#' Every top-level `name <- function(...)` in a file, as evaluated closures.
mcc_closures <- function(path) {
  ex <- tryCatch(parse(path, keep.source = FALSE), error = function(e) NULL)
  if (is.null(ex)) return(list())
  out <- list()
  for (e in ex) {
    if (!(is.call(e) && length(e) == 3L &&
          deparse(e[[1]])[1] %in% c("<-", "=", "<<-"))) next
    if (!(is.call(e[[3]]) && deparse(e[[3]][[1]])[1] == "function")) next
    fn <- tryCatch(eval(e[[3]], envir = new.env(parent = globalenv())),
                   error = function(z) NULL)
    if (is.function(fn)) out[[length(out) + 1L]] <-
      list(nm = deparse(e[[2]])[1], fn = fn)
  }
  out
}

mcc_profile <- function(files) {
  rows <- list()
  for (f in files) for (d in mcc_closures(f)) {
    b <- body(d$fn)
    # Best-effort: a body this walk cannot strip yields cc_own = NA rather than
    # ending the run. NA in one row is visible; a dead script measures nothing.
    f2 <- tryCatch({ g <- d$fn; body(g) <- mcc_strip_closures(b); g },
                   error = function(z) NULL)
    rows[[length(rows) + 1L]] <- data.frame(
      fn = d$nm, file = f,
      cc     = tryCatch(cyclocomp::cyclocomp(d$fn), error = function(z) NA_integer_),
      cc_own = if (is.null(f2)) NA_integer_ else
        tryCatch(cyclocomp::cyclocomp(f2), error = function(z) NA_integer_),
      loc    = length(deparse(b)),
      nest   = tryCatch(mcc_depth(b), error = function(z) NA_integer_),
      n_if   = tryCatch(mcc_count_call(b, "if"), error = function(z) NA_integer_),
      n_loop = tryCatch(mcc_count_call(b, c("for", "while", "repeat")),
                        error = function(z) NA_integer_),
      args   = length(formals(d$fn)), stringsAsFactors = FALSE)
  }
  do.call(rbind, rows)
}

#' Groups of definitions sharing a normalised body. The RENAMED copies are the
#' interesting ones: identical work under two names, which H4 cannot see.
mcc_duplicates <- function(files, min_loc = 4L) {
  rows <- list()
  for (f in files) {
    ex <- tryCatch(parse(f, keep.source = FALSE), error = function(e) NULL)
    if (is.null(ex)) next
    for (e in ex) {
      if (!(is.call(e) && length(e) == 3L &&
            deparse(e[[1]])[1] %in% c("<-", "=", "<<-"))) next
      if (!(is.call(e[[3]]) && deparse(e[[3]][[1]])[1] == "function")) next
      b <- e[[3]][[3]]
      rows[[length(rows) + 1L]] <- data.frame(
        fn = deparse(e[[2]])[1], file = f, loc = length(deparse(b)),
        h = gsub("\\s+", " ", paste(deparse(b), collapse = " ")),
        stringsAsFactors = FALSE)
    }
  }
  d <- do.call(rbind, rows)
  g <- split(d, d$h)
  g <- g[vapply(g, nrow, 1L) > 1L]
  g[vapply(g, function(x) x$loc[1] >= min_loc, TRUE)]
}

if (sys.nframe() == 0L) {
  root <- mcc_root(); owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
  out_dir <- if (length(commandArgs(TRUE))) commandArgs(TRUE)[1] else "."
  files <- mcc_files()
  cat(sprintf("measuring %d tracked .R files (tests excluded)\n", length(files)))

  d <- mcc_profile(files)
  cat(sprintf("%d top-level functions in %d files\n", nrow(d),
              length(unique(d$file))))
  cat(sprintf("cc: median %g, mean %.1f, max %d\n",
              stats::median(d$cc, na.rm = TRUE), mean(d$cc, na.rm = TRUE),
              max(d$cc, na.rm = TRUE)))
  print(table(cut(d$cc, c(0, 5, 10, 20, 50, 100, Inf),
                  labels = c("1-5", "6-10", "11-20", "21-50", "51-100", ">100"))))
  cat("\n== top 15 by cyclomatic complexity ==\n")
  print(utils::head(d[order(-d$cc),
                      c("fn", "file", "cc", "cc_own", "loc", "nest", "n_if")], 15),
        row.names = FALSE)

  g <- mcc_duplicates(files)
  cat(sprintf("\n== %d exact-duplicate body group(s), body >= 4 lines ==\n", length(g)))
  for (x in g) {
    renamed <- length(unique(x$fn)) > 1L
    cat(sprintf("  %d copies x %d lines  [%s]%s\n", nrow(x), x$loc[1],
                paste(unique(x$fn), collapse = " == "),
                if (renamed) "   <- RENAMED COPY, invisible to H4" else ""))
    for (i in seq_len(nrow(x))) cat("      ", x$file[i], "\n", sep = "")
  }

  p <- file.path(out_dir, "code_complexity_profile.csv")
  utils::write.csv(d, p, row.names = FALSE)
  cat(sprintf("\nwrote %s\n", p))
}
