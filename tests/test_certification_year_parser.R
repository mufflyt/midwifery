#!/usr/bin/env Rscript
# =============================================================================
# A date parser that returns NA for every row must never pass as a clean run
# =============================================================================
# analyze_temporal_plausibility.R shipped with:
#
#   cert_year <- function(v) suppressWarnings(as.integer(substr(as.character(v), 1, 4)))
#
# certification_date in the frozen crosswalk is MM/YYYY ("06/2015"), so
# substr(v, 1, 4) is "06/2" and as.integer("06/2") is NA -- for all 22,309 rows,
# silently, under suppressWarnings(). Every accepted match fell through to the
# "not assessable" branch, the summary artifact was written, and the script
# exited 0. The D17 evidence section read "100.0% not assessable", which is
# indistinguishable from a real finding to anyone who did not check the parser.
#
# That is the same failure class as the DuckDB volume defect: a run that reports
# success having measured nothing. This test exists so the parser cannot regress
# to a silent all-NA, in EITHER date spelling.
#
# Hermetic: no crosswalk, no panel, no network, no artifacts. It tests one pure
# function against literals, so it runs on a clean checkout.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "amcb_resolver.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cy <- amcb_certification_year

cat("\n-- P: the spelling the roster actually uses --\n")
{
  # THE REGRESSION. Every one of these is a real certification_date shape from
  # artifacts/amcb_npi_linkage_FROZEN.csv.
  mm <- c("06/2015", "07/2018", "01/2011", "01/2018", "02/2024", "12/1971")
  got <- cy(mm)
  chk(identical(got, c(2015L, 2018L, 2011L, 2018L, 2024L, 1971L)),
      "P1 MM/YYYY parses to the YEAR, not to the first four characters")
  chk(!any(is.na(got)),
      "P2 and none of them is NA -- the defect was 100% NA on exactly this input")
  # The original implementation, kept here so the test states what it rejects.
  old <- suppressWarnings(as.integer(substr(as.character(mm), 1, 4)))
  chk(all(is.na(old)),
      "P3 the substr() parser really did return NA for all of them")
}

cat("\n-- I: an ISO-dated vintage must not break it --\n")
{
  iso <- c("2015-06-01", "1998-12-31", "2026-01-15")
  chk(identical(cy(iso), c(2015L, 1998L, 2026L)),
      "I1 YYYY-MM-DD still parses")
  chk(identical(cy("2015"), 2015L), "I2 a bare year parses")
}

cat("\n-- L: length and type are preserved, so a join cannot shift --\n")
{
  # The verdict logic joins on position. A parser that DROPS unmatched elements
  # -- which regmatches() does by default -- would silently misalign every row
  # after the first unparseable one.
  mixed <- c("06/2015", NA, "", "not a date", "07/2018")
  got <- cy(mixed)
  chk(length(got) == length(mixed),
      "L1 output length equals input length even with unparseable elements")
  chk(is.integer(got), "L2 output is integer")
  chk(identical(got[c(1L, 5L)], c(2015L, 2018L)),
      "L3 the parseable elements keep their positions")
  chk(all(is.na(got[2:4])), "L4 the unparseable ones are NA, not dropped")
  chk(identical(cy(character(0)), integer(0)),
      "L5 zero-length input gives zero-length output, not an error")
}

cat("\n-- N: a year is a year, not any four digits --\n")
{
  chk(is.na(cy("99/9999")), "N1 9999 is not accepted as a year")
  chk(identical(cy("cert 06/2015 issued"), 2015L),
      "N2 an embedded year is found")
}

cat("\n-- S: no caller may define its own copy --\n")
{
  # H4 in ci_hygiene.R catches duplicate top-level definitions repo-wide; this
  # states the specific rule, because a second copy of THIS function is how the
  # all-NA parser comes back in one script while the other stays correct.
  callers <- c("analyze_temporal_plausibility.R",
               "make_temporal_plausibility_figure.R")
  bad <- character(0)
  for (f in callers) {
    if (!file.exists(f)) next
    ln <- readLines(f, warn = FALSE)
    ln <- ln[!grepl("^\\s*#", ln)]
    if (any(grepl("^\\s*cert_year\\s*<-\\s*function", ln))) bad <- c(bad, f)
  }
  chk(length(bad) == 0L,
      sprintf("S1 no caller defines cert_year() itself [%s]",
              if (length(bad)) paste(bad, collapse = ", ") else "none"))
  ok <- vapply(callers, function(f)
    !file.exists(f) || any(grepl("amcb_resolver", readLines(f, warn = FALSE))),
    logical(1))
  chk(all(ok), "S2 every caller sources R/amcb_resolver.R for it")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
