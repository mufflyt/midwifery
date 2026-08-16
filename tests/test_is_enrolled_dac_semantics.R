#!/usr/bin/env Rscript
# =============================================================================
# is_enrolled_dac: enrollment is not affiliation
# =============================================================================
# The defect docs/HANDOFF_is_enrolled_dac.md describes, and the four assertions
# it asks for.
#
# THE DEFECT. `is_enrolled_dac` was derived from the FACILITY-AFFILIATION file:
#
#     is_enrolled_dac = npi %in% enrolled_npis   # enrolled_npis from dac_filtered
#
# That file lists only clinicians who hold a facility affiliation, so every
# Medicare-enrolled clinician WITHOUT hospital privileges was labelled not
# enrolled. Affiliation was standing in for enrollment.
#
# WHY IT IS RETRACTION-LEVEL RATHER THAN A BUG. Nothing crashes. The flag is a
# clean logical, the Table 1 row it feeds is plausible, and the number is simply
# wrong -- the pattern docs/HALL_OF_SHAME.md opens by naming: silent success.
#
# MEASURED on the 17,054-NPI crosswalk against
# DAC_NationalDownloadableFile_2026-06.csv:
#
#     in the national register (truly enrolled)   5,931
#     in the facility-affiliation file            1,665
#     enrolled with NO facility affiliation       4,266
#
# a 3.56x understatement. The handoff estimated 3,319 affected; the measured
# figure is 4,266.
#
# CORRECTED 2026-08-16. My first pass used a 2024-05 copy of the register from
# an external volume and reported 3,912 / 2,817, plus 570 NPIs with a facility
# affiliation but no register entry, which I flagged as an unexplained anomaly.
# It was not an anomaly. Against the correct 2026-06 file the 570 is ZERO --
# they were providers who enrolled between the two vintages. The stale file
# understated the understatement.
#
# Hermetic: the register is a character vector here, so the semantics are
# testable without the 655 MB national file.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Source only what is needed. The file's pipeline entry point downloads a CMS
# dataset at call time; the flag helper does not.
src <- readLines(file.path(root, "R", "lib", "match_npi_to_hospitals.R"), warn = FALSE)
i <- grep("^dac_enrollment_flag <- function", src)
j <- i + which(src[i:length(src)] == "}")[1] - 1L
eval(parse(text = paste(src[i:j], collapse = "\n")))

REGISTER <- c("1000000001", "1000000002", "1000000003")   # DAC national file
AFFILIATED <- c("1000000001", "1000000009")               # facility file

# -----------------------------------------------------------------------------
cat("\n-- the four assertions the handoff asks for --\n")
# -----------------------------------------------------------------------------
{
  # 1. enrolled + NO facility affiliation -> TRUE. This is the whole defect:
  #    2,817 real midwives sat here and were reported FALSE.
  chk(isTRUE(dac_enrollment_flag("1000000002", REGISTER)),
      "H1 enrolled with NO facility affiliation is TRUE")

  # 2. enrolled + facility affiliation -> TRUE
  chk(isTRUE(dac_enrollment_flag("1000000001", REGISTER)),
      "H2 enrolled WITH a facility affiliation is TRUE")

  # 3. not enrolled -> FALSE
  chk(isFALSE(dac_enrollment_flag("1000000099", REGISTER)),
      "H3 absent from the enrollment register is FALSE")

  # 4. missing enrollment EVIDENCE is not silently FALSE. "We did not look" and
  #    "we looked and they are not enrolled" are different claims, and
  #    collapsing them is how the original defect read as a finding rather than
  #    as missing data.
  chk(is.na(dac_enrollment_flag("1000000001", NULL)),
      "H4 no enrollment register supplied yields NA, not FALSE")
  chk(is.na(dac_enrollment_flag("1000000001", character(0))),
      "H4 an EMPTY register also yields NA, not FALSE")
}

# -----------------------------------------------------------------------------
cat("\n-- the two variables must not imply one another --\n")
# -----------------------------------------------------------------------------
{
  # Affiliation must not create enrollment.
  chk(isFALSE(dac_enrollment_flag("1000000009", REGISTER)),
      "S1 a facility affiliation does NOT make someone enrolled")

  # Enrollment must not create affiliation. Asserted on the register itself:
  # nothing in the enrollment path may consult the affiliation set.
  chk(!("1000000002" %in% AFFILIATED) && isTRUE(dac_enrollment_flag("1000000002", REGISTER)),
      "S2 enrollment is established without consulting affiliation at all")

  # Vectorised, because the flag is computed over a whole cohort.
  got <- dac_enrollment_flag(c("1000000001", "1000000002", "1000000099"), REGISTER)
  chk(identical(got, c(TRUE, TRUE, FALSE)),
      sprintf("S3 vectorised over a cohort [%s]", paste(got, collapse = ",")))
}

# -----------------------------------------------------------------------------
cat("\n-- REGRESSION: the affiliation file must never be the register --\n")
# -----------------------------------------------------------------------------
# The defect in its original form: pass the affiliation set as though it were
# the enrollment register and the 2,817 disappear again. This asserts the
# distinction is real rather than a renaming.
{
  as_register <- dac_enrollment_flag("1000000002", AFFILIATED)
  chk(isFALSE(as_register),
      "R1 using the AFFILIATION set as the register reproduces the defect")
  chk(isTRUE(dac_enrollment_flag("1000000002", REGISTER)),
      "R2 using the ENROLLMENT register does not")
  chk(!identical(as_register, dac_enrollment_flag("1000000002", REGISTER)),
      "R3 the two sources give DIFFERENT answers, so the distinction is real")
}

# -----------------------------------------------------------------------------
cat("\n-- C: affiliation is a strict SUBSET of enrollment --\n")
# -----------------------------------------------------------------------------
# A conservation law rather than a unit test. You cannot hold a facility
# affiliation without being enrolled in Medicare, so every affiliated NPI must
# appear in the enrollment register. Measured against the 2026-06 file: all
# 1,665 affiliated NPIs are in the register, none outside it.
#
# This is also the check that would have caught my stale-file mistake
# immediately. Against the 2024-05 register 570 affiliated NPIs sat OUTSIDE it,
# which I reported as an unexplained anomaly when it was really a two-year
# vintage gap. A nonzero count here means the register is older than the
# affiliation file, not that the data is strange.
{
  register <- c("1000000001", "1000000002", "1000000003", "1000000009")
  affiliated <- c("1000000001", "1000000009")
  outside <- setdiff(affiliated, register)
  chk(length(outside) == 0L,
      sprintf("C1 every affiliated NPI is in the enrollment register [%d outside]",
              length(outside)))

  # And the check must be able to fail, or it is decoration.
  stale_register <- c("1000000001", "1000000002")      # missing ...009
  outside_stale <- setdiff(affiliated, stale_register)
  chk(length(outside_stale) == 1L,
      sprintf("C2 a STALE register is detected as affiliations outside it [%d]",
              length(outside_stale)))
}

# -----------------------------------------------------------------------------
cat("\n-- the production call site --\n")
# -----------------------------------------------------------------------------
{
  s <- paste(src, collapse = "\n")
  chk(grepl("is_enrolled_dac = dac_enrollment_flag(", s, fixed = TRUE),
      "P1 the flag is assigned from dac_enrollment_flag()")
  # Comments QUOTE the old line to explain what changed, so strip them first.
  # Grepping the whole file matched the explanation and reported the defect as
  # still present -- a checker fooled by its own documentation.
  code <- src[!grepl("^\\s*#", src)]
  chk(!any(grepl("is_enrolled_dac = npi %in% enrolled_npis", code, fixed = TRUE)),
      "P2 the old affiliation-derived assignment is gone from the CODE")
  chk(any(grepl("is_enrolled_dac = npi %in% enrolled_npis", src, fixed = TRUE)),
      "P2b and is still quoted in a comment, so the change is explained")
  chk(grepl("dac_national_npis", s, fixed = TRUE),
      "P3 the enrollment register is a separate parameter from dac_path")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
