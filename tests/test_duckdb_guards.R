#!/usr/bin/env Rscript
# =============================================================================
# refuse_if_large() must refuse cleanly, not with a cryptic base-R error
# =============================================================================
# Called from 10 top-level scripts right after a DuckDB query result lands in
# R (see R/lib/duckdb_guards.R's own header for why: this rule already killed
# three sessions). The function itself had no test: a malformed input (not a
# data.frame, or NULL) fell straight into nrow(d) > limit, which on a non-2D
# object returns NULL and makes `if (NULL > limit)` fail with "argument is of
# length zero" -- a confusing low-level error instead of the guard's own
# message. Pinned here alongside the normal-use and over-limit cases.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "duckdb_guards.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
err_msg <- function(expr) {
  res <- tryCatch(expr, error = function(e) e)
  if (inherits(res, "error")) conditionMessage(res) else NA_character_
}

cat("\n-- NORMAL USE --\n")
small <- data.frame(id = 1:5)
chk(identical(refuse_if_large(small, "small table"), small),
    "T1 a table under the limit passes through unchanged")
chk(identical(refuse_if_large(small, "small table", limit = 5), small),
    "T2 a table exactly at the limit is not refused (strict '>', not '>=')")

cat("\n-- OVER LIMIT --\n")
big <- data.frame(id = 1:10)
msg <- err_msg(refuse_if_large(big, "big table", limit = 5))
chk(!is.na(msg), "T3 a table over the limit stops")
chk(grepl("big table", msg, fixed = TRUE), "T4 the error names the caller's label")
chk(grepl("10", msg, fixed = TRUE) && grepl("5", msg, fixed = TRUE),
    "T5 the error reports both the actual row count and the limit")

cat("\n-- MALFORMED INPUT --\n")
chk(grepl("not a data frame", err_msg(refuse_if_large(NULL, "null input"))),
    "T6 NULL gives the guard's own clear message, not a base-R length-zero error")
chk(grepl("not a data frame", err_msg(refuse_if_large(1:10, "bare vector"))),
    "T7 a bare vector (has length, not nrow) is refused with the same clear message")
chk(grepl("list", err_msg(refuse_if_large(list(a = 1), "a list"))),
    "T8 the error reports the actual class it got, to help diagnose the caller")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
