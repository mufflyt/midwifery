# =============================================================================
# The candidate reduction is EXACT, and this is why
# =============================================================================
# reconcile_address_parser_universe.R and diagnose_address_match_failures.R both
# compare a 1,544-midwife cohort against a 1.87M-row organization universe by
# first reducing that universe to ~9,600 candidates. The reduction is not a
# sample, and the whole comparison -- including the "+46 uniquely resolved"
# result -- is only valid because of one property:
#
#   EVERY normaliser under comparison PRESERVES THE LEADING HOUSE NUMBER.
#
# Given that, two addresses can produce the same key only if they share the ZIP
# and the house number, so an organization outside that set cannot match under
# ANY of the three normalisers and dropping it cannot change a count.
#
# If the property fails, the reduction silently drops real matches and every
# number in artifacts/address_parser_reconciliation.csv is an undercount. That
# is too load-bearing to leave as a comment, so it is asserted here.
#
# @section Why this cannot run in CI:
# It needs the canonical parser from ~/isochrones, which no runner has. It SKIPS
# loudly rather than passing vacuously -- see the .github/workflows/ci.yml
# header on that distinction. Run it locally before trusting a reconciliation.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else failures <<- c(failures, msg)
}

suppressPackageStartupMessages({
  ok_pkgs <- all(vapply(c("stringr", "postmastr", "yaml"),
                        requireNamespace, logical(1), quietly = TRUE))
})
iso_r <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
parser <- file.path(iso_r, "address_parsing_standardized.R")

if (!ok_pkgs || !file.exists(parser)) {
  cat("\nSKIP: the canonical parser is unavailable here.\n")
  cat(sprintf("      looked for %s\n", parser))
  cat("      This suite asserts the property that makes the candidate reduction\n")
  cat("      exact. It cannot be checked without the parser, and it is NOT\n")
  cat("      being reported as a pass. Run it locally before trusting a\n")
  cat("      reconciliation result.\n")
  quit(status = 0)
}

suppressPackageStartupMessages({library(stringr); library(postmastr); library(yaml)})
source(file.path(root, "R", "lib", "address_keys.R"))
source(file.path(root, "R", "lib", "isochrones_dep.R"))
source(file.path(root, "R", "lib", "address_parser_canonical.R"))

# Literal addresses, not production data: this is a property of the NORMALISER,
# and person-level rows are neither needed nor permitted in a tracked test.
PLAIN <- c("3130 HIGHLAND AVE", "3130 HIGHLAND AVENUE", "361 THIRD STREET",
           "361 3RD ST STE D", "80 JESSE HILL JR DR SE # 26105",
           "1315 JESSE JEWELL PKWY NE STE 200", "4881 SUGAR MAPLE DR BLDG 830",
           "220 CHURCH ST FL 5", "1060 GAFFNEY RD STOP 7400",
           "850 N MAIN STREET EXT STE 2A2", "242 SOUTH COASTAL HWY 17",
           "19505 76TH AVE W", "1 PEARL ST # 2300A")
# Letter-prefixed Wisconsin grid forms and lettered house numbers. These are the
# cases most likely to break the property, which is why they are here.
GRID  <- c("N8150 AMUNDSON COULEE RD", "N2930 BAUER LN",
           "S34W34601 COUNTY ROAD C", "N20302 SUNSET RIDGE LN",
           "W180N8085 TOWN HALL RD")
LETTER <- c("9040A FITZSIMMONS DR", "9040 A JACKSON AVE", "993-D JOHNSON FERRY RD")

lead_digits <- function(a) {
  a <- trimws(as.character(a))
  ifelse(grepl("^[0-9]", a), sub("^([0-9]+).*$", "\\1", a), NA_character_)
}
lead_grid <- function(a) {
  a <- toupper(trimws(as.character(a)))
  ifelse(grepl("^[NSEW][0-9]", a),
         sub("^([NSEW][0-9]+([NSEW][0-9]+)?).*$", "\\1", a), NA_character_)
}

cat("\n-- R1 the canonical parser preserves a numeric house number --\n")
out <- norm_addr_canonical(PLAIN)
for (i in seq_along(PLAIN)) {
  chk(identical(lead_digits(PLAIN[i]), lead_digits(out[i])),
      sprintf("%s -> %s", PLAIN[i], out[i]))
}

cat("\n-- R2 letter-prefixed grid house numbers survive --\n")
og <- norm_addr_canonical(GRID)
for (i in seq_along(GRID)) {
  chk(identical(lead_grid(GRID[i]), lead_grid(og[i])),
      sprintf("%s -> %s", GRID[i], og[i]))
}

cat("\n-- R3 lettered house numbers keep their digits --\n")
ol <- norm_addr_canonical(LETTER)
for (i in seq_along(LETTER)) {
  chk(identical(lead_digits(LETTER[i]), lead_digits(ol[i])),
      sprintf("%s -> %s", LETTER[i], ol[i]))
}

cat("\n-- R4 the same property holds for the two legacy normalisers --\n")
# The reduction is applied to ALL THREE arms of the comparison, so it has to hold
# for the production normaliser too, not only the one being promoted.
for (fn in c("norm_addr", "norm_addr_drop_unit")) {
  f <- get(fn)
  a <- f(PLAIN)
  chk(all(mapply(identical, lead_digits(PLAIN), lead_digits(a))),
      sprintf("%s() preserves every numeric house number", fn))
}

cat("\n-- R5 alignment: output is element-for-element with input --\n")
mixed <- c(PLAIN[1], NA_character_, "", PLAIN[2], "   ")
am <- norm_addr_canonical(mixed)
chk(length(am) == length(mixed), "length preserved with NA and blank inputs")
chk(is.na(am[2]) && is.na(am[3]) && is.na(am[5]),
    "NA and blank inputs come back NA, not shifted or dropped")
chk(!is.na(am[1]) && !is.na(am[4]),
    "usable inputs keep their positions around the unusable ones")

cat("\n-- R6 norm_addr_canonical_keep_unit separates normalisation from policy --\n")
# Substituting the canonical parser wholesale bundles a POLICY change with a
# normalisation fix: it DISCARDS suite designators, while norm_addr() keeps them
# on the documented grounds that two suites in one building are two workplaces.
# Measured on the 1,544 cohort the bundle is +46 uniquely resolved, of which +39
# is achieved by dropping suites alone. This variant isolates the rest.
ku <- norm_addr_canonical_keep_unit(
  c("1942 ATKINSON RD STE 100", "1942 ATKINSON RD STE 500", "1942 ATKINSON RD"))
chk(!identical(ku[1], ku[2]),
    "STE 100 and STE 500 stay DISTINCT (the suite policy is preserved)")
chk(!identical(ku[1], ku[3]),
    "a suited address stays distinct from the bare building address")

# The half it SHOULD fix: suffix and directional spelling.
same <- function(a, b) identical(norm_addr_canonical_keep_unit(a),
                                 norm_addr_canonical_keep_unit(b))
chk(same("250 MAIN STREET", "250 MAIN ST"), "MAIN STREET == MAIN ST")
chk(same("419 6TH STREET", "419 6TH ST"), "6TH STREET == 6TH ST")
chk(same("320 PELHAM AVENUE SW", "320 PELHAM AVE SW"), "AVENUE SW == AVE SW")
chk(same("242 SOUTH COASTAL HWY", "242 S COASTAL HWY"), "SOUTH == S")

# `#` and SUITE are one suite written two ways. Under norm_addr() they key
# differently because `#` becomes whitespace.
chk(same("1 PEARL ST # 2300", "1 PEARL ST STE 2300"), "# 2300 == STE 2300")

# KNOWN UPSTREAM GAPS, pinned as the current behaviour rather than as a wish.
# The canonical parser does NOT normalise spelled ordinals, JUNIOR, NO/SO, or
# EXTENSION. Measured against the 1,544 cohort these affect exactly ONE
# non-matching row, which is why they are recorded and not fixed: the spelled
# forms occur on the ORGANIZATION side, not the cohort side. If a future parser
# version closes them, these assertions flip and should be updated, not deleted.
chk(!same("361 THIRD STREET", "361 3RD ST"),
    "KNOWN GAP: spelled ordinal THIRD is not normalised to 3RD")
chk(!same("80 JESSE HILL JUNIOR DR", "80 JESSE HILL JR DR"),
    "KNOWN GAP: JUNIOR is not normalised to JR")
chk(!same("850 NO MAIN STREET EXTENSION", "850 N MAIN ST EXT"),
    "KNOWN GAP: NO->N and EXTENSION->EXT are not normalised")

cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  cat("\nThe candidate reduction in reconcile_address_parser_universe.R and\n")
  cat("diagnose_address_match_failures.R is NOT exact if this fails. Every count\n")
  cat("they report would be an undercount. Fix before trusting those artifacts.\n")
  quit(status = 1)
}
cat("PASS (0 failures)\n")
