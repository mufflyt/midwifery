#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 3 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Targets: the two untested libraries that produce DENOMINATORS and COUNTS --
# R/safe_divide.R and R/lib/wonder_natality.R -- plus the ACS denominator built
# in R/12-district-profiles.R. Neither library had a single test.
#
# The organising principle of this cycle is one sentence: SUPPRESSED IS NOT
# ZERO, and NEITHER IS MISSING. Every defect below is a place where an absent
# value is silently given the numeric value 0, which is not missingness but a
# claim -- and always a claim in the direction that makes access look better or
# a denominator look smaller.
#
# Run: Rscript tests/test_cycle3_denominators.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages(library(dplyr))
source(file.path(root, "R", "safe_divide.R"))
source(file.path(root, "R", "lib", "wonder_natality.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- BVA --\n")

# T21 (BVA). zero_threshold is a strict <, so 1e-10 divides and 9e-11 does not.
# A denominator is either a real quantity or it is not; the edge must be pinned
# because it silently converts a very small population into "no population".
{
  chk(is.finite(safe_divide(1, 1e-10)) && is.na(safe_divide(1, 9e-11)),
      "T21a zero_threshold edge: 1e-10 divides, 9e-11 is treated as zero")
  chk(is.na(safe_divide(1, 0)) && is.na(safe_divide(1, NA_real_)),
      "T21b exact zero and NA denominators both yield the default")
  chk(is.finite(safe_divide(1, -5)),
      "T21c a negative denominator is not confused with a zero one")
}

# T22 (BVA). Length and type stability. A helper used inside mutate() must
# return one value per input row; returning a scalar for a zero-length input
# either errors on recycling or silently lengthens a column.
{
  chk(length(safe_divide(numeric(0), numeric(0))) == 0L,
      "T22a zero-length in, zero-length out")
  chk(length(safe_divide(1, numeric(0))) == 0L,
      sprintf("T22b mismatched zero-length returns zero-length [got length %d]",
              length(safe_divide(1, numeric(0)))))
  chk(length(safe_divide(c(1, 2, 3), 0)) == 3L,
      "T22c a scalar denominator recycles to the numerator's length")
}

# T23 (BVA). R's round() is round-half-to-EVEN, so 12.25 -> 12.2 rather than
# 12.3. My first version of this test also expected 12.35 -> 12.4 by the same
# rule and was WRONG: 12.35 is not representable in binary and its double is
# fractionally BELOW the midpoint, so it rounds down to 12.3 for a reason that
# has nothing to do with banker's rounding. Both mechanisms are pinned, because
# "round half up" is what a reader assumes a published percentage did, and
# neither of these is that.
{
  chk(identical(safe_percent(1225, 10000), 12.2),
      sprintf("T23a exact-midpoint .25 rounds to even, not up [12.25 -> %s]",
              safe_percent(1225, 10000)))
  chk(identical(safe_percent(1235, 10000), 12.3),
      sprintf("T23b .35 is below its midpoint as a double and rounds down [12.35 -> %s]",
              safe_percent(1235, 10000)))
}

cat("\n-- SEMANTIC --\n")

# T24 (semantic). THE NAMED BUG, STILL LIVE. safe_pct_manu()'s own
# documentation states that default = 0 "caused Step 4/11 to report 0% access
# when the denominator was missing, creating phantom care-desert artifacts
# (DEN-032)". The alias was fixed. safe_percent() still defaults to 0, so a
# county with no denominator is reported as 0% rather than unknown -- an
# assertion of total absence of access, produced by missing data.
{
  chk(is.na(safe_pct_manu(5, 0)), "T24a safe_pct_manu returns NA on an empty denominator")
  hazard <- safe_percent(5, 0)
  chk(identical(hazard, 0),
      sprintf("T24b DOCUMENTED HAZARD: safe_percent still defaults to 0%% on an empty denominator [got %s] -- see ledger, decision pending",
              hazard))
  # Containment: no midwifery code may call the hazardous default. This is what
  # keeps the finding honest while the fix belongs to another repo.
  callers <- unlist(lapply(
    list.files(file.path(root, "R"), pattern = "\\.R$", recursive = TRUE,
               full.names = TRUE),
    function(f) if (basename(f) == "safe_divide.R") NULL
                else if (any(grepl("safe_percent\\(", readLines(f, warn = FALSE)))) f))
  chk(length(callers) == 0L,
      sprintf("T24c no midwifery script calls safe_percent() directly [found: %s]",
              if (length(callers)) paste(basename(callers), collapse = ", ") else "none"))
}

# T25 (semantic). wonder_count()'s flag is the contract: flag == "ok" is what
# downstream code tests to decide whether a count is publishable. It must
# therefore imply a real number.
{
  w <- wonder_count(c("1,234", "12", "0"))
  chk(all(w$flag == "ok") && !any(is.na(w$value)),
      "T25a a parsed count is flagged ok and carries a value")
  w2 <- wonder_count(",,,")
  chk(!(w2$flag == "ok" && is.na(w2$value)),
      sprintf("T25b flag 'ok' must imply a non-NA value [',,,' -> flag=%s value=%s]",
              w2$flag, w2$value))
}

# T26 (semantic). SUPPRESSED IS NOT ZERO. WONDER suppresses sub-national cells
# below 10 births; the true value is 1-9, never 0. Recording it as 0 would turn
# "we cannot say" into "no midwife-attended births happened here", which is the
# strongest possible claim about a county.
{
  w <- wonder_count(c("Suppressed", "Not Applicable", "Unreliable"))
  chk(all(is.na(w$value)) && !any(w$value %in% 0),
      "T26a suppressed / not-applicable / unreliable are NA, never 0")
  chk(identical(w$flag, c("suppressed", "not_applicable", "unreliable")),
      "T26b each non-count reason keeps its own flag, not one generic missing")
}

cat("\n-- ADVERSARIAL --\n")

# T27 (adversarial). Malformed but plausible cell values. A WONDER export
# hand-edited in a spreadsheet produces exactly these.
{
  raw <- c(" 12 ", "1 234", "1,,2", "-5", "12.5", "")
  w <- wonder_count(raw)
  bad <- raw[w$flag == "ok" & is.na(w$value)]
  chk(length(bad) == 0L,
      sprintf("T27 no malformed value is flagged ok with an NA count [offenders: %s]",
              if (length(bad)) paste(sprintf("'%s'", bad), collapse = ", ") else "none"))
}

# T28 (adversarial). A non-finite numerator must not become a finite answer.
{
  chk(is.na(safe_divide(NA_real_, 5)), "T28a NA numerator stays NA")
  chk(is.infinite(safe_divide(Inf, 5)) || is.na(safe_divide(Inf, 5)),
      "T28b Inf numerator does not silently become a number")
  chk(is.na(safe_rate(5, 0, multiplier = 100000)),
      "T28c a rate on an empty exposure is NA, not 0 per 100k")
}

# T29 (adversarial). SUPPRESSED IS NOT ZERO, second instance. The ACS
# denominator women_15_44 is built with rowSums(..., na.rm = TRUE), and the
# loader has just converted Census negative sentinels to NA. na.rm = TRUE then
# scores every suppressed component as 0, understating the denominator -- which
# inflates every per-capita rate computed from it. A partially suppressed
# district is indistinguishable from one with genuinely fewer women.
{
  comp <- data.frame(a = c(100, 100), b = c(50, NA_real_))
  naive <- rowSums(comp, na.rm = TRUE)
  honest <- ifelse(rowSums(is.na(comp)) > 0, NA_real_, rowSums(comp))
  chk(identical(naive, c(150, 100)) && is.na(honest[2]),
      sprintf("T29 DOCUMENTED HAZARD: rowSums(na.rm=TRUE) scores a suppressed component as 0 [%s vs honest %s] -- see ledger",
              paste(naive, collapse = "/"), paste(honest, collapse = "/")))
}

# T30 (adversarial). The safe-arithmetic family is vendored from mufflyaccess,
# the SSOT, with no declared dependency. Drift between the two copies is the
# duplicate-definition class that has cost this project repeatedly, and it is
# invisible because both copies are named the same and neither errors.
{
  ssot <- Sys.glob(file.path(path.expand("~"), "mufflyaccess", "R", "safe_divide.R"))
  if (!length(ssot)) {
    cat("  skip T30 mufflyaccess not present\n")
  } else {
    sig <- function(f) {
      src <- readLines(f, warn = FALSE)
      i <- grep("^safe_percent <- function", src)
      if (!length(i)) NA_character_ else trimws(src[i[1]])
    }
    a <- sig(file.path(root, "R", "safe_divide.R")); b <- sig(ssot[1])
    chk(identical(a, b),
        sprintf("T30 midwifery's safe_percent has not drifted from the mufflyaccess SSOT\n         local: %s\n         ssot : %s", a, b))
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
