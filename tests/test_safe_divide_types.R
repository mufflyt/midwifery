#!/usr/bin/env Rscript
# =============================================================================
# safe_divide() must refuse a non-numeric argument, not coerce it
# =============================================================================
# safe_divide("abc", 5) used to return NA. So does safe_divide(1, 0). The two
# were indistinguishable, which made the safe-arithmetic family silently
# reintroduce the failure it exists to prevent: a count column read as text
# ("1,234" out of a CSV, a read_csv() that guessed character) divided to
# "missing", and every downstream guard treated it as suppressed-or-absent data
# rather than as the type error it was. This repository has published wrong
# numbers three times from exactly that confusion -- WONDER cells rendered as
# zeros, the apportioned CT regions, the POS obstetric-service flag.
#
# Both halves are pinned here on purpose. A test that only checks the new error
# invites someone to fix a caller by tightening the guard until NA input or a
# logical NA stops working, and safe_divide(1, NA) -> default is the contract
# the whole pipeline rests on.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "safe_divide.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
refuses <- function(expr) inherits(try(expr, silent = TRUE), "try-error")

cat("\n-- REFUSES NON-NUMERIC --\n")
chk(refuses(safe_divide("10", 5)),  "T1 a character numerator stops")
chk(refuses(safe_divide(10, "5")),  "T2 a character denominator stops")
chk(refuses(safe_divide("abc", 5)), "T3 unparseable text stops rather than returning NA")

# Factors are the dangerous case: as.numeric() on a factor returns LEVEL CODES,
# so the old path did not produce NA at all -- factor("3") has one level and
# divided as 1. Confident nonsense is worse than a missing value.
chk(refuses(safe_divide(factor("3"), 1)), "T4 a factor numerator stops (level codes, not values)")
chk(refuses(safe_divide(1, factor("3"))), "T5 a factor denominator stops")

# The message names the argument, so nested rate helpers say which one was wrong.
msg <- tryCatch(safe_divide("10", 5), error = conditionMessage)
chk(grepl("numerator", msg) && grepl("must be numeric", msg),
    sprintf("T6 the error names the offending argument [%s]", substr(msg, 1, 46)))

cat("\n-- STILL ACCEPTS EVERYTHING IT ACCEPTED BEFORE --\n")
chk(is.na(safe_divide(1, NA)),        "T7 a bare NA denominator is logical and must stay legal")
chk(is.na(safe_divide(NA, 1)),        "T8 a bare NA numerator likewise")
chk(is.na(safe_divide(1, NA_real_)),  "T9 a typed NA denominator")
chk(identical(safe_divide(TRUE, 2), 0.5), "T10 logical TRUE divides as 1")
chk(identical(safe_divide(1L, 2L), 0.5),  "T11 integer input")
chk(is.na(safe_divide(NULL, 4)),      "T12 NULL numerator returns the default")
chk(is.na(safe_divide(4, NULL)),      "T13 NULL denominator returns the default")
chk(length(safe_divide(integer(0), integer(0))) == 0L, "T14 zero-length in, zero-length out")
chk(identical(safe_divide(10, 2), 5), "T15 ordinary division is untouched")
chk(identical(safe_divide(c(1, 2), c(0, 2)), c(NA, 1)), "T16 vectorised zero-denominator guard")

cat("\n-- THE WRAPPERS INHERIT IT --\n")
chk(refuses(safe_percent("1", 4)),      "T17 safe_percent")
chk(refuses(safe_rate("1", 4)),         "T18 safe_rate")
chk(refuses(safe_ratio("1", 4)),        "T19 safe_ratio")
chk(refuses(safe_pct_manu("1", 4)),     "T20 safe_pct_manu")
chk(refuses(safe_divide_manu("1", 4)),  "T21 safe_divide_manu")

# The zero-denominator semantics the family is named for, unchanged by the
# validation: safe_percent displays 0, safe_pct_manu reports NA (DEN-032).
chk(identical(safe_percent(1, 0), 0),  "T22 safe_percent still defaults to 0 on a zero denominator")
chk(is.na(safe_pct_manu(1, 0)),        "T23 safe_pct_manu still returns NA (DEN-032)")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
