#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 2 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Cycle 1 carried forward two defect classes and fixed only their first
# instances. This cycle finishes both sweeps, and tests the finding that
# matters most: cycle 1's own sweep was incomplete.
#
#   Class D (positional date parsing). str_sub() takes character positions, so
#   it encodes a date FORMAT as an offset. One site was fixed; the sweep found
#   cert_decade still doing it.
#
#   Class K (key conflicts resolved by row order). distinct(.keep_all = TRUE)
#   keeps whichever row sorted first. The ledger estimated 8 sites; the actual
#   count is 14, and one of them is inside R/join_safety.R -- a helper whose
#   name promises the opposite.
#
#   Class C1 (duplicate definitions). Cycle 1 found the RUCC banding rule in
#   three copies and fixed three. There is a fourth.
#
# Run: Rscript tests/test_cycle2_dates_keys.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(stringr)})
source(file.path(root, "R", "lib", "table1_bands.R"))
source(file.path(root, "R", "join_safety.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# The live implementation of cert_decade, lifted verbatim from
# R/07-cohort-composition.R:158 so the test exercises the shipped rule.
cert_decade_live <- function(d) paste0(str_sub(d, -4, -2), "0s")

cat("\n-- BVA --\n")

# T11 (BVA). Decade edges. A year ending in 0 opens a decade and one ending in
# 9 closes it; getting either wrong moves a whole cohort one decade.
{
  y <- c("01/01/1990", "12/31/1999", "01/01/2000", "12/31/2009")
  got <- band_cert_decade(y)
  chk(identical(got, c("1990s", "1990s", "2000s", "2000s")),
      "T11 decade boundaries: years ending 0 open and 9 closes the decade")
}

# T12 (BVA). Empty, NA and zero-length input must not error or fabricate.
{
  chk(identical(band_cert_decade(character(0)), character(0)),
      "T12a zero-length input returns zero-length, not an error")
  chk(all(is.na(band_cert_decade(c(NA_character_, "", "  ")))),
      "T12b NA and blank dates yield NA, not a fabricated decade")
}

# T13 (BVA). Out-of-window years are not plausible certification dates.
{
  chk(is.na(band_cert_decade("01/01/1776")),
      "T13a implausibly early year rejected, not banded")
  chk(is.na(band_cert_decade("01/01/3000")),
      "T13b implausibly late year rejected, not banded")
}

cat("\n-- SEMANTIC --\n")

# T14 (semantic). THE DEFECT. cert_decade must denote a decade regardless of
# which date format the export used. NPPES and the AMCB registry have both
# shipped ISO and US formats; the positional rule silently encodes one of them.
{
  iso <- band_cert_decade("2007-05-12")
  us  <- band_cert_decade("05/12/2007")
  chk(identical(iso, us) && identical(iso, "2000s"),
      sprintf("T14 same day, two formats, same decade [ISO=%s US=%s]", iso, us))
  # ANTI-CEREMONY. The retired rule must FAIL this, or the test proves nothing.
  chk(!identical(cert_decade_live("2007-05-12"), cert_decade_live("05/12/2007")),
      sprintf("T14b the retired positional rule is discriminated against [ISO=%s]",
              cert_decade_live("2007-05-12")))
}

# T15 (semantic). The label must bound the value. "2000s" has to mean a year in
# 2000-2009, which a positional slice cannot guarantee.
{
  labs <- band_cert_decade(c("2007-05-12", "05/12/1998", "1985-01-01"))
  chk(all(grepl("^[0-9]{3}0s$", labs)),
      sprintf("T15 every decade label is a 4-digit year ending in 0, then 's' [got: %s]",
              paste(labs, collapse = ", ")))
}

# T16 (semantic). A helper named assert_unique_keys must not resolve a
# CONFLICT by row order. Deduping identical rows is fine; silently picking one
# of two disagreeing rows is a scientific decision disguised as cleanup.
{
  conflicting <- data.frame(
    certification_number = c("C1", "C1"),
    practice_state       = c("CO", "TX"),
    stringsAsFactors = FALSE)
  out <- tryCatch(
    suppressMessages(assert_unique_keys(conflicting, "certification_number",
                                        "cycle2", dedupe = TRUE)),
    error = function(e) "refused")
  chk(identical(out, "refused") ||
        (is.data.frame(out) && nrow(out) == 2L),
      sprintf("T16 conflicting duplicate keys are not silently resolved by row order [kept: %s]",
              if (is.data.frame(out)) paste(out$practice_state, collapse = "/") else out))
}

# T17 (semantic). Identical duplicate rows carry no conflict, so collapsing
# them is safe and must still work -- the fix for T16 must not over-reject.
{
  identical_dups <- data.frame(
    certification_number = c("C1", "C1"),
    practice_state       = c("CO", "CO"),
    stringsAsFactors = FALSE)
  out <- tryCatch(
    suppressMessages(assert_unique_keys(identical_dups, "certification_number",
                                        "cycle2", dedupe = TRUE)),
    error = function(e) NULL)
  chk(!is.null(out) && nrow(out) == 1L && out$practice_state == "CO",
      "T17 identical duplicate rows still collapse to one")
}

cat("\n-- ADVERSARIAL --\n")

# T18 (adversarial). Row order must not change any answer. This is the
# invariant every .keep_all site violates when values conflict.
{
  d  <- c("05/12/2007", "01/01/1999", "12/31/2010")
  a <- band_cert_decade(d)
  b <- band_cert_decade(rev(d))
  chk(identical(a, rev(b)), "T18 decade assignment is invariant to row order")
}

# T19 (adversarial). Factor input. readr and readxl return factors under
# options this repo does not pin, and as.integer(factor) yields a LEVEL INDEX.
# This is the same trap cycle 1 found in the RUCC rule.
{
  f <- factor(c("05/12/2007", "01/01/1999"))
  chk(identical(band_cert_decade(f), c("2000s", "1990s")),
      "T19 factor dates parse by value, not by level index")
}

# T20 (adversarial). THE SWEEP. Cycle 1 reported the RUCC banding rule in three
# copies and fixed three. Any remaining inline copy is a fourth, and a fix
# applied to three of four is a fix applied to none of them.
{
  files <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)
  inline <- Filter(function(f) {
    if (basename(f) == "table1_bands.R") return(FALSE)
    src <- paste(readLines(f, warn = FALSE), collapse = "\n")
    grepl("rucc[_0-9]*\\s*%in%\\s*1:3", src)
  }, files)
  chk(length(inline) == 0L,
      sprintf("T20 no inline RUCC banding rule outside table1_bands.R [found: %s]",
              if (length(inline)) paste(basename(inline), collapse = ", ") else "none"))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
