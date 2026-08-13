#!/usr/bin/env Rscript
# =============================================================================
# Age-at-certification validator -- tests
# =============================================================================
# Confirms the free consistency check on an acquired year-of-birth against the
# already-scraped certification_date (MM/YYYY): each plausibility class is
# reached, the derived covariate is correct, and impossible inputs are labelled
# (never dropped, never leaked into age_at_certification).
#
# reference_year is pinned so the "born in the future" check is deterministic.
#
# Run: Rscript tests/test_validate_age_at_certification.R   (exit 1 on failure)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

suppressPackageStartupMessages({
  library(dplyr); library(stringr)
})
source(file.path(root, "validate_age_at_certification.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

roster <- tibble::tibble(
  certification_number = c("C1", "C2", "C3", "C4", "C5", "C6", "C7"),
  certification_date = c(
    "06/2015",  # C1 plausible
    "01/2011",  # C2 young: 2011 - 1999 = 12
    "05/2017",  # C3 implausible birth year (1850)
    "01/2020",  # C4 old: 2020 - 1940 = 80
    "01/2011",  # C5 born after cert: 2011 - 2015 = -4
    "03/2018",  # C6 incomplete: birth year missing
    ""          # C7 incomplete: no parseable cert year
  ),
  birth_year = c("1985", "1999", "1850", "1940", "2015", NA, "1980")
)

res <- validate_age_at_certification(roster, reference_year = 2026L)
d <- res$data
flag_of <- function(id) d$age_flag[d$certification_number == id]
age_of  <- function(id) d$age_at_certification[d$certification_number == id]

cat("\n-- plausibility flags --\n")
chk(flag_of("C1") == "plausible", "normal record is plausible")
chk(flag_of("C2") == "implausibly_young_at_certification", "certified at 12 flagged young")
chk(flag_of("C3") == "implausible_birth_year", "birth year 1850 flagged (before age check)")
chk(flag_of("C4") == "implausibly_old_at_certification", "certified at 80 flagged old")
chk(flag_of("C5") == "born_after_certification", "born after certification flagged")
chk(flag_of("C6") == "incomplete", "missing birth year is incomplete")
chk(flag_of("C7") == "incomplete", "unparseable certification date is incomplete")

cat("\n-- covariate value + no leakage --\n")
chk(age_of("C1") == 30L, "age_at_certification computed correctly (2015-1985=30)")
chk(is.na(age_of("C3")), "implausible birth year does not leak a bogus age")
chk(is.na(age_of("C6")), "incomplete row has no age")

cat("\n-- structure --\n")
chk(nrow(d) == nrow(roster), "no rows dropped")
chk(all(c("certification_year", "age_at_certification", "age_flag") %in% names(d)),
    "annotated columns present")
chk(sum(res$summary$n) == nrow(roster), "summary counts reconcile to row total")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
