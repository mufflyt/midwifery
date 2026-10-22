#!/usr/bin/env Rscript
# =============================================================================
# R/lib/medicaid_enrollment_intervals.R: NPI validation, status/provider-type
# qualification, date normalisation, and interval merging must each fail
# loudly or merge correctly on the specific cases the spec calls out --
# never silently drop or silently merge something that should stay separate.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path(root, "R", "lib", "medicaid_enrollment_intervals.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- NPI VALIDATION --\n")
chk(npi_check_digit_valid("1234567893"),
    "T1 a known-valid Luhn check digit passes")
chk(!npi_check_digit_valid("1234567890"),
    "T2 the same NPI body with a wrong check digit fails")
chk(is_placeholder_npi("0000000000"),
    "T3 the documented literal placeholder 0000000000 is detected")
chk(is_placeholder_npi("1111111111"),
    "T4 any all-same-digit ten-character string is a placeholder")
chk(!is_valid_individual_npi("0000000000"),
    "T5 the placeholder is rejected by the combined validator")
chk(!is_valid_individual_npi("M420017412"),
    paste("T6 the ten-character state-assigned pseudo-ID (M-prefixed) seen",
          "in the warehouse is rejected -- not 10 digits, not a candidate NPI at all"))
chk(!is_valid_individual_npi(NA_character_),
    "T7 NA is rejected, never silently TRUE")
chk(is_valid_individual_npi("1234567893"),
    "T8 a genuinely valid-format, non-placeholder, Luhn-correct NPI passes")

cat("\n-- STATUS AND PROVIDER-TYPE QUALIFICATION --\n")
chk(all(is_qualifying_enrollment_status(c("01", "03", "06", "60", "77", "83"))),
    "T9 every ACTIVE and TERM code qualifies as real enrollment time")
chk(!any(is_qualifying_enrollment_status(c("20", "21", "40", "47"))),
    "T10 every DENIED and PENDING code does NOT qualify")
chk(!is_qualifying_enrollment_status("99"),
    "T11 an unrecognised code fails CLOSED (allowlist, not a denylist)")
chk(!is_qualifying_enrollment_status(NA_character_),
    "T12 NA status does not qualify")
chk(is_individual_provider_type("03") && !is_individual_provider_type("01") &&
      !is_individual_provider_type("02"),
    "T13 only PRVDR_TYPE '03' INDIVIDUAL qualifies")

cat("\n-- STATE CODE VALIDATION --\n")
chk(all(is_valid_medicaid_state(c("CO", "DC", "PR", "GU"))),
    "T14 states, DC, and observed territories validate")
chk(!is_valid_medicaid_state("ZZ"),
    "T15 a non-jurisdiction code is rejected")

cat("\n-- OPEN-ENDED SENTINEL DATES --\n")
chk(is_open_ended(as.Date("9999-12-31")) && is_open_ended(as.Date("9999-12-30")),
    "T16 both observed sentinel forms are recognised as open-ended")
chk(!is_open_ended(as.Date("2024-12-31")),
    "T17 a real, non-sentinel date is NOT treated as open-ended")

cat("\n-- DATE NORMALISATION --\n")
d <- normalize_enrollment_dates(
  c("2020-01-01", "", "2020-05-01", "2020-06-01", NA),
  c("2020-06-01", "2020-06-01", "not-a-date", "2020-01-01", "2020-01-01"))
chk(is.na(d$date_issue[1]), "T18 a clean start<=end pair has no issue flagged")
chk(identical(d$date_issue[2], "missing_start"), "T19 a blank start date is flagged")
chk(identical(d$date_issue[3], "unparseable"), "T20 an unparseable end date is flagged")
chk(identical(d$date_issue[4], "start_after_end"),
    "T21 start after end is flagged rather than silently kept")
chk(identical(d$date_issue[5], "missing_start"), "T22 NA start is flagged, not R's own NA coercion")

cat("\n-- MERGING: OVERLAPPING AND ADJACENT, BUT NOT TOO FAR APART --\n")
segs <- tribble(
  ~npi, ~state, ~start, ~end,
  "A", "CO", as.Date("2020-01-01"), as.Date("2020-06-30"),
  "A", "CO", as.Date("2020-05-01"), as.Date("2020-12-31"),   # overlaps -> merge
  "A", "CO", as.Date("2021-01-01"), as.Date("2021-03-31"),   # 1-day gap -> merge
  "A", "CO", as.Date("2022-06-01"), as.Date("2022-12-31"),   # >1-day gap -> separate
  "A", "WY", as.Date("2020-01-01"), as.Date("2020-12-31")    # different state -> separate
)
merged <- merge_enrollment_intervals(segs)
chk(nrow(merged) == 3L, "T23 three true intervals result from five raw rows")
co_long <- merged[merged$npi == "A" & merged$state == "CO" &
                    merged$interval_start == as.Date("2020-01-01"), ]
chk(nrow(co_long) == 1L && co_long$interval_end == as.Date("2021-03-31"),
    "T24 the overlapping-plus-adjacent CO segments merged into one 2020-01-01..2021-03-31 interval")
co_gap <- merged[merged$npi == "A" & merged$state == "CO" &
                   merged$interval_start == as.Date("2022-06-01"), ]
chk(nrow(co_gap) == 1L,
    "T25 the >1-day-gap CO segment stayed its own interval, not merged backward")
chk(nrow(merged[merged$state == "WY", ]) == 1L,
    "T26 the WY segment never merges across state lines")

cat("\n-- DUPLICATE RECORDS DO NOT INFLATE INTERVAL COUNT --\n")
dup <- tribble(
  ~npi, ~state, ~start, ~end,
  "D", "CO", as.Date("2020-01-01"), as.Date("2020-12-31"),
  "D", "CO", as.Date("2020-01-01"), as.Date("2020-12-31"))  # exact duplicate row
chk(nrow(merge_enrollment_intervals(dup)) == 1L,
    "T27 an exact duplicate row collapses to one interval, not two")

cat("\n-- CONTRADICTORY STATUS, PRESERVED FOR ADJUDICATION --\n")
contra <- tribble(
  ~npi, ~state, ~start, ~end, ~status_family,
  "B", "CO", as.Date("2020-01-01"), as.Date("2020-12-31"), "active",
  "B", "CO", as.Date("2020-06-01"), as.Date("2020-08-31"), "term")
flagged <- detect_contradictory_segments(contra)
chk(nrow(flagged) == 1L,
    "T28 two overlapping segments with different status families are flagged, not silently merged away")
compatible <- tribble(
  ~npi, ~state, ~start, ~end, ~status_family,
  "C", "CO", as.Date("2020-01-01"), as.Date("2020-06-30"), "active",
  "C", "CO", as.Date("2020-07-01"), as.Date("2020-12-31"), "term")
chk(nrow(detect_contradictory_segments(compatible)) == 0L,
    "T29 non-overlapping active-then-term segments (ordinary closure) are NOT flagged as contradictory")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
