# =============================================================================
# AMCB matching rules and defensive helpers, as testable functions
# =============================================================================
#
# WHY THESE ARE FUNCTIONS AND NOT INLINE EXPRESSIONS. Each one encodes a rule
# that has already been got wrong at least once in this pipeline. Inline in a
# 700-line script they can only be tested through a nine-minute full run and an
# artifact diff; here they are testable in milliseconds and a regression names
# itself. See tests/test_amcb_gates.R.
# =============================================================================

#' Award a contested NPI to a claimant whose evidence STRICTLY dominates.
#'
#' WHY THIS IS BACK, AND WHY IT IS NOT WHAT IT WAS (2026-08-30).
#'
#' Until 2026-08-08 the canonical resolver consumed NPIs greedily: where two
#' certificants claimed one NPI, whoever sorted first took it. That was removed
#' upstream for a stated reason -- "a score gap is not by itself evidence that
#' the higher scorer is the right person" -- and removing it doubled this
#' pipeline's contested stratum from 95 to 188, which is 93 people withdrawn
#' from the cohort by a change in another repository.
#'
#' Measured over those 93 contested NPIs:
#'
#'   56  one claimant holds STRICTLY stronger name evidence than every rival
#'   37  the claimants tie at the same evidence class (10 at class 1, 19 at
#'       class 2, 8 at class 3) -- nothing separates them but sort order
#'
#' So the two rules are not "recover 93" against "recover 0". They are:
#'
#'   quarantine_all     recover  0, decide 0 identities on sort order
#'   strict_dominance   recover 56, decide 0 identities on sort order
#'   greedy             recover 93, decide 37 identities on SORT ORDER
#'
#' Those are the counts on the CONTROL run's contested set. In the shipped
#' pipeline the middle-name fix runs first and shrinks that set, so the rule
#' awards 53 NPIs and 123 rows remain contested. Both numbers are real; they
#' are measured on different candidate sets and neither supersedes the other.
#'
#' strict_dominance is the default because it takes every record the evidence
#' can actually justify and none that it cannot. The 37 are a real tie: two
#' people, one provider record, identical name evidence. Handing that NPI to
#' the lexically smaller certification number is not a linkage result.
#'
#' greedy remains reachable (CONTESTED_RULE=greedy) because reproducing the
#' frozen 16,892 cohort requires it, and a number nobody can regenerate is
#' worse than one whose weakness is written down. It is not the default.
#'
#' @param quarantine the `quarantine` attribute of rank_one_to_one()'s result.
#' @param rule "strict_dominance", "quarantine_all", or "greedy".
#' @return the rows to ADD back to the matched set; zero rows if none qualify.
amcb_award_contested <- function(quarantine, rule = "strict_dominance",
                                 id_col = "enthealth_id") {
  if (!rule %in% c("strict_dominance", "quarantine_all", "greedy")) {
    stop(sprintf("CONTESTED_RULE must be strict_dominance, quarantine_all or greedy; got '%s'",
                 rule), call. = FALSE)
  }
  empty <- quarantine[0, , drop = FALSE]
  if (rule == "quarantine_all" || is.null(quarantine) || !nrow(quarantine)) {
    return(empty)
  }
  require_cols(quarantine, c(id_col, "npi", "resolution_status",
                             "method_priority", "score_total_adj",
                             "confidence_score"), "quarantine")
  cc <- quarantine[quarantine$resolution_status == "ambiguous_contested_npi", ,
                   drop = FALSE]
  if (!nrow(cc)) return(empty)
  # Lexicographic, matching the resolver's own key: priority ascending, then
  # score, then confidence. Ties on ALL THREE are what "not separable" means.
  ord <- order(cc$npi, cc$method_priority, -cc$score_total_adj,
               -cc$confidence_score, cc[[id_col]])
  cc <- cc[ord, , drop = FALSE]
  key <- paste(cc$method_priority, cc$score_total_adj, cc$confidence_score)
  keep <- vapply(split(seq_len(nrow(cc)), cc$npi), function(ix) {
    if (length(ix) < 2L) return(NA_integer_)
    # greedy takes the first row regardless; strict_dominance only when the
    # leader's evidence tuple differs from the runner-up's.
    if (rule == "greedy" || key[ix[1]] != key[ix[2]]) ix[1] else NA_integer_
  }, integer(1))
  keep <- keep[!is.na(keep)]
  if (!length(keep)) return(empty)
  won <- cc[keep, , drop = FALSE]
  # A person cannot win two NPIs, and an NPI cannot go to two people.
  won <- won[!duplicated(won[[id_col]]) & !duplicated(won$npi), , drop = FALSE]
  won
}

#' Assert the BEHAVIOUR of rank_one_to_one(), which is imported from isochrones.
#'
#' THE DEFECT THIS EXISTS TO PREVENT (2026-08-30, cost two dead runs).
#' This pipeline imports five functions from another repository and checked them
#' with `exists(fn)`. Existence is not a contract. Between the frozen linkage and
#' today, isochrones consolidated four copies of rank_one_to_one() and, in doing
#' so, changed two things this script depended on:
#'
#'   1. the default `id_col` moved from "enthealth_id" to "abog_id"
#'   2. it began REQUIRING method_priority, or build_method_priority_lut() in
#'      scope -- a helper the ENT script does not export
#'
#' `exists("rank_one_to_one")` was TRUE throughout. The run died 15 minutes in,
#' twice, on a pipeline whose own header advertises a nine-minute cost.
#'
#' AND THE LOUD FAILURE WAS THE LUCKY ONE. A caller whose data happens to carry a
#' column named by the NEW default gets no error at all: the bijection is then
#' enforced over the wrong identifier and the run looks clean. That is the case
#' this function is really here for, because nothing else in this repository
#' would notice it.
#'
#' So the contract is asserted by BEHAVIOUR on a fixture, not by signature: the
#' resolver must return one row per identifier, must keep the highest
#' score_total within an identifier, and must not award one NPI to two people.
#' Those three properties are what this pipeline actually relies on; a future
#' change that preserves them is not a break, and one that does not is.
#'
#' @param fn the imported function. Injected rather than looked up so the gate
#'   can also be run against a deliberately-wrong stand-in -- see G7.
#' @param id_col the identifier column this pipeline passes explicitly.
#' @return TRUE invisibly, or stop() naming the property that failed.
amcb_assert_rank_one_to_one <- function(fn = NULL, id_col = "enthealth_id") {
  if (is.null(fn)) fn <- get0("rank_one_to_one", mode = "function")
  if (is.null(fn)) {
    stop("rank_one_to_one() is not available; the isochrones import failed",
         call. = FALSE)
  }
  # NO DOMINANCE RULE. The first version of this fixture asserted that the
  # higher-scoring claimant WINS a contested NPI. That was the behaviour until
  # 2026-08-08, when the canonical resolver deliberately removed it: "A score
  # gap is not by itself evidence that the higher scorer is the right person."
  # Asserting the old rule would have pinned this pipeline to semantics that no
  # longer exist and called the current, more conservative resolver a break.
  #
  # Four people covering the three outcomes the pipeline depends on:
  #   A  two candidates, one strictly better   -> resolves to the better one
  #   B  two candidates, identical evidence    -> not identified
  #   C,D  both claim one NPI as their best    -> NEITHER resolves
  fx <- data.frame(
    id  = c("A", "A", "B", "B", "C", "D"),
    npi = c("1000000004", "1000000012", "1000000020", "1000000038",
            "1000000046", "1000000046"),
    match_method = "exact_last_first",
    score_total      = c(4L, 3L, 3L, 3L, 4L, 2L),
    confidence_score = c(0.9, 0.7, 0.7, 0.7, 0.9, 0.5),
    method_priority = 99L,
    stringsAsFactors = FALSE)
  names(fx)[1] <- id_col
  got <- tryCatch(fn(fx, id_col = id_col), error = function(e)
    stop(sprintf("rank_one_to_one() contract: it errored on the fixture: %s",
                 conditionMessage(e)), call. = FALSE))
  ids <- got[[id_col]]
  if (is.null(ids)) {
    stop(sprintf("rank_one_to_one() contract: no '%s' column in the result",
                 id_col), call. = FALSE)
  }
  if (anyDuplicated(ids)) {
    stop("rank_one_to_one() contract: returned more than one row per identifier",
         call. = FALSE)
  }
  if (anyDuplicated(got$npi)) {
    stop("rank_one_to_one() contract: awarded one NPI to two identifiers",
         call. = FALSE)
  }
  keep <- got$npi[ids == "A"]
  if (length(keep) != 1L || keep != "1000000004") {
    stop(paste("rank_one_to_one() contract: did not keep the strictly better",
               "candidate within one identifier"), call. = FALSE)
  }
  if ("B" %in% ids) {
    stop(paste("rank_one_to_one() contract: resolved a person whose two",
               "candidates carry identical evidence"), call. = FALSE)
  }
  if (any(c("C", "D") %in% ids)) {
    stop(paste("rank_one_to_one() contract: awarded a contested NPI to one",
               "claimant. Greedy consumption was removed on 2026-08-08; a",
               "resolver that does this again silently changes who owns every",
               "contested NPI in the crosswalk"), call. = FALSE)
  }
  invisible(TRUE)
}

#' Compare two middle names as TOKEN SETS, not as position-1 initials.
#'
#' THE DEFECT THIS FIXES (2026-08-30, audited over the frozen linkage).
#' The middle-name axis compared substr(middle, 1, 1) on each side. AMCB and
#' NPPES routinely record a woman's middle slot from different conventions --
#' AMCB carries the maiden surname, NPPES the legal middle name, or the two
#' agree on a token that is simply not in the same position:
#'
#'   AMCB "Katherine A. Reinhard" / NPPES "KATHERINE REINHARD RYE"   A vs R
#'   AMCB "Pamela Beth Harvey"    / NPPES "PAMELA H. CAPISTA"        B vs H
#'   AMCB "Alyssa Diane Bantz"    / NPPES "ALYSSA BANTZ HINDMON"     D vs B
#'
#' Every one of those was scored a CONFLICT and vetoed, though the two strings
#' share a token outright. Measured: 82 roster rows had their ONLY exact
#' first-and-last-name candidate deleted this way, 57 of the 88 deleted pairs
#' carrying a CNM credential in NPPES, and the row was then published as "no
#' candidate" -- indistinguishable from a person absent from the registry.
#'
#' WHAT THIS DOES NOT DO. It does not loosen the conflict. Two full middle
#' names sharing no token still conflict (JANE against DENISE), and an initial
#' still conflicts with a token it cannot abbreviate (F against MARILYN). Only
#' POSITION is stopped from manufacturing disagreement. Token-set comparison is
#' already the rule this repository applies to author names in
#' amcb_person_matches(); this makes the middle-name axis consistent with it.
#'
#' @param a_tokens,b_tokens lists of character vectors from
#'   amcb_middle_tokens(), same length.
#' @return character: "corroborates", "conflicts", or "uninformative" -- the
#'   third when either side records no middle name, which is absence of
#'   evidence and must never be read as evidence of difference.
amcb_middle_agreement <- function(a_tokens, b_tokens) {
  # Delegated to the mysterynpi package (2026-09-05), which carries this exact
  # rule -- token sets, concatenated initials, no edit distance, absence
  # uninformative -- together with its full rationale, its regression tests,
  # its caller-assertable contract (run by tests/test_mysterynpi_contracts.R),
  # and a per-push mutation campaign that proves the tests can fail. Verified
  # identical to the implementation this replaces over the 23,543 distinct
  # name values in this cohort's roster.
  mysterynpi::middle_agreement(a_tokens, b_tokens)
}

# initials_string_matches() moved to mysterynpi with the rule that uses it.


#' Count RIVAL NPIs: alternative candidates that are a different PERSON.
#'
#' THE DEFECT THIS EXISTS TO PREVENT (2026-08-10, cost two false demotions).
#' The temporal panel's unit is (NPI x snapshot x name variant), NOT NPI. One
#' person recorded with a middle initial in one snapshot and without it in
#' another supplies BOTH a conflicting and a non-conflicting candidate row. A
#' naive n_distinct(npi[conflict]) therefore counts a person as evidence
#' AGAINST the match that belongs to them:
#'
#'   NPI 1609834951  JOANNE ANDERSON, middle "L" then absent  -> self-vetoed
#'   NPI 1548261456  ANASTASIA OTT HALLISEY, "M." then absent -> self-vetoed
#'
#' The same root cause -- treating a name variant as a distinct person --
#' also produced the WILLIAMS/WRIGHT false mismatch. Anything in this pipeline
#' that counts "alternative candidates" must exclude the matched NPI.
#'
#' @param vetoed_pairs data frame with columns `amcb_id` and `vetoed_npi`:
#'   candidate NPIs removed by a veto, before the veto was applied.
#' @param matched data frame with columns `amcb_id` and `npi`: the NPI that
#'   actually won, one row per amcb_id.
#' @return data frame `amcb_id`, `n_rival_npis` -- distinct OTHER people vetoed.
count_rival_npis <- function(vetoed_pairs, matched) {
  require_cols(vetoed_pairs, c("amcb_id", "vetoed_npi"), "vetoed_pairs")
  require_cols(matched, c("amcb_id", "npi"), "matched")
  if (anyDuplicated(matched$amcb_id)) {
    stop("matched must hold one row per amcb_id; the bijection is upstream",
         call. = FALSE)
  }
  if (!nrow(vetoed_pairs)) {
    return(data.frame(amcb_id = character(0), n_rival_npis = integer(0),
                      stringsAsFactors = FALSE))
  }
  j <- merge(unique(vetoed_pairs[, c("amcb_id", "vetoed_npi")]),
             matched[, c("amcb_id", "npi")], by = "amcb_id", all.x = TRUE)
  # is.na(npi): the person matched nothing, so every vetoed candidate is a
  # rival. Otherwise a rival must carry a DIFFERENT NPI.
  j$is_rival <- is.na(j$npi) | j$vetoed_npi != j$npi
  agg <- stats::aggregate(is_rival ~ amcb_id, data = j, FUN = sum)
  names(agg)[2] <- "n_rival_npis"
  agg$n_rival_npis <- as.integer(agg$n_rival_npis)
  agg[order(agg$amcb_id), , drop = FALSE]
}

#' Fail loudly when a join key or required column is absent.
#'
#' THE DEFECT THIS EXISTS TO PREVENT. A check written as
#' `sum(q$amcb_id %in% co$amcb_id)` against a data frame with no `amcb_id`
#' column compares against NULL, returns 0, and reads as a clean result. An
#' unexpectedly clean answer from a key that does not exist is indistinguishable
#' from a real one -- so the column must be asserted, not assumed.
require_cols <- function(df, cols, what = deparse(substitute(df))) {
  if (!is.data.frame(df)) {
    stop(sprintf("%s is not a data frame (got %s)", what, class(df)[1]),
         call. = FALSE)
  }
  missing <- setdiff(cols, names(df))
  if (length(missing)) {
    stop(sprintf("%s is missing required column(s): %s\n  has: %s",
                 what, paste(missing, collapse = ", "),
                 paste(names(df), collapse = ", ")), call. = FALSE)
  }
  invisible(df)
}

#' Fail when a selection matched nothing.
#'
#' THE DEFECT THIS EXISTS TO PREVENT. A test harness whose file selector matched
#' zero files ran nothing and reported "ALL CLEAN". A selector that matches
#' nothing has not passed -- it has not run. Silence is not success.
assert_nonempty_selection <- function(x, what) {
  if (length(x) == 0L) {
    stop(sprintf(paste("%s selected NOTHING. A selector that matches nothing",
                       "has not passed -- it has not run."), what), call. = FALSE)
  }
  invisible(x)
}
