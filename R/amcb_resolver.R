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
  # DETERMINISTIC TIEBREAK, 2026-08-16. The picks below were which.min(), which
  # returns the FIRST minimum -- so when a person had two candidate rows for one
  # NPI tied at the same evidence class, the recorded spelling was whichever
  # arrived first. The permutation suite measured it: the recorded variant
  # changed in 231 of 300 candidate orderings while the accepted identity never
  # moved once.
  #
  # Identity was never at risk, so this is not a linkage change. But the
  # recorded spelling is what a human READS in amcb_crosswalk_review_sample_*.csv
  # and amcb_class5_review_census.csv when judging whether a weak match is real,
  # and two reviewers running the pipeline on different days should not be shown
  # different evidence for the same person.
  #
  # Sorting first makes first() a property of the DATA rather than of the row
  # order, and keeps the strongest evidence class winning exactly as before.
  candidates |>
    dplyr::arrange(.data$amcb_id, .data$npi, .data$name_evidence_class,
                   .data$nppes_matched_last, .data$nppes_matched_first,
                   .data$nppes_mid_init) |>
    dplyr::group_by(.data$amcb_id, .data$npi) |>
    dplyr::summarise(
      name_evidence_class = min(.data$name_evidence_class),
      mid_match = max(.data$mid_match),
      taxonomy_axis = dplyr::first(.data$taxonomy_axis),
      match_method = dplyr::first(.data$match_method),
      match_strategy = dplyr::first(.data$match_strategy),
      nppes_matched_last = dplyr::first(.data$nppes_matched_last),
      nppes_matched_first = dplyr::first(.data$nppes_matched_first),
      nppes_mid_init = dplyr::first(.data$nppes_mid_init),
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

#' Normalise NPI taxonomy class labels used by the AMCB resolver
#'
#' Upstream taxonomy class values are data, not control flow. Case or whitespace
#' drift should not change a nursing NPI into primary midwifery evidence, and an
#' unrecognised value should fail closed into its own sensitivity tier.
normalise_npi_tax_class <- function(npi_tax_class) {
  x <- tolower(trimws(as.character(npi_tax_class)))
  x[is.na(npi_tax_class) | !nzchar(x)] <- NA_character_
  dplyr::case_when(
    x == "midwife" ~ "midwife",
    x == "nursing" ~ "nursing",
    TRUE ~ NA_character_
  )
}

#' Assign the linkage tier
#'
#' Extracted from match_amcb_to_npi.R for the same reason as the rules above:
#' the tier decides whether a resolved identity is eligible for the analytic
#' cohort, and that policy could not be exercised without the whole pipeline.
#'
#' Ordering matters and is deliberate. Fuzzy identity evidence is
#' sensitivity-only WHATEVER the taxonomy, so classes 5 and 4 are tested before
#' taxonomy is consulted. Class 5 keeps its own tier rather than being folded
#' into sensitivity_fuzzy: a partial surname and a whole surname within edit
#' distance 2 have different failure modes and must stay separable.
#'
#' @param npi `character`: resolved NPI, NA when unresolved.
#' @param name_evidence_class `integer`: 1 (strongest) to 5 (weakest).
#' @param npi_tax_class `character`: "midwife" or "nursing"; case/whitespace
#'   are normalised. Anything else becomes `sensitivity_unknown_taxonomy` rather
#'   than falling through to `primary_midwifery`.
#' @param demoted_absence_c5 `logical`: class-5 candidate held out by the guard.
#' @param match_status `character`: e.g. "ambiguous_pool", used only when there
#'   is no NPI.
#' @return `character` tier.
amcb_linkage_tier <- function(npi, name_evidence_class, npi_tax_class,
                              demoted_absence_c5 = FALSE,
                              match_status = NA_character_) {
  n <- max(length(npi), length(name_evidence_class), length(npi_tax_class),
           length(demoted_absence_c5), length(match_status))
  rep_to <- function(x) if (length(x) == 1L) rep(x, n) else x
  npi <- rep_to(npi); name_evidence_class <- rep_to(name_evidence_class)
  npi_tax_class <- rep_to(npi_tax_class)
  demoted_absence_c5 <- rep_to(demoted_absence_c5)
  match_status <- rep_to(match_status)

  has <- !is.na(npi) & nzchar(npi)
  tax <- normalise_npi_tax_class(npi_tax_class)
  dplyr::case_when(
    has & name_evidence_class == 5L        ~ "sensitivity_name_component",
    has & name_evidence_class == 4L        ~ "sensitivity_fuzzy",
    has & tax == "nursing"                 ~ "sensitivity_nursing",
    has & tax == "midwife"                 ~ "primary_midwifery",
    has                                    ~ "sensitivity_unknown_taxonomy",
    demoted_absence_c5 %in% TRUE           ~ "quarantined",
    grepl("^ambiguous", match_status)      ~ "quarantined",
    TRUE                                   ~ "unmatched")
}

# --- Temporal separation of tied pools ---------------------------------------
# OFF BY DEFAULT AND NOT WIRED INTO THE PIPELINE. This exists so the question
# "would a temporal rule separate any of the tied records?" can be answered with
# a number instead of an opinion. Nothing calls it during a linkage run.
#
# WHY IT IS NOT ON. The resolver's stated rule is that candidates tied at the
# strongest class are indistinguishable ON THE EVIDENCE HELD, and are
# quarantined rather than separated by something that does not speak to
# identity. That rule is why taxonomy may not break a tie. A first-seen year is
# closer to identity evidence than taxonomy is -- an NPI that did not exist
# until long after a certificant qualified is weak evidence against that
# pairing -- but "closer" is not "settled", and switching it on silently would
# convert 3,044 reported quarantines into matches with no ruling behind them.
# See DECISIONS_CONTRACT.md D17.
#
# WHAT IT DOES NOT DO. It never promotes; it returns the separation a rule WOULD
# produce, leaving the caller to report or discard it. And it refuses to
# separate on a censored year: an NPI first seen in the earliest snapshot may
# have enumerated before the panel begins, so a lead computed against it is a
# bound and cannot rule anything out.

#' Which tied pools would a temporal rule separate?
#'
#' @param cand `data.frame`: candidate-level rows for TIED certificants, with
#'   `amcb_id`, `npi`, `name_evidence_class`, `first_year` and
#'   `first_year_censored` (as written to linkage_candidate_audit.csv).
#' @param cert_year `data.frame`: `amcb_id` and `cert_year`.
#' @param grace `numeric`: years an NPI may precede certification before the
#'   pairing is called implausible. NOT zero -- an RN enumerates years before
#'   she certifies as a midwife, which is the normal career order, so only a
#'   long lead is informative.
#' @return one row per tied `amcb_id`: `n_candidates`, `n_surviving`,
#'   `n_censored_unusable`, `separated` (exactly one survivor), and
#'   `surviving_npi` where separated.
amcb_temporal_separation <- function(cand, cert_year, grace = 25) {
  stopifnot(is.data.frame(cand), is.data.frame(cert_year),
            all(c("amcb_id", "npi", "first_year") %in% names(cand)),
            all(c("amcb_id", "cert_year") %in% names(cert_year)))
  if (!"first_year_censored" %in% names(cand)) cand$first_year_censored <- NA
  d <- merge(cand, cert_year, by = "amcb_id", all.x = TRUE)
  d$lead <- d$cert_year - d$first_year
  # A candidate survives unless the evidence positively rules it out. Unknown
  # and censored years survive: absence of a usable year is not evidence.
  d$ruled_out <- !is.na(d$lead) & !isTRUE_vec(d$first_year_censored) &
    d$lead > grace
  # A year that cannot be used is not evidence FOR a candidate either.
  d$unusable <- isTRUE_vec(d$first_year_censored) | is.na(d$lead)
  sp <- lapply(split(d, d$amcb_id), function(g) {
    surv <- g[!g$ruled_out, , drop = FALSE]
    # SEPARATION REQUIRES A SURVIVOR THAT WAS ACTUALLY ASSESSED. A pool whose
    # sole survivor survived because its year was censored or missing has not
    # been separated -- it has been decided by ignorance, promoting the one
    # candidate nothing is known about over the ones that were ruled out. That
    # is the middle-name veto's manufactured uniqueness in a new costume, and
    # tests T3/T5 exist because the first version of this function did it.
    sep <- nrow(surv) == 1L && nrow(g) > 1L && !surv$unusable[1]
    data.frame(
      amcb_id = g$amcb_id[1],
      n_candidates = nrow(g),
      n_surviving = nrow(surv),
      n_censored_unusable = sum(g$unusable),
      separated = sep,
      separation_blocked_by_censoring =
        nrow(surv) == 1L && nrow(g) > 1L && surv$unusable[1],
      surviving_npi = if (sep) as.character(surv$npi[1]) else NA_character_,
      stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, sp)
  rownames(out) <- NULL
  out
}

#' Vectorised isTRUE: NA and non-logical are FALSE, never NA.
#'
#' Written out because `isTRUE()` is scalar-only and a bare `x %in% TRUE` reads
#' as a membership test rather than a truth test at the call site above, where
#' the difference decides whether a censored row silently rules a candidate out.
isTRUE_vec <- function(x) !is.na(x) & (x %in% TRUE)
