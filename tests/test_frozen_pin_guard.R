#!/usr/bin/env Rscript
# =============================================================================
# guard_frozen_write() must refuse a re-pin, and must not cry wolf
# =============================================================================
# The guard exists because R/03 wrote artifacts/midwives_geography_FROZEN.csv
# with no protection at all, so a plain pipeline run re-pinned the geography
# every published county figure rests on. R/05 has had the equivalent guard on
# its frozen INPUT since the analytic cohort was moved by accident twice.
#
# Both halves are tested, and the second is the one that decides whether the
# guard survives. Its first version compared numeric columns as STRINGS, so the
# in-memory frame at 15 significant digits never matched the rounded CSV: it
# reported 2,435 changed rows in a column where the two files agree exactly. A
# guard that fires on formatting noise is answered with ALLOW_REFREEZE=1 as a
# matter of routine, and then it is not a guard.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "frozen_pin.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

dir <- file.path(tempdir(), paste0("fpin_", as.integer(stats::runif(1) * 1e9)))
dir.create(dir, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(dir, recursive = TRUE), add = TRUE)

pinned <- file.path(dir, "frozen.csv")
base <- data.frame(id  = c("a", "b", "c"),
                   val = c(1.5, 2.25, 3.125),
                   lab = c("x", "y", "z"), stringsAsFactors = FALSE)
utils::write.csv(base, pinned, row.names = FALSE)

# Named guard_refuses, not refuses: H4 forbids a top-level function defined in
# two tracked files, and tests/test_safe_divide_types.R already has a refuses().
# The collision was invisible until this file was staged, because ci_hygiene.R
# reads `git ls-files` -- an untracked new test is one H4 cannot see yet.
guard_refuses <- function(new, path = pinned) {
  inherits(try(guard_frozen_write(new, path), silent = TRUE), "try-error")
}

cat("\n-- it must PROCEED when nothing would change --\n")
chk(!guard_refuses(base, file.path(dir, "absent.csv")), "an absent target is a first write")
chk(!guard_refuses(base), "a rebuild that reproduces the artifact")

# THE REGRESSION. Same numbers, formatting a reader cannot see.
noise <- base; noise$val <- c(1.5000000000001, 2.25, 3.125)
chk(!guard_refuses(noise), "float formatting noise below 1e-9 is not a change")

cat("\n-- it must REFUSE a real change --\n")
num <- base; num$val[2] <- 99
chk(guard_refuses(num), "a numeric value moved")
str_ <- base; str_$lab[3] <- "CHANGED"
chk(guard_refuses(str_), "a string value moved")
chk(guard_refuses(base[1:2, ]), "the row count moved")
wide <- base; wide$extra <- 1L
chk(guard_refuses(wide), "a column was added")

cat("\n-- and the escape hatch must work, but only when asked --\n")
withr_env <- Sys.getenv("ALLOW_REFREEZE")
Sys.setenv(ALLOW_REFREEZE = "1")
chk(!guard_refuses(num), "ALLOW_REFREEZE=1 permits a deliberate re-pin")
if (nzchar(withr_env)) Sys.setenv(ALLOW_REFREEZE = withr_env) else Sys.unsetenv("ALLOW_REFREEZE")
chk(guard_refuses(num), "and refuses again once it is unset")

cat("\n-- the message has to name what moved --\n")
msg <- tryCatch(guard_frozen_write(num, pinned), error = function(e) conditionMessage(e))
chk(grepl("val", msg) && grepl("1 row", msg), "it names the column and the row count")
chk(grepl("ALLOW_REFREEZE", msg), "it says how to proceed deliberately")

cat("\n")
if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
