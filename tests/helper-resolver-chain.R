# =============================================================================
# The production identity chain, as one call
# =============================================================================
# Both the adversarial corpus suite and the metamorphic suite need to drive the
# same three production functions in the same order. They each grew their own
# copy, ci_hygiene H4 caught it, and renaming one would have been the wrong fix:
# two copies of "what the pipeline decides" is exactly how the two suites would
# drift into testing different things while appearing to agree.
#
# Nothing here reimplements a rule. It only sequences:
#
#   amcb_resolve()        R/amcb_resolver.R            stage 1
#   amcb_linkage_tier()   R/amcb_resolver.R            evidence tier
#   is_cohort_member()    R/amcb_cohort_membership.R   eligibility
#
# Named helper-* so the nightly sources it rather than executing it.
# =============================================================================

#' Corpus rows -> the candidate frame the resolver expects
chain_to_candidates <- function(df) {
  data.frame(
    amcb_id = df$amcb_id, npi = df$npi,
    name_evidence_class = as.integer(df$name_evidence_class),
    taxonomy_axis = df$taxonomy_axis,
    match_method = "corpus",
    match_strategy = as.integer(df$name_evidence_class),
    mid_match = 0L,
    nppes_matched_last = if (!is.null(df$variant)) df$variant else "V",
    nppes_matched_first = "F", nppes_mid_init = "",
    stringsAsFactors = FALSE)
}

#' Outcome per person: "member", "held_out", or "quarantined"
#'
#' @param detail when TRUE, also returns the resolved rows and pool statistics.
chain_classify <- function(df, detail = FALSE) {
  cands <- chain_to_candidates(df)
  res <- amcb_resolve(cands)
  out <- stats::setNames(rep("quarantined", length(unique(cands$amcb_id))),
                         sort(unique(cands$amcb_id)))
  if (nrow(res$resolved)) {
    tier <- amcb_linkage_tier(res$resolved$npi, res$resolved$name_evidence_class,
                              res$resolved$taxonomy_axis)
    out[res$resolved$amcb_id] <-
      ifelse(is_cohort_member(res$resolved$npi, tier), "member", "held_out")
  }
  if (!detail) return(out)
  list(outcome = out, resolved = res$resolved, pool = res$pool_stats)
}
