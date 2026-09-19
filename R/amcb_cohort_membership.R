# =============================================================================
# Cohort membership: an explicit allowlist, not "has an NPI"
# =============================================================================
#
# THE RULE THIS FILE EXISTS TO MAKE EXPLICIT:
#
#   Match tier and cohort-membership tier are SEPARATE THINGS. A candidate may
#   exist in the crosswalk, with full evidence, without being eligible for the
#   primary analytic cohort.
#
# WHY IT NEEDED SAYING. Downstream membership was `filter(!is.na(npi))` --
# inferred from the presence of an identifier rather than declared. That was
# harmless while every matching strategy produced comparable evidence. It
# stopped being harmless the moment a deliberately weak strategy was added:
# surname-component matching (evidence class 5) contributed 156 candidates, and
# under the inferred rule all 156 would have entered the analytic cohort as full
# members. 96% of the proposed cohort growth would have come from the weakest,
# entirely unreviewed tier -- not a linkage improvement but a redefinition of
# the cohort around an unvalidated fuzzy rule.
#
# The tiers were designed to be separable precisely so that could be prevented.
# Separability is worth nothing if the consumer ignores it, so the allowlist is
# declared here, in one place, and gated in tests/test_amcb_gates.R.
# =============================================================================

#' Evidence tiers eligible for the primary analytic cohort.
#'
#' Deliberately EXCLUDED:
#'   sensitivity_name_component  class 5, surname component + exact given name.
#'                               The weakest evidence in the crosswalk, admitted
#'                               at the bottom of the order on the understanding
#'                               that it would stay out of the cohort until
#'                               reviewed. 156 candidates, 0 reviewed.
#'   quarantined                 candidates existed; identity not resolvable.
#'   unmatched                   no candidate at all.
#'
#' WHAT CHANGING THIS VECTOR ACTUALLY CHANGES. It said "the analytic cohort"
#' until 2026-09-19, and that was wrong (#244): no published estimate reads
#' this allowlist. It governs the LINKAGE-ELIGIBLE set -- the `cohort_member`
#' column, the freeze manifest's `membership_rule`, and therefore who gets a
#' geography row (build_midwives_geography_guarded.R), a birth-activity record
#' (R/15-build-birth-activity.R), a composition row (R/07-cohort-composition.R),
#' an affiliation-coverage row and a credential classification.
#'
#' The STUDY cohort is canonical_active_primary() in R/lib/cohort_definitions.R:
#' ACTIVE and primary_midwifery only. This allowlist is a strict superset of it,
#' by 910 ACTIVE certificants on freeze 1a7bd6a8 (821 sensitivity_nursing, 89
#' sensitivity_fuzzy). cohort_rule_reconciliation() measures the gap; the two
#' rules must not be conflated, and neither may be called "the cohort" without
#' saying which.
#'
#' Still not a tuning knob: every edit needs an explicit decision and a
#' re-freeze, not an incidental rebuild. See docs/ and the freeze manifest.
#' @export
COHORT_MEMBERSHIP_TIERS <- c(
  "primary_midwifery",             # exact/near-exact identity, midwifery taxonomy
  "sensitivity_nursing",           # same identity evidence, nursing-taxonomy NPI
  "sensitivity_fuzzy",             # fuzzy surname within edit distance 2, exact given
  "sensitivity_unknown_taxonomy"    # identity evidence present; taxonomy label dirty
)

#' Is this crosswalk row linkage-eligible?
#'
#' NOT "a member of the analytic cohort" -- see the note above the allowlist.
#' The name is kept because it is written into the freeze, ~25 scripts and
#' several gates; renaming it would need a re-freeze, and the misreading it
#' invites is fixed by saying what it means rather than by churning an
#' identifier.
#'
#' Requires BOTH a resolved NPI and an allowlisted evidence tier. Having an NPI
#' is necessary and NOT sufficient -- that distinction is the entire point.
#'
#' @param npi `character`: matched NPI, NA when unmatched.
#' @param linkage_tier `character`: the row's evidence tier.
#' @param allowed `character`: tiers eligible for membership.
#' @return `logical` vector, never NA.
#' @export
is_cohort_member <- function(npi, linkage_tier,
                             allowed = COHORT_MEMBERSHIP_TIERS) {
  if (length(npi) != length(linkage_tier)) {
    stop(sprintf("npi and linkage_tier differ in length (%d vs %d)",
                 length(npi), length(linkage_tier)), call. = FALSE)
  }
  has_npi <- !is.na(npi) & nzchar(npi)
  eligible <- !is.na(linkage_tier) & linkage_tier %in% allowed
  # An NPI in a non-allowlisted tier is a CANDIDATE, not a member. An
  # allowlisted tier with no NPI resolved nothing. Membership needs both.
  has_npi & eligible
}

#' Membership counts by tier, including the candidates deliberately excluded.
#'
#' Reports the excluded rows rather than dropping them silently: "156 candidates
#' held out of the cohort" is a finding, and a pipeline that simply filters them
#' away cannot report it.
#' @export
cohort_membership_summary <- function(df, allowed = COHORT_MEMBERSHIP_TIERS) {
  stopifnot(all(c("npi", "linkage_tier") %in% names(df)))
  member <- is_cohort_member(df$npi, df$linkage_tier, allowed)
  tab <- as.data.frame(table(tier = df$linkage_tier), stringsAsFactors = FALSE)
  names(tab)[2] <- "n"
  tab$eligible_tier <- tab$tier %in% allowed
  tab$n_members <- vapply(tab$tier, function(t) sum(member & df$linkage_tier == t),
                          integer(1))
  tab$n_candidates_excluded <- tab$n - tab$n_members
  list(summary = tab[order(-tab$n), ],
       n_members = sum(member),
       n_with_npi = sum(!is.na(df$npi) & nzchar(df$npi)),
       n_candidates_not_members = sum(!is.na(df$npi) & nzchar(df$npi) & !member))
}
