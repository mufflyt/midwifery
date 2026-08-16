# =============================================================================
# Organization affiliation: one status from several arms, none of them employer
# =============================================================================
# Each arm is kept SEPARATE and the status is derived from their combination.
# Collapsing them into a single "employer" column would destroy the only thing
# that makes this defensible -- knowing which evidence supports which claim.
#
#   pecos_reassignment_on_file    a Medicare reassignment relationship on file
#                                 in PECOS at the snapshot date. Restricted to
#                                 currently-approved enrollments, so NOT an
#                                 all-time history -- but withdrawal is the
#                                 practitioner's responsibility, so it MAY lag
#                                 the real relationship.
#
#   care_compare_group_listing    CMS publishes this clinician as practising
#                                 with this group. A curated directory.
#
#   nppes_practice_org_candidate  a Type-2 NPI at the same practice address.
#                                 Weakest: a hospital campus can carry dozens.
#
# See DECISIONS_CONTRACT.md, "PECOS reassignment: temporal interpretation".
#
# WHY medicare_reassignment_only IS NOT "historical". It may be a genuine
# concurrent billing relationship Care Compare does not display, or an
# administratively stale record. Those are different facts and the data cannot
# yet separate them, so the status says what is known -- a reassignment is on
# file, current practice status uncertain -- and stops there.
# =============================================================================

#' Classify one midwife-organization pair from the available arms
#'
#' @param pecos logical: a PECOS reassignment is on file at the snapshot date.
#' @param care_compare logical: Care Compare lists the group for this clinician.
#' @param nppes logical: an address-derived Type-2 candidate.
#' @param location_agrees logical or NA: arms that name a location agree on it.
#' @param contradicted logical: an arm positively contradicts the pairing.
#' @return character status, one value per input row.
classify_affiliation_status <- function(pecos, care_compare, nppes,
                                        location_agrees = NA,
                                        contradicted = FALSE) {
  n <- max(length(pecos), length(care_compare), length(nppes))
  rep_to <- function(x) if (length(x) == 1L) rep(x, n) else x
  pecos <- rep_to(pecos); care_compare <- rep_to(care_compare)
  nppes <- rep_to(nppes); location_agrees <- rep_to(location_agrees)
  contradicted <- rep_to(contradicted)

  # Missing evidence is ABSENT evidence, never contrary evidence. NA in an arm
  # means that arm was not consulted or had nothing to say, and treating that
  # as FALSE would let a source we never checked argue against an affiliation.
  p  <- pecos %in% TRUE
  cc <- care_compare %in% TRUE
  np <- nppes %in% TRUE
  contra <- contradicted %in% TRUE
  loc_ok <- location_agrees %in% TRUE

  dplyr::case_when(
    contra                       ~ "conflicting",

    # Both current-ish arms name the same organization. Location agreement
    # raises it no further on its own -- two independent CMS products already
    # agreeing is the strong evidence here -- but its ABSENCE is not held
    # against the pairing either, since only some rows carry a location.
    p & cc &  loc_ok             ~ "high_confidence_current",
    p & cc                       ~ "high_confidence_current",

    # Care Compare is the curated statement of where CMS lists someone
    # practising. Alone, with nothing against it, that is probable-current.
    cc                           ~ "probable_current",

    # A reassignment on file and no Care Compare listing. NOT historical: it
    # may be a real concurrent billing relationship Care Compare omits, or a
    # stale record nobody withdrew. The status says what is known.
    p                            ~ "medicare_reassignment_only",

    # Address alone. A shared street is not an affiliation.
    np                           ~ "address_only",

    TRUE                         ~ "unknown"
  )
}

#' The statuses, weakest to strongest
#'
#' Ordered so that "did the evidence get stronger or weaker" is answerable
#' without every caller inventing its own ranking.
AFFILIATION_STATUS_LEVELS <- c(
  "unknown",
  "address_only",
  "medicare_reassignment_only",
  "probable_current",
  "high_confidence_current"
)

#' Is this status a defensible claim of CURRENT affiliation?
#'
#' `conflicting` is deliberately FALSE rather than an error: a conflict is a
#' finding to look at, not a row to drop.
is_current_affiliation <- function(status) {
  status %in% c("high_confidence_current", "probable_current")
}
