#' Full-panel migration move classifier -- shared, testable rule logic
#'
#' Pulled out of `classify_migration_moves_full_panel.R` so
#' `tests/test_migration_move_classification.R` can exercise every rule
#' against small synthetic indices without loading the real cohort panel.
#' See that build script's header and
#' `docs/TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md` for the full
#' design rationale (fused-prediction candidate moves, held-out
#' confirmation via leave-one-out refits, facility_affiliation's
#' descriptive-only exclusion).

GAP_TRANSITIONS <- list(c(2017L, 2018L), c(2023L, 2024L))
FAMILIES <- c("dac_pecos_combined", "open_payments", "tmsis_medicaid")

#' Is this transition one of the two known >=20-month NPPES snapshot gaps?
#'
#' Vectorized over `year_from`/`year_to` (works for a scalar pair, as used
#' inside `classify_apparent_move()`, and for whole data-frame columns, as
#' used when building the Deliverable C summary).
is_gap_transition <- function(year_from, year_to) {
  hits <- vapply(GAP_TRANSITIONS, function(g) year_from == g[1] & year_to == g[2],
                  logical(length(year_from)))
  if (length(year_from) == 1) any(hits) else rowSums(matrix(hits, ncol = length(GAP_TRANSITIONS))) > 0
}

#' Build a direct-observation index for one source family: npi|year -> state
#'
#' No inference, ever. A (npi, year) absent from `claims` for this family is
#' "unavailable"; present with >1 distinct `claimed_value` is "ambiguous"
#' (never arbitrarily resolved); otherwise "usable" with that single state.
#'
#' @param claims `data.frame` with `npi`, `source_family`, `year`, `claimed_value`.
#' @param family Scalar source_family value to index.
#' @return `list(state, status)`, each a named character vector keyed `"npi|year"`.
build_family_index <- function(claims, family) {
  fam <- claims[claims$source_family == family, c("npi", "year", "claimed_value")]
  fam <- unique(fam)
  if (nrow(fam) == 0) {
    empty <- stats::setNames(character(0), character(0))
    return(list(state = empty, status = empty))
  }
  agg <- dplyr::summarise(dplyr::group_by(fam, npi, year),
                           n_vals = dplyr::n_distinct(claimed_value),
                           state = dplyr::first(claimed_value), .groups = "drop")
  agg$status <- ifelse(agg$n_vals > 1, "ambiguous", "usable")
  agg$state <- ifelse(agg$status == "ambiguous", NA_character_, agg$state)
  key <- paste(agg$npi, agg$year, sep = "|")
  list(state = stats::setNames(agg$state, key), status = stats::setNames(agg$status, key))
}

#' Direct-observation lookup against a pre-built family index
#'
#' @param family_idx Named list of `build_family_index()` results, one per family.
#' @return `list(state, status)` for this one (family, npi, year) -- `status`
#'   is always one of `"usable"`, `"ambiguous"`, `"unavailable"`, never `NA`.
lookup_family <- function(family_idx, family, npi_val, year_val) {
  if (!family %in% names(family_idx)) return(list(state = NA_character_, status = "unavailable"))
  key <- paste(npi_val, year_val, sep = "|")
  st <- family_idx[[family]]$status[key]
  if (is.na(st)) return(list(state = NA_character_, status = "unavailable"))
  list(state = unname(family_idx[[family]]$state[key]), status = unname(st))
}

#' Proximity-window fallback lookup -- ONLY for sources that lack a more
#' informative effective interval (dac_pecos_combined, open_payments; never
#' tmsis_medicaid, which already has real interval_start/interval_end dates
#' and is checked at exact-year resolution via `expand_intervals_to_year_
#' claims()` upstream -- windowing it would make its answer LESS precise,
#' not more; never facility_affiliation, which stays descriptive-only
#' regardless of window).
#'
#' The exact year always wins if the source has ANY observation there
#' (usable or ambiguous) -- a window is a backfill for a MISSING year, never
#' an override for an existing one. When the exact year has nothing, nearby
#' years within `window` are searched; if they disagree with each other (or
#' any of them is itself ambiguous), the result is `"ambiguous"`, never
#' arbitrarily picked -- windowing is a sensitivity ASSUMPTION about how
#' long a value stays valid, and disagreement within the window is itself
#' evidence a change happened sometime in that span, not noise to average
#' away.
#'
#' @param window Integer years of proximity to search when the exact year
#'   is missing (0 = no fallback, identical to `lookup_family()`).
#' @return `list(state, status, window_used)` -- `window_used` is `0L` when
#'   the exact year answered directly, otherwise the window size that was
#'   actually searched (for auditing which classifications depend on a
#'   backfilled, less-precise observation).
lookup_family_windowed <- function(family_idx, family, npi_val, year_val, window = 0L) {
  exact <- lookup_family(family_idx, family, npi_val, year_val)
  if (exact$status != "unavailable" || window <= 0L) return(c(exact, list(window_used = 0L)))
  nearby_years <- setdiff(seq(year_val - window, year_val + window), year_val)
  found_states <- character(0); any_ambiguous <- FALSE
  for (y in nearby_years) {
    r <- lookup_family(family_idx, family, npi_val, y)
    if (r$status == "ambiguous") any_ambiguous <- TRUE
    else if (r$status == "usable") found_states <- c(found_states, r$state)
  }
  distinct_states <- unique(found_states)
  if (any_ambiguous || length(distinct_states) > 1)
    return(list(state = NA_character_, status = "ambiguous", window_used = window))
  if (length(distinct_states) == 1)
    return(list(state = distinct_states, status = "usable", window_used = window))
  list(state = NA_character_, status = "unavailable", window_used = window)
}

#' Build a leave-one-out held-out index for one method: variant -> npi|year -> state
#'
#' @param loo `data.frame` with `npi`, `year`, `state`, `variant`, `method`
#'   (non-abstained rows only, matching
#'   `build_leave_one_source_out_sensitivity.R`'s own persisted output).
#' @param method_val Scalar method to filter to (e.g. `"dawid_skene"`).
#' @return Named list, one named character vector (keyed `"npi|year"`) per variant.
build_loo_index <- function(loo, method_val) {
  loo_m <- loo[loo$method == method_val, ]
  if (nrow(loo_m) == 0) return(list())
  lapply(split(loo_m, loo_m$variant), function(sub) stats::setNames(sub$state, paste(sub$npi, sub$year, sep = "|")))
}

#' Does a move survive refitting the model with `family` excluded?
#'
#' A missing variant (e.g. a typo) or a missing npi-year key is a FAILED
#' check (default-deny) -- never a default-approve. See saboteur case #15
#' in docs/TECHNICAL_APPENDIX_MIGRATION_MOVE_CLASSIFICATION.md.
held_out_ok <- function(loo_idx, family, npi_val, year_from, year_to) {
  v <- paste0("drop_", family)
  if (!v %in% names(loo_idx)) return(FALSE)
  vec <- loo_idx[[v]]
  s_from <- vec[paste(npi_val, year_from, sep = "|")]
  s_to   <- vec[paste(npi_val, year_to, sep = "|")]
  if (is.na(s_from) || is.na(s_to)) return(FALSE)
  unname(s_from) != unname(s_to)
}

#' Categorize one eligible (npi, year_from, year_to) pair before classification
#'
#' Abstention is checked BEFORE stability, deliberately: an abstained year's
#' state is `NA`, and `NA == NA` is itself `NA`, not `TRUE` -- if stability
#' were checked first, a doubly-abstained pair could fall through to the
#' `"move"` branch instead of `"abstained"`. `case_when()` only acts on the
#' first condition that evaluates `TRUE` per row, so this order is load-
#' bearing, not cosmetic. Vectorized (works on whole data-frame columns).
#'
#' @return Character vector, one of `"abstained"`, `"stable"`, `"move"`.
classify_row_type <- function(abstain_from, abstain_to, state_from, state_to) {
  dplyr::case_when(
    abstain_from | abstain_to ~ "abstained",
    state_from == state_to ~ "stable",
    TRUE ~ "move"
  )
}

#' Sources windowing is allowed to backfill for -- only those lacking a
#' more informative effective interval. tmsis_medicaid already has real
#' interval_start/interval_end dates (checked at exact-year resolution
#' upstream); windowing it would make its answer less precise, not more.
WINDOWED_FAMILIES <- c("dac_pecos_combined", "open_payments")

#' Classify ONE apparent move (never called for abstained or stable pairs)
#'
#' Rule IDs, in evaluation order (evidence-based rules are checked before
#' the context-only `ART-GAP` fallback -- see saboteur case #7):
#' `CONF-2FAM` / `CONF-2FAM-NOHOLD`, `ART-CONTRA`, `ART-GAP`, `MIXED-SPLIT`,
#' `POSS-SINGLE`, `POSS-NONE`. `nppes` is never counted as a corroborating
#' or contradicting witness -- only `families` (default `FAMILIES`, i.e.
#' the 3 usable non-NPPES, non-facility_affiliation sources) are checked.
#'
#' @param window Proximity-window years for the temporal-sensitivity
#'   analysis (default `0L` = today's strict, exact-year-only behavior,
#'   identical to every call site and test predating this parameter).
#'   Applied only to `WINDOWED_FAMILIES` -- see `lookup_family_windowed()`.
#' @return `list(classification, rule_id, reason, support, contradict,
#'   ambiguous, windowed_families_used)` -- the last element names which
#'   families' support/contradict verdict actually came from a backfilled
#'   nearby year rather than the exact one, for auditing temporal
#'   sensitivity (empty when `window == 0`).
classify_apparent_move <- function(family_idx, loo_idx, npi_val, year_from, year_to,
                                    state_from, state_to, families = FAMILIES, window = 0L) {
  support <- character(0); contradict <- character(0); ambiguous <- character(0)
  windowed_used <- character(0)
  for (fam in families) {
    if (window > 0L && fam %in% WINDOWED_FAMILIES) {
      a <- lookup_family_windowed(family_idx, fam, npi_val, year_from, window)
      b <- lookup_family_windowed(family_idx, fam, npi_val, year_to, window)
      if (a$window_used > 0L || b$window_used > 0L) windowed_used <- c(windowed_used, fam)
    } else {
      a <- lookup_family(family_idx, fam, npi_val, year_from)
      b <- lookup_family(family_idx, fam, npi_val, year_to)
    }
    if (a$status == "ambiguous" || b$status == "ambiguous") { ambiguous <- c(ambiguous, fam); next }
    if (a$status == "unavailable" || b$status == "unavailable") next
    if (identical(a$state, state_from) && identical(b$state, state_to)) support <- c(support, fam)
    else if (identical(a$state, state_from) && identical(b$state, state_from)) contradict <- c(contradict, fam)
  }
  n_support <- length(support); n_contradict <- length(contradict)
  gap <- is_gap_transition(year_from, year_to)

  if (n_support >= 2 && n_contradict == 0) {
    held_out <- all(vapply(support, held_out_ok, logical(1), loo_idx = loo_idx,
                            npi_val = npi_val, year_from = year_from, year_to = year_to))
    if (held_out) {
      return(list(classification = "confirmed", rule_id = "CONF-2FAM",
                  reason = ">=2 independent families directly observe both endpoint states, and the move survives leave-one-out refits excluding each of them",
                  support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
    }
    return(list(classification = "confirmed_not_held_out", rule_id = "CONF-2FAM-NOHOLD",
                reason = ">=2 independent families support the move, but it does not survive a leave-one-out refit excluding at least one of them -- not genuinely held-out confirmation",
                support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
  }
  if (n_contradict >= 1 && n_support == 0) {
    return(list(classification = "administrative_artifact", rule_id = "ART-CONTRA",
                reason = "an independent family shows the origin state persisting through the destination year",
                support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
  }
  if (gap && n_support == 0 && n_contradict == 0) {
    return(list(classification = "administrative_artifact", rule_id = "ART-GAP",
                reason = "measured across a known >=20-month NPPES snapshot gap, mechanically inflating apparent-move counts -- a transition-level mechanism, not NPI-specific evidence",
                support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
  }
  if (n_support >= 1 && n_contradict >= 1) {
    return(list(classification = "indeterminate", rule_id = "MIXED-SPLIT",
                reason = "independent families disagree with each other, not just with NPPES -- an unexplained disagreement is not automatically an artifact",
                support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
  }
  if (n_support == 1 && n_contradict == 0) {
    return(list(classification = "possible", rule_id = "POSS-SINGLE",
                reason = "supported by exactly one independent family -- insufficient for independent confirmation",
                support = support, contradict = contradict, ambiguous = ambiguous,
                windowed_families_used = windowed_used))
  }
  list(classification = "possible", rule_id = "POSS-NONE",
       reason = "no other source has any direct observation of either endpoint year for this NPI",
       support = support, contradict = contradict, ambiguous = ambiguous,
       windowed_families_used = windowed_used)
}
