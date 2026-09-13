# =============================================================================
# The three populations the pipeline reports on, kept apart on purpose
# =============================================================================
# A single denominator stood in for three different questions, and the
# difference only surfaced when two outputs disagreed (11,920 against 11,093;
# reconcile_trilliant_cohort.R). They are:
#
#   canonical_active_primary()   WHO IS IN THE STUDY. ACTIVE AMCB certificants
#       with a primary-tier NPI link, in the freeze the tracked manifest
#       describes. Registered sizes: tests/ci_science_laws.R, LAW_COHORTS.
#
#   board_validation_eligible()  WHO A STATE BOARD COULD CONFIRM. Canonical
#       members whose NPPES practice state is one whose board this project
#       actually queried. That is WA, CO and TX -- each a real call to the
#       state's own public API. The 40-state list behind the tracked roster is
#       NOT board coverage: it was the state list of a fabricated "scrape"
#       (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md), and must never be
#       used to restrict anything.
#
#   cms_dac_observed()           WHO CMS CAN SEE. Canonical members whose NPI
#       appears in the CMS Doctors & Clinicians file. Facility affiliation is
#       measured among them. Board coverage has nothing to do with whether CMS
#       observes a clinician, so this subset is taken from the canonical
#       cohort, never from a board-restricted one.
#
# Each subset is a subset of the canonical cohort and of nothing else.
# =============================================================================

#' States whose Board of Nursing this project has genuinely queried
#'
#' Adding a state here requires a live_<state>_bon_ingested_*.csv produced by
#' a real request to that board's own data. A state is not "covered" because
#' a file once claimed to have scraped it.
GENUINE_BOARD_STATES <- c("WA", "CO", "TX")

#' Refuse a linkage file that is not the freeze the manifest describes
#'
#' @param path [character(1)] the linkage CSV.
#' @param manifest [character(1)] its tracked manifest.
#' @param allow_sha256 [character(1)] a different freeze accepted on purpose.
#' @return [character(1)] the file's sha256, invisibly.
verify_linkage_freeze <- function(path,
                                  manifest = "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json",
                                  allow_sha256 = Sys.getenv("ALLOW_FREEZE_SHA256", "")) {
  if (!file.exists(path)) stop("no linkage file at ", path, call. = FALSE)
  m <- jsonlite::read_json(manifest)
  sha <- digest::digest(file = path, algo = "sha256")
  if (!identical(sha, m$artifact_sha256) && !identical(sha, allow_sha256)) {
    stop(sprintf(paste0("%s has sha256 %s..., but the tracked manifest describes %s... (%s rows).\n",
                        "  Use the current freeze, or set ALLOW_FREEZE_SHA256 to use this one deliberately."),
                 path, substr(sha, 1, 8), substr(m$artifact_sha256, 1, 8),
                 format(m$artifact_rows, big.mark = ",")), call. = FALSE)
  }
  invisible(sha)
}

#' The canonical ACTIVE, primary-linked cohort
#'
#' One row per certification_number. A certificant listed twice with the same
#' NPI collapses to one row; listed twice with DIFFERENT NPIs is an identity
#' conflict and stops, rather than being resolved by row order.
#' @param linkage [data.frame] the linkage freeze, all columns character.
#' @return [data.frame]
canonical_active_primary <- function(linkage) {
  need <- c("certification_number", "status", "linkage_tier", "npi", "nppes_state")
  miss <- setdiff(need, names(linkage))
  if (length(miss)) stop("linkage is missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  x <- linkage[linkage$status %in% "ACTIVE" & linkage$linkage_tier %in% "primary_midwifery" &
                 !is.na(linkage$npi) & nzchar(linkage$npi), , drop = FALSE]
  npis_per_cert <- tapply(x$npi, x$certification_number, function(v) length(unique(v)))
  conflict <- names(npis_per_cert)[npis_per_cert > 1L]
  if (length(conflict))
    stop(sprintf("%d certification number(s) carry more than one NPI (e.g. %s); resolve the identity before counting.",
                 length(conflict), conflict[1]), call. = FALSE)
  x[!duplicated(x$certification_number), , drop = FALSE]
}

#' Canonical members a state board could confirm
#' @param cohort [data.frame] from canonical_active_primary().
#' @param states [character] boards genuinely queried.
board_validation_eligible <- function(cohort, states = GENUINE_BOARD_STATES) {
  cohort[cohort$nppes_state %in% states, , drop = FALSE]
}

#' Canonical members CMS observes in the Doctors & Clinicians file
#' @param cohort [data.frame] from canonical_active_primary(), never a board subset.
#' @param dac_npis [character] NPIs present in the DAC national file.
cms_dac_observed <- function(cohort, dac_npis) {
  cohort[cohort$npi %in% as.character(dac_npis), , drop = FALSE]
}

#' Why each certificant is in one canonical cohort and not the other
#'
#' Compares the canonical cohort of two freezes and gives every certificant in
#' either exactly one reason, so the counts are mutually exclusive and sum to
#' the union. Built for the 11,920 (2026-08-10) -> 12,171 (current) question,
#' but takes any two linkage files.
#' @param old,new [data.frame] two linkage freezes, all columns character.
#' @return [data.frame] certification_number, in_old, in_new, reason, and the
#'   old/new status, tier and NPI behind the reason.
cohort_transition_reasons <- function(old, new) {
  keep <- c("certification_number", "status", "linkage_tier", "npi", "nppes_state")
  o_all <- old[!duplicated(old$certification_number), keep, drop = FALSE]
  n_all <- new[!duplicated(new$certification_number), keep, drop = FALSE]
  o_coh <- canonical_active_primary(old)$certification_number
  n_coh <- canonical_active_primary(new)$certification_number
  ids <- union(o_coh, n_coh)
  o <- o_all[match(ids, o_all$certification_number), , drop = FALSE]
  n <- n_all[match(ids, n_all$certification_number), , drop = FALSE]
  in_old <- ids %in% o_coh
  in_new <- ids %in% n_coh
  on_old_roster <- !is.na(o$certification_number)
  on_new_roster <- !is.na(n$certification_number)
  reason <- ifelse(in_old & in_new & o$npi == n$npi, "in both, same NPI",
            ifelse(in_old & in_new, "in both, NPI changed",
            ifelse(in_new & !on_old_roster, "joined: new to the AMCB roster",
            ifelse(in_new & o$status != "ACTIVE", "joined: status became ACTIVE",
            ifelse(in_new & o$linkage_tier != "primary_midwifery", "joined: link became primary",
            ifelse(in_new, "joined: NPI newly present",
            ifelse(!on_new_roster, "left: gone from the AMCB roster",
            ifelse(n$status != "ACTIVE", "left: status no longer ACTIVE",
            ifelse(n$linkage_tier != "primary_midwifery", "left: link no longer primary",
                   "left: NPI no longer present")))))))))
  data.frame(certification_number = ids, in_old = in_old, in_new = in_new, reason = reason,
             old_status = o$status, new_status = n$status,
             old_tier = o$linkage_tier, new_tier = n$linkage_tier,
             old_npi = o$npi, new_npi = n$npi,
             state = ifelse(is.na(n$nppes_state), o$nppes_state, n$nppes_state),
             stringsAsFactors = FALSE)
}
