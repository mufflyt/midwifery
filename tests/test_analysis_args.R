#!/usr/bin/env Rscript
# =============================================================================
# arg_or(): positional argument, then env var, then default, then error
# =============================================================================
# R/analysis_args.R's own header explains why this one definition is shared by
# four analysis/ scripts whose numbers are quoted in docs/TECHNICAL_APPENDIX_*.md
# -- a second, slightly different copy is how two callers quietly disagree. It
# had no test of its own precedence order. commandArgs(TRUE) and Sys.getenv()
# are stubbed below so this runs the same everywhere, including under `Rscript
# tests/test_analysis_args.R` with no extra arguments.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "analysis_args.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
raises <- function(expr) inherits(tryCatch(expr, error = function(e) e), "error")

ENV <- "ARG_OR_TEST_VAR_DOES_NOT_EXIST"
stopifnot(!nzchar(Sys.getenv(ENV)))  # sanity: the env var really is unset

with_args <- function(args, expr) {
  fake_commandArgs <- function(trailingOnly = FALSE) if (trailingOnly) args else args
  old_fn <- get("commandArgs", envir = .GlobalEnv)
  assign("commandArgs", fake_commandArgs, envir = .GlobalEnv)
  on.exit(assign("commandArgs", old_fn, envir = .GlobalEnv), add = TRUE)
  force(expr)
}

cat("\n-- PRECEDENCE: positional beats env beats default --\n")
chk(with_args(c("from_arg"), arg_or(1, ENV, "from_default")) == "from_arg",
    "T1 a positional argument wins outright")

do.call(Sys.setenv, setNames(list("from_env"), ENV))
chk(with_args(character(0), arg_or(1, ENV, "from_default")) == "from_env",
    "T2 no positional argument falls back to the env var")
Sys.unsetenv(ENV)

chk(with_args(character(0), arg_or(1, ENV, "from_default")) == "from_default",
    "T3 neither positional nor env var falls back to the default")

cat("\n-- EMPTY STRING IS TREATED AS ABSENT, NOT AS A VALUE --\n")
chk(with_args("", arg_or(1, ENV, "from_default")) == "from_default",
    "T4 an empty positional argument is skipped, not returned literally")

do.call(Sys.setenv, setNames(list(""), ENV))
chk(with_args(character(0), arg_or(1, ENV, "from_default")) == "from_default",
    "T5 an empty env var is skipped, not returned literally")
Sys.unsetenv(ENV)

cat("\n-- NO DEFAULT MEANS ABSENCE IS AN ERROR, NOT A GUESS --\n")
chk(with_args(character(0), raises(arg_or(1, ENV))),
    "T6 absent argument, absent env var, NULL default: errors rather than returning NULL")
chk(grepl("1", err <- tryCatch(with_args(character(0), arg_or(1, ENV)),
                                error = function(e) conditionMessage(e))) &&
    grepl(ENV, err, fixed = TRUE),
    "T7 the error names both the argument position and the env var")

cat("\n-- POSITION MATTERS --\n")
chk(with_args(c("first", "second"), arg_or(2, ENV, "from_default")) == "second",
    "T8 a later position is read correctly when earlier ones are present")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
