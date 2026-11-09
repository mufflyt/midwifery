# =============================================================================
# Medicaid enrollment vs. NPPES practice state: concordance and transition
# classification
# =============================================================================
# Pure classification logic over ALREADY-VALIDATED, ALREADY-MERGED enrollment
# intervals (R/lib/medicaid_enrollment_intervals.R builds those). This file
# answers two separate questions, each with its own category set:
#
#   classify_state_concordance()   ONE NPI-YEAR: does NPPES's reported state
#     agree with the Medicaid-enrolled state(s)? Six mutually exclusive
#     categories (S5 of the spec): Concordant, Discordant, Multistate
#     concordant, Multistate discordant, Not observed, Indeterminate.
#
#   classify_transition_support()  ONE NPPES INTERSTATE MOVE: does an
#     enrollment transition corroborate it? Six mutually exclusive
#     categories (S7): Strong administrative support, Partial
#     administrative support, Preexisting destination enrollment,
#     Contradictory enrollment evidence, No informative enrollment evidence,
#     Indeterminate.
#
# NEITHER FUNCTION PROVES A PHYSICAL MOVE OR CLINICAL PRACTICE. Medicaid
# enrollment is an administrative relationship with a state program -- not a
# claim, not a delivery, not a practice address. A midwife can be
# legitimately enrolled in two states at once, or hold enrollment with no
# claims activity at all. See docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md
# S11 for the full certification -> licensure -> enrollment -> claims ->
# practice -> delivery interpretation ladder this project will not collapse.
# =============================================================================

#' Classify one NPI-year's state concordance
#'
#' Missing evidence is ABSENT evidence, never contrary evidence: an NA
#' `nppes_state` or a non-NA `indeterminate_reason` forces "Indeterminate"
#' rather than falling through to "Discordant"/"Not observed", which would
#' misrepresent "we could not tell" as a resolved finding.
#'
#' @param nppes_state [character] NPPES practice state this NPI-year, or `NA`
#'   if NPPES has no resolvable state that year.
#' @param medicaid_states [list] of character vectors, one per row: the
#'   DISTINCT qualifying Medicaid states for this NPI-year (an empty
#'   `character(0)`, not `NA`, means "qualifying evidence checked, found
#'   none").
#' @param indeterminate_reason [character] `NA` (resolvable) or a reason
#'   string (identity/date/status could not be resolved) -- always wins over
#'   whatever the state comparison would otherwise say.
#' @return [character] one of the six categories above, one value per row.
classify_state_concordance <- function(nppes_state, medicaid_states,
                                       indeterminate_reason = NA_character_) {
  n <- length(nppes_state)
  if (length(medicaid_states) != n)
    stop("nppes_state and medicaid_states must be the same length", call. = FALSE)
  indeterminate_reason <- rep_len(indeterminate_reason, n)
  n_states <- vapply(medicaid_states, length, integer(1))
  matches <- vapply(seq_len(n), function(i) {
    !is.na(nppes_state[i]) && nppes_state[i] %in% medicaid_states[[i]]
  }, logical(1))

  dplyr::case_when(
    !is.na(indeterminate_reason) ~ "Indeterminate",
    is.na(nppes_state) ~ "Indeterminate",
    n_states == 0L ~ "Not observed",
    matches & n_states == 1L ~ "Concordant",
    matches & n_states >= 2L ~ "Multistate concordant",
    !matches & n_states >= 2L ~ "Multistate discordant",
    TRUE ~ "Discordant"
  )
}

#' Summarise one state's merged enrollment intervals against a transition
#' window -- the booleans `classify_transition_support()` actually consumes
#'
#' @param intervals [data.frame] this NPI's merged intervals (any state);
#'   filtered internally to `state`. Columns `state`, `interval_start`,
#'   `interval_end` (Date).
#' @param state [character(1)] the state to summarise (origin or
#'   destination).
#' @param window_start,window_end [Date] the prespecified transition window.
#' @return [list] `any_in_window`, `starts_in_window` (an interval's own
#'   start falls inside the window -- NOT merely overlapping it, which
#'   `preexisting` already covers), `ends_in_window` (a NON-open-ended
#'   interval end falls inside the window), `persists_at_window_end`
#'   (an interval covers `window_end`, i.e. is still active then),
#'   `preexisting` (an interval both started before `window_start` AND
#'   overlaps the window -- enrollment that predates the transition).
summarize_state_window_evidence <- function(intervals, state, window_start, window_end) {
  rows <- intervals[intervals$state %in% state, , drop = FALSE]
  overlapping <- rows[rows$interval_start <= window_end & rows$interval_end >= window_start, , drop = FALSE]
  list(
    any_in_window = nrow(overlapping) > 0L,
    starts_in_window = any(overlapping$interval_start >= window_start &
                            overlapping$interval_start <= window_end),
    ends_in_window = any(!is_open_ended(overlapping$interval_end) &
                         overlapping$interval_end >= window_start &
                         overlapping$interval_end <= window_end),
    persists_at_window_end = any(overlapping$interval_start <= window_end &
                                 overlapping$interval_end >= window_end),
    preexisting = any(overlapping$interval_start < window_start)
  )
}

#' Classify one NPPES interstate move's Medicaid transition-support evidence
#'
#' Priority order (first match wins), chosen so a single move cannot satisfy
#' two categories at once:
#'   1. `indeterminate_reason` non-NA -> Indeterminate.
#'   2. Destination enrollment PREDATES the window -> Preexisting destination
#'      enrollment, regardless of anything else that happened -- legitimate
#'      longstanding multistate practice is not evidence of a NEW move.
#'   3. No destination evidence anywhere in the window:
#'        origin enrollment persists through the window -> Contradictory
#'          enrollment evidence (NPPES says they left; Medicaid enrollment
#'          in the origin state says they didn't).
#'        otherwise -> No informative enrollment evidence.
#'   4. Destination enrollment starts within the window (and did not
#'      preexist it):
#'        an origin enrollment ALSO ends within the window -> Strong
#'          administrative support.
#'        otherwise -> Partial administrative support (new destination
#'          enrollment without an observed origin termination, including
#'          continuing/multistate origin enrollment).
#'
#' @param destination_preexisting,destination_starts_in_window,
#'   origin_ends_in_window,origin_persists_in_window,destination_any_in_window,
#'   origin_any_in_window [logical] from `summarize_state_window_evidence()`
#'   applied to the destination and origin states respectively. `NA` is
#'   treated as `FALSE` (absent evidence, not contrary evidence).
#' @param indeterminate_reason [character] `NA`, or a reason that forces
#'   Indeterminate regardless of the booleans above.
#' @return [character] one of the six categories, one value per row.
classify_transition_support <- function(destination_preexisting,
                                        destination_starts_in_window,
                                        origin_ends_in_window,
                                        origin_persists_in_window,
                                        destination_any_in_window,
                                        origin_any_in_window,
                                        indeterminate_reason = NA_character_) {
  n <- length(destination_preexisting)
  absent_as_false <- function(x) { x <- rep_len(x, n); x[is.na(x)] <- FALSE; x }
  dest_pre <- absent_as_false(destination_preexisting)
  dest_starts <- absent_as_false(destination_starts_in_window)
  orig_ends <- absent_as_false(origin_ends_in_window)
  orig_persists <- absent_as_false(origin_persists_in_window)
  dest_any <- absent_as_false(destination_any_in_window)
  orig_any <- absent_as_false(origin_any_in_window)
  indeterminate_reason <- rep_len(indeterminate_reason, n)

  dplyr::case_when(
    !is.na(indeterminate_reason) ~ "Indeterminate",
    dest_pre ~ "Preexisting destination enrollment",
    !dest_any & orig_persists ~ "Contradictory enrollment evidence",
    !dest_any ~ "No informative enrollment evidence",
    dest_starts & orig_ends ~ "Strong administrative support",
    dest_starts ~ "Partial administrative support",
    TRUE ~ "Partial administrative support"
  )
}
