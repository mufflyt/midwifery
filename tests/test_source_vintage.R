#!/usr/bin/env Rscript
# =============================================================================
# Source vintage contract
# =============================================================================
# Pairing comparisons by date is only safe while parse_vintage() reads the dates
# correctly, and the dangerous failure is silent: a filename it cannot parse
# must come back NA, never a plausible-looking guess. These cases pin the
# conventions, pin the REFUSAL to read a bare year as a date, and pin that a gap
# past the limit stops the run.
# =============================================================================
suppressPackageStartupMessages(library(stringr))
source(file.path("R", "lib", "source_vintage.R"))

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}

chk(identical(parse_vintage("npidata_pfile_20050523-20260809.csv"), as.Date("2026-08-09")),
    "NPPES bulk: takes the END date, not the 2005 start date")
chk(identical(parse_vintage("DAC_NationalDownloadableFile_2026-07.csv"), as.Date("2026-07-01")),
    "DAC YYYY-MM -> first of that month")
chk(identical(parse_vintage("revalidation_reassignment_2026-08.csv"), as.Date("2026-08-01")),
    "PECOS monthly revalidation")
chk(identical(parse_vintage("medicaid_provider_enrollment_segments_2026_07_24"),
              as.Date("2026-07-24")),
    "DOGE YYYY_MM_DD directory")
chk(identical(parse_vintage("doctors_and_clinicians_2026_10"), as.Date("2026-10-01")),
    "facility affiliation YYYY_MM directory")

# THE REFUSAL. A bare four-digit year is as often a cohort label or a program
# year as a snapshot date; reading it as January 1st invents an error of up to
# twelve months, which is the exact failure this library exists to prevent.
chk(is.na(parse_vintage("op_2025")), "a bare year is NOT read as a date")
chk(is.na(parse_vintage("midwives_2024_cohort.csv")), "nor is a bare year mid-filename")
chk(is.na(parse_vintage("no_date_here.csv")), "an undateable name returns NA")

chk(identical(parse_vintage(c("x_2026-07.csv", "nope.csv")),
              c(as.Date("2026-07-01"), as.Date(NA))),
    "vectorised, in order, NA preserved")

cands <- c("a_2025-01.csv", "a_2026-07.csv", "a_2026-12.csv")
chk(identical(basename(nearest_vintage(cands, as.Date("2026-08-01"))), "a_2026-07.csv"),
    "nearest_vintage picks the closest, not the newest")
chk(identical(basename(nearest_vintage(cands, as.Date("2030-01-01"))), "a_2026-12.csv"),
    "and the newest when the target is past all of them")
chk(inherits(tryCatch(nearest_vintage(cands, as.Date("2026-08-01"), max_months = 0.1),
                      error = function(e) e), "error"),
    "a nearest candidate beyond max_months errors rather than being used")
chk(inherits(tryCatch(nearest_vintage(c("nope.csv"), Sys.Date()),
                      error = function(e) e), "error"),
    "no parseable candidate errors rather than returning nothing")

chk(abs(vintage_gap_months(as.Date("2025-11-09"), as.Date("2026-10-02")) - 10.7) < 0.1,
    "gap in months matches the measured NPPES/facility-affiliation spread")
chk(vintage_gap_months(as.Date("2026-10-02"), as.Date("2025-11-09")) < 0,
    "the gap is signed, so direction is recoverable")
chk(identical(interval_representative("2025-01-01", "2025-12-31"), as.Date("2025-07-02")),
    "an interval source is represented by its MIDPOINT, not its publication date")

chk(is.numeric(assert_vintage_gap(as.Date("2026-07-01"), as.Date("2026-08-09"), 6)),
    "a pairing inside the limit passes and returns the gap")
chk(inherits(tryCatch(assert_vintage_gap(as.Date("2025-07-02"), as.Date("2026-10-01"), 6),
                      error = function(e) e), "error"),
    "a 15-month pairing is refused at a 6-month limit")
chk(inherits(tryCatch(assert_vintage_gap(as.Date(NA), as.Date("2026-10-01"), 6),
                      error = function(e) e), "error"),
    "an unknown vintage errors rather than passing as a zero gap")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
