# =============================================================================
# The AMCB -> NPI resolution rules, as callable functions
# =============================================================================
# These expressions lived inline in match_amcb_to_npi.R, which means they could
# only be exercised by running the whole pipeline against person-level inputs
# that are gitignored. The single most consequential decision in this
# repository -- which candidate becomes a person's identity, and which people
# stay ambiguous -- had no way to be tested directly.
#
# This is an EXTRACTION, not a change. The bodies are the same expressions,
# moved. tests/test_amcb_resolver_permutation.R then attacks them the way the
# data never will: hundreds of randomised candidate orderings over a fixture
# built to contain exact ties.
#
# WHY ORDER IS THE RIGHT ATTACK. Resolution has two stages with opposite
# properties:
#
#   Stage 1 (here)   counts candidates at the best evidence class. Counting is
#                    order-independent, so this SHOULD be permutation-invariant
#                    -- and "should be" is precisely the kind of claim that is
#                    worth testing rather than assuming.
#
#   Stage 2          rank_one_to_one(), a greedy bijection. Greedy algorithms
#                    are order-SENSITIVE by construction. It lives in the
#                    private isochrones repository, so it cannot be tested on a
#                    public runner; see tests/ci_nightly_exceptions.txt.
#
# One subtlety worth stating because it is easy to get wrong: per_npi() uses
# which.min() to pick which candidate row supplies the recorded name variant.
# which.min() returns the FIRST minimum, so when a person has two candidate
# rows for the same NPI tied at the same evidence class, the recorded variant
# depends on row order even though the ACCEPTED IDENTITY does not. The identity
# is the scientific claim; the variant is provenance about which spelling won.
# The permutation test asserts identity invariance strictly, and reports variant
# instability separately rather than pretending it is the same thing.
# =============================================================================

#' Collapse candidates to one row per (person, NPI)
#'
#' @param candidates `data.frame` with at least amcb_id, npi,
#'   name_evidence_class, taxonomy_axis, match_method, match_strategy,
#'   nppes_matched_last, nppes_matched_first, nppes_mid_init, mid_match.
#' @return one row per amcb_id x npi, carrying the strongest evidence class.
amcb_per_npi <- function(candidates) {
  candidates |>
    dplyr::group_by(.data$amcb_id, .data$npi) |>
    dplyr::summarise(
      name_evidence_class = min(.data$name_evidence_class),
      mid_match = max(.data$mid_match),
      taxonomy_axis = dplyr::first(.data$taxonomy_axis),
      match_method = .data$match_method[which.min(.data$name_evidence_class)],
      match_strategy = .data$match_strategy[which.min(.data$name_evidence_class)],
      nppes_matched_last = .data$nppes_matched_last[which.min(.data$name_evidence_class)],
      nppes_matched_first = .data$nppes_matched_first[which.min(.data$name_evidence_class)],
      nppes_mid_init = .data$nppes_mid_init[which.min(.data$name_evidence_class)],
      .groups = "drop")
}

#' Per-person candidate-pool statistics
#'
#' `n_at_best_class` is the number that decides everything downstream: one
#' candidate at the strongest class resolves, more than one is ambiguous.
amcb_pool_stats <- function(per_npi) {
  per_npi |>
    dplyr::group_by(.data$amcb_id) |>
    dplyr::summarise(
      n_candidates_pre_rank = dplyr::n(),
      n_midwifery_candidates = sum(.data$taxonomy_axis == "midwife"),
      n_nursing_only_candidates = sum(.data$taxonomy_axis == "nursing"),
      best_evidence_class = min(.data$name_evidence_class),
      n_at_best_class = sum(.data$name_evidence_class ==
                              min(.data$name_evidence_class)),
      .groups = "drop")
}

#' Resolve people whose strongest evidence class holds exactly one candidate
#'
#' Several candidates at the strongest class means they are indistinguishable
#' on the evidence held. Taxonomy must NOT break that tie: it says nothing
#' about WHICH person the name refers to, only what the NPI does for a living.
amcb_resolve_best_class <- function(per_npi, pool_stats) {
  per_npi |>
    dplyr::inner_join(pool_stats, by = "amcb_id", relationship = "many-to-one") |>
    dplyr::filter(.data$name_evidence_class == .data$best_evidence_class) |>
    dplyr::filter(.data$n_at_best_class == 1L) |>
    dplyr::mutate(
      resolution = dplyr::if_else(.data$name_evidence_class == 1L,
                                  "unique_best_class_with_middle",
                                  "unique_best_class"),
      # Class 5 sits BELOW class 4: a partial surname is weaker evidence than a
      # whole surname within edit distance 2.
      confidence_score = c(1.0, 0.9, 0.7, 0.5, 0.35)[.data$name_evidence_class])
}

#' The people who did not resolve
amcb_quarantined_ids <- function(candidates, resolved) {
  setdiff(unique(candidates$amcb_id), unique(resolved$amcb_id))
}

#' Stage 1 end to end: candidates in, resolved + quarantined out.
#'
#' @return `list(per_npi, pool_stats, resolved, quarantined_ids)`
amcb_resolve <- function(candidates) {
  pn <- amcb_per_npi(candidates)
  ps <- amcb_pool_stats(pn)
  rs <- amcb_resolve_best_class(pn, ps)
  list(per_npi = pn, pool_stats = ps, resolved = rs,
       quarantined_ids = amcb_quarantined_ids(candidates, rs))
}
