#!/usr/bin/env Rscript
# =============================================================================
# Affiliation status: the claims each evidence combination is allowed to make
# =============================================================================
# The ruling this enforces is in docs/DECISIONS_CONTRACT.md, "PECOS
# reassignment: temporal interpretation":
#
#   A PPEF reassignment indicates a Medicare reassignment relationship ON FILE
#   IN PECOS AT THE SNAPSHOT DATE. It is neither an employment relationship nor
#   an all-time affiliation history.
#
# Two errors this file exists to prevent, both of which the project has already
# made once:
#
#   1. Calling a billing relationship EMPLOYMENT. PECOS records where benefits
#      are paid; CMS tells practitioners to withdraw when employment ends, which
#      is a different fact and one they may not have done.
#
#   2. Calling a PECOS-only relationship HISTORICAL. That was the original D6
#      framing, and it was wrong: PPEF is restricted to currently-approved
#      enrollments, so it was never a cumulative history. A PECOS-only pair may
#      be a genuine concurrent billing relationship Care Compare does not
#      display, or an administratively stale record. Those are different facts
#      and the data cannot separate them, so the status must not pick one.
#
# Hermetic. No artifact, no network.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages(library(dplyr))
source(file.path(root, "R", "lib", "organization_affiliation_status.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
# Named aff_status, not st: test_adapt_license_bridge_to_reconcile.R already
# defines st() at top level, and ci_hygiene H4 caught the collision.
aff_status <- function(p, cc, np, loc = NA, contra = FALSE)
  classify_affiliation_status(p, cc, np, loc, contra)

# =============================================================================
cat("\n-- S: each combination gets the status it has earned --\n")
# =============================================================================
{
  chk(identical(aff_status(TRUE,  TRUE,  TRUE, TRUE),  "high_confidence_current"),
      "S1 both current arms plus agreeing location -> high_confidence_current")
  chk(identical(aff_status(TRUE,  TRUE,  FALSE),       "high_confidence_current"),
      "S2 both current arms, no location available -> still high confidence")
  chk(identical(aff_status(FALSE, TRUE,  FALSE),       "probable_current"),
      "S3 Care Compare alone -> probable_current")
  chk(identical(aff_status(TRUE,  FALSE, FALSE),       "medicare_reassignment_only"),
      "S4 PECOS alone -> medicare_reassignment_only")
  chk(identical(aff_status(FALSE, FALSE, TRUE),        "address_only"),
      "S5 a shared address alone -> address_only")
  chk(identical(aff_status(FALSE, FALSE, FALSE),       "unknown"),
      "S6 no evidence -> unknown")
  chk(identical(aff_status(TRUE,  TRUE,  TRUE, TRUE, TRUE), "conflicting"),
      "S7 a positive contradiction outranks everything else")
}

# =============================================================================
cat("\n-- H: PECOS-only is NOT historical, and NOT current --\n")
# =============================================================================
# The correction at the centre of D6.
{
  s <- aff_status(TRUE, FALSE, FALSE)
  chk(!grepl("histor|former|past|ended", s),
      sprintf("H1 the PECOS-only status makes no claim about the past [%s]", s))
  chk(!is_current_affiliation(s),
      "H2 and it is not counted as a current affiliation either")
  chk(identical(s, "medicare_reassignment_only"),
      "H3 it says exactly what is known: a reassignment is on file")

  # It must not be silently upgraded by weak corroboration. An address match is
  # not evidence that a billing relationship is current.
  chk(!is_current_affiliation(aff_status(TRUE, FALSE, TRUE)),
      "H4 an address match does not promote PECOS-only to current")
}

# =============================================================================
cat("\n-- E: nothing anywhere is called employer --\n")
# =============================================================================
{
  all_st <- c(aff_status(TRUE,TRUE,TRUE,TRUE), aff_status(FALSE,TRUE,FALSE), aff_status(TRUE,FALSE,FALSE),
              aff_status(FALSE,FALSE,TRUE), aff_status(FALSE,FALSE,FALSE),
              aff_status(TRUE,TRUE,TRUE,TRUE,TRUE))
  chk(!any(grepl("employ", all_st)),
      "E1 no status contains the word employ")
  src <- paste(readLines(file.path(root, "R", "lib",
                                   "organization_affiliation_status.R"),
                         warn = FALSE), collapse = "\n")
  code <- {
    ln <- readLines(file.path(root, "R", "lib",
                              "organization_affiliation_status.R"), warn = FALSE)
    paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
  }
  # The word may appear in comments explaining why it is not used.
  chk(!grepl('"[^"]*employer[^"]*"', code),
      "E2 no string literal in the code names an employer")
  chk(grepl("DECISIONS_CONTRACT", src, fixed = TRUE),
      "E3 the file points at the ruling it implements")
}

# =============================================================================
cat("\n-- A: absent evidence is not contrary evidence --\n")
# =============================================================================
# NA means an arm was not consulted. Treating it as FALSE would let a source
# nobody checked argue against an affiliation.
{
  chk(identical(aff_status(NA, NA, NA), "unknown"),
      "A1 all arms NA -> unknown, not a negative claim")
  chk(identical(aff_status(NA, TRUE, NA), "probable_current"),
      "A2 an NA arm does not veto a positive one")
  chk(identical(aff_status(TRUE, NA, NA), "medicare_reassignment_only"),
      "A3 an unconsulted Care Compare does not make PECOS-only weaker")
  # A missing location must not downgrade two agreeing arms.
  chk(identical(aff_status(TRUE, TRUE, FALSE, NA), aff_status(TRUE, TRUE, FALSE, TRUE)),
      "A4 a missing location does not downgrade two agreeing arms")
}

# =============================================================================
cat("\n-- O: the ordering is usable and monotone --\n")
# =============================================================================
{
  chk(length(AFFILIATION_STATUS_LEVELS) == 5L,
      "O1 the ranked levels are declared once, not per caller")
  idx <- function(s) match(s, AFFILIATION_STATUS_LEVELS)
  chk(idx("high_confidence_current") > idx("probable_current"),
      "O2 two arms outrank one")
  chk(idx("probable_current") > idx("medicare_reassignment_only"),
      "O3 a current listing outranks a reassignment on file")
  chk(idx("medicare_reassignment_only") > idx("address_only"),
      "O4 a reassignment on file outranks a shared address")
  chk(idx("address_only") > idx("unknown"),
      "O5 weak evidence outranks none")
  # conflicting is deliberately OUTSIDE the ladder: it is a finding to look at,
  # not a rung.
  chk(is.na(idx("conflicting")),
      "O6 conflicting is not a rung on the ladder")
  chk(!is_current_affiliation("conflicting"),
      "O7 and is not counted as current")
}

# =============================================================================
cat("\n-- V: vectorised, because it runs over the whole cohort --\n")
# =============================================================================
{
  got <- aff_status(c(TRUE, FALSE, TRUE), c(TRUE, TRUE, FALSE), c(FALSE, FALSE, FALSE))
  chk(identical(got, c("high_confidence_current", "probable_current",
                       "medicare_reassignment_only")),
      sprintf("V1 vectorised over three pairs [%s]", paste(got, collapse = ", ")))
  chk(identical(is_current_affiliation(got), c(TRUE, TRUE, FALSE)),
      "V2 is_current_affiliation() is vectorised too")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
