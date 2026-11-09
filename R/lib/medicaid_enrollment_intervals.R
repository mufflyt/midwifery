# =============================================================================
# Medicaid Provider Enrollment Segments: validation and interval construction
# =============================================================================
# This file owns turning raw T-MSIS enrollment-segment ROWS into validated,
# non-overlapping (NPI, state) ENROLLMENT INTERVALS. It does not decide what
# an interval means for geographic concordance (R/lib/medicaid_state_concordance.R)
# -- it only decides which rows are real enrollment evidence, and how to merge
# them without inventing continuity the source data does not support.
#
# CODE SEMANTICS, established empirically before any logic here was written
# (not assumed -- see docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md
# S2 for the full inspection):
#   ENRL_STATUS_CD: ACTIVE (01-06) and TERM (60-83) both represent REAL
#     enrolled time -- TERM describes why/how a real enrollment ended, not a
#     null enrollment. DENIED (20-24) and PENDING (40-47) are NOT real
#     enrollment: an application that was denied or never finished processing
#     was never actually enrolled, even though T-MSIS gives it a segment with
#     dates.
#   PRVDR_TYPE: '03' = INDIVIDUAL practitioner, vs '01' FACILITY / '02' GROUP.
#     This cohort is individual clinicians; rows under any other code are
#     excluded from person-level linkage, and the exclusion count is reported
#     rather than silently dropped.
#   9999-12-31 (and the near-identical 9999-12-30 seen in one release) is an
#     OPEN-ENDED sentinel, not a literal observed end date. is_open_ended()
#     below is how callers distinguish the two rather than treating 9999 as a
#     real calendar year.
# =============================================================================

#' The fixed fifteen-character prefix the NPI check digit is computed against
#'
#' Per the NPI Final Rule (45 CFR 162.406): the check digit is a Luhn digit
#' over the constant "80840" followed by the NPI's own first nine digits.
NPI_LUHN_PREFIX <- "80840"

#' Literal placeholder NPI values seen in this dataset's NPI column
#'
#' Documented directly on opendata.hhs.gov: "Some source records use the
#' literal value 0000000000" for a row with no qualifying source NPI. Any
#' all-same-digit ten-character string is treated the same way -- a human
#' placeholder pattern, not a value anyone was ever issued.
is_placeholder_npi <- function(npi) {
  npi <- as.character(npi)
  ten_digits <- grepl("^[0-9]{10}$", npi)
  all_same_digit <- grepl("^(.)\\1{9}$", npi)
  ten_digits & all_same_digit
}

#' Luhn check-digit validation for a 10-digit NPI
#'
#' A ten-digit, non-placeholder string can still be garbage (a state internal
#' ID, a typo, a shifted column) -- this is the one check that actually
#' verifies the NPI was constructed the way NPPES constructs real ones.
#'
#' @param npi [character] candidate NPI values.
#' @return [logical] TRUE where the value is a 10-digit string whose last
#'   digit is the correct Luhn check digit over `NPI_LUHN_PREFIX` + its own
#'   first nine digits. FALSE for anything else, including NA and
#'   non-10-digit strings -- never NA itself, so callers can use this
#'   directly in `dplyr::filter()`.
npi_check_digit_valid <- function(npi) {
  npi <- as.character(npi)
  ok_format <- !is.na(npi) & grepl("^[0-9]{10}$", npi)
  luhn_check_digit <- function(payload14) {
    digits <- as.integer(strsplit(payload14, "")[[1]])
    from_right <- rev(digits)
    double_at <- seq(1, length(from_right), by = 2)
    from_right[double_at] <- from_right[double_at] * 2
    from_right[from_right > 9] <- from_right[from_right > 9] - 9L
    as.integer((10L - (sum(from_right) %% 10L)) %% 10L)
  }
  out <- rep(FALSE, length(npi))
  idx <- which(ok_format)
  if (!length(idx)) return(out)
  payloads <- paste0(NPI_LUHN_PREFIX, substr(npi[idx], 1, 9))
  expected <- vapply(payloads, luhn_check_digit, integer(1))
  actual <- as.integer(substr(npi[idx], 10, 10))
  out[idx] <- expected == actual
  out
}

#' A ten-digit NPI candidate validated enough to use for person-level linkage
#'
#' Combines format, non-placeholder and Luhn checks into the one predicate
#' every caller should actually filter on, rather than three separate ones a
#' caller could apply inconsistently or forget.
#'
#' @param npi [character] candidate NPI values.
#' @return [logical], never NA.
is_valid_individual_npi <- function(npi) {
  npi <- as.character(npi)
  format_ok <- !is.na(npi) & grepl("^[0-9]{10}$", npi)
  format_ok & !is_placeholder_npi(npi) & npi_check_digit_valid(npi)
}

#' Status-code families, enumerated as an ALLOWLIST, not a denylist
#'
#' FAIL-CLOSED on purpose: every one of the 43 `ENRL_STATUS_CD` values this
#' dataset actually uses was inspected before this file was written (see the
#' technical appendix S2), and ACTIVE/TERM are exactly the ones that
#' represent real enrollment time. A denylist of DENIED/PENDING codes would
#' silently treat any FUTURE or unexpected code as qualifying; this allowlist
#' instead treats an unrecognised code as non-qualifying until someone
#' deliberately adds it here with the same inspection discipline.
#' @family medicaid-codes
MEDICAID_ACTIVE_STATUS_CODES <- c("01", "02", "03", "04", "05", "06")
MEDICAID_TERM_STATUS_CODES <- c(
  "60", "61", "62", "63", "64", "65", "66", "67", "68", "69",
  "70", "71", "72", "73", "74", "75", "76", "77", "78", "79",
  "80", "81", "82", "83")
MEDICAID_QUALIFYING_STATUS_CODES <- c(MEDICAID_ACTIVE_STATUS_CODES, MEDICAID_TERM_STATUS_CODES)
MEDICAID_DENIED_PENDING_CODES <- c(
  "20", "21", "22", "23", "24",                                # DENIED
  "40", "41", "42", "43", "44", "45", "46", "47")              # PENDING

#' Does this status code represent real (ACTIVE or TERM) enrollment time?
#'
#' @param status_cd [character] `ENRL_STATUS_CD` values.
#' @return [logical], never NA; NA, or any code outside the known ACTIVE/TERM
#'   allowlist, returns FALSE (absent evidence, not enrollment evidence).
is_qualifying_enrollment_status <- function(status_cd) {
  as.character(status_cd) %in% MEDICAID_QUALIFYING_STATUS_CODES
}

#' Is this provider-type code an individual practitioner?
#'
#' @param prvdr_type [character] `PRVDR_TYPE` values.
#' @return [logical], never NA.
is_individual_provider_type <- function(prvdr_type) {
  as.character(prvdr_type) %in% "03"
}

#' Valid USPS/territory state codes T-MSIS actually uses
#'
#' 50 states, DC, and the four territories observed in this dataset (PR, VI,
#' GU; AS and MP are included for completeness of the USPS territory list
#' even though neither was observed in the enrollment_segments table as of
#' this writing -- an unobserved-but-valid code is not the same defect as an
#' invalid one, so both are named here rather than inferring the list from
#' whatever happens to appear in one pull).
VALID_MEDICAID_STATE_CODES <- c(
  state.abb, "DC", "PR", "VI", "GU", "AS", "MP")

#' Is this a real Medicaid/CHIP jurisdiction code?
#' @param state_cd [character] `STATE_CD` values.
#' @return [logical], never NA.
is_valid_medicaid_state <- function(state_cd) {
  as.character(state_cd) %in% VALID_MEDICAID_STATE_CODES
}

#' The open-ended sentinel end-dates this dataset uses
#'
#' Both forms have been observed: 9999-12-31 (the documented sentinel) and
#' 9999-12-30 (one day off, seen in at least one release's MAX(ENRL_END_DT)).
#' Treated identically -- both mean "still active as of the pull", neither is
#' a literal historical date.
MEDICAID_OPEN_ENDED_SENTINELS <- as.Date(c("9999-12-31", "9999-12-30"))

#' Is this end date the open-ended sentinel rather than a real observed date?
#' @param end_dt [Date] `ENRL_END_DT`, already parsed.
#' @return [logical], never NA; NA input returns FALSE.
is_open_ended <- function(end_dt) {
  !is.na(end_dt) & end_dt %in% MEDICAID_OPEN_ENDED_SENTINELS
}

#' Parse ENRL_START_DT/ENRL_END_DT, flagging rather than silently dropping
#' rows a naive `as.Date()` would fail or misread.
#'
#' @param start_dt,end_dt [character] raw date strings, "YYYY-MM-DD" expected.
#' @return [tibble] `start`, `end` (Date), `date_issue` (character, one of
#'   `NA` (clean), `"missing_start"`, `"missing_end"`, `"unparseable"`,
#'   `"start_after_end"`).
normalize_enrollment_dates <- function(start_dt, end_dt) {
  n <- max(length(start_dt), length(end_dt))
  start_raw <- as.character(start_dt); end_raw <- as.character(end_dt)
  start <- suppressWarnings(as.Date(start_raw))
  end <- suppressWarnings(as.Date(end_raw))
  issue <- dplyr::case_when(
    is.na(start_raw) | !nzchar(start_raw) ~ "missing_start",
    is.na(end_raw) | !nzchar(end_raw) ~ "missing_end",
    is.na(start) | is.na(end) ~ "unparseable",
    start > end ~ "start_after_end",
    TRUE ~ NA_character_
  )
  tibble::tibble(start = start, end = end, date_issue = issue)
}

#' Merge overlapping or contiguous qualifying segments into enrollment
#' intervals, per (NPI, state)
#'
#' GAPS-AND-ISLANDS over a RUNNING MAX of prior end-dates (not merely the
#' immediately preceding row), so containment is caught regardless of
#' whatever order the source rows happen to arrive in. Two segments one day
#' apart are treated as contiguous (a Friday termination followed by a
#' Monday reinstatement is not a real gap in coverage); two segments more
#' than one day apart are not merged, even in the same state.
#'
#' Rows must already be restricted to qualifying evidence before calling
#' this (see `is_qualifying_enrollment_status()`, `is_individual_provider_type()`,
#' `is_valid_individual_npi()`) -- this function merges intervals, it does
#' not decide which rows are real enrollment.
#'
#' @param segments [data.frame] with `npi`, `state`, `start` (Date), `end`
#'   (Date) -- already validated, one row per qualifying source segment.
#' @return [tibble] `npi`, `state`, `interval_start`, `interval_end`, one row
#'   per merged, non-overlapping interval.
merge_enrollment_intervals <- function(segments) {
  if (!nrow(segments))
    return(tibble::tibble(npi = character(), state = character(),
                          interval_start = as.Date(character()),
                          interval_end = as.Date(character())))
  segments |>
    dplyr::arrange(.data$npi, .data$state, .data$start) |>
    dplyr::group_by(.data$npi, .data$state) |>
    dplyr::mutate(
      running_max_end = dplyr::lag(cummax(as.numeric(.data$end))),
      new_group = dplyr::if_else(
        is.na(.data$running_max_end) |
          as.numeric(.data$start) > .data$running_max_end + 1L,
        1L, 0L),
      grp = cumsum(.data$new_group)
    ) |>
    dplyr::group_by(.data$npi, .data$state, .data$grp) |>
    dplyr::summarise(interval_start = min(.data$start),
                     interval_end = max(.data$end), .groups = "drop") |>
    dplyr::select(-dplyr::any_of("grp")) |>
    tibble::as_tibble()
}

#' Flag genuinely CONTRADICTORY raw segments: two qualifying rows for the
#' same (NPI, state) whose date ranges overlap but whose status families
#' disagree (one says this period was active enrollment under a status that
#' later became terminated for one reason, another row claims a DIFFERENT
#' status for an overlapping span). This is a narrower check than "any
#' overlap" -- status-compatible overlaps (two ACTIVE rows, or an ACTIVE row
#' and the TERM row that closes it) are ordinary source duplication and are
#' handled by `merge_enrollment_intervals()`; a contradiction is preserved
#' for adjudication, per spec, rather than silently resolved by picking one.
#'
#' @param segments [data.frame] `npi`, `state`, `start`, `end`, `status_family`
#'   (character; caller's own grouping, e.g. the first digit of ENRL_STATUS_CD).
#' @return [tibble] one row per contradicting PAIR: `npi`, `state`,
#'   `start_a`, `end_a`, `status_family_a`, `start_b`, `end_b`, `status_family_b`.
#'
#' IMPLEMENTATION NOTE: a pairwise `combn()` per (npi, state) group was tried
#' first and measured as the actual bottleneck on real data -- minutes for
#' ~85,000 rows across tens of thousands of mostly-tiny groups, almost
#' entirely per-group R-level overhead, not large-group combinatorics.
#' `data.table::foverlaps()` does the same interval self-join as a single
#' vectorised operation (0.06s for 60,000 rows / 20,000 groups in testing)
#' and is used here internally; the function's own interface is still a
#' plain data.frame in, tibble out, so nothing about the three call sites
#' or the tests that exercise this function needed to change.
detect_contradictory_segments <- function(segments) {
  empty <- tibble::tibble(npi = character(), state = character(),
                          start_a = as.Date(character()), end_a = as.Date(character()),
                          status_family_a = character(),
                          start_b = as.Date(character()), end_b = as.Date(character()),
                          status_family_b = character())
  if (!nrow(segments)) return(empty)
  dt <- data.table::as.data.table(segments)
  x <- data.table::copy(dt); y <- data.table::copy(dt)
  data.table::setkeyv(x, c("npi", "state", "start", "end"))
  data.table::setkeyv(y, c("npi", "state", "start", "end"))
  hits <- data.table::foverlaps(x, y, type = "any", which = TRUE, nomatch = NULL)
  hits <- hits[hits$xid < hits$yid, ]
  if (!nrow(hits)) return(empty)
  a <- dt[hits$xid, ]; b <- dt[hits$yid, ]
  keep <- a$status_family != b$status_family
  tibble::tibble(npi = a$npi[keep], state = a$state[keep],
                 start_a = a$start[keep], end_a = a$end[keep],
                 status_family_a = a$status_family[keep],
                 start_b = b$start[keep], end_b = b$end[keep],
                 status_family_b = b$status_family[keep])
}

#' Normalise `midwife_panel.csv`'s inconsistently formatted snapshot_date
#'
#' Observed directly across panel builds: "2020-10-11" alongside bare
#' "20201011" (no separators) for the same column. A plain `as.Date()`
#' silently returns NA for the eight-digit form rather than erroring, which
#' would make every NPI-year from whichever build years used that form
#' quietly drop out of anything keyed on this date -- reformat the
#' eight-digit case to ISO before parsing rather than let that happen.
#'
#' @param x [character] raw `snapshot_date` values.
#' @return [Date], one per input value; `NA` only for genuinely unparseable
#'   input, never for the eight-digit form.
normalize_snapshot_date <- function(x) {
  eight_digit <- grepl("^[0-9]{8}$", x)
  reformatted <- ifelse(eight_digit,
                        paste(substr(x, 1, 4), substr(x, 5, 6), substr(x, 7, 8), sep = "-"),
                        x)
  suppressWarnings(as.Date(reformatted))
}
