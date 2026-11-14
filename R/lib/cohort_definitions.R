# =============================================================================
# The four populations the pipeline reports on, kept apart on purpose
# =============================================================================
# A single denominator stood in for three different questions, and the
# difference only surfaced when two outputs disagreed (11,920 against 11,093;
# reconcile_trilliant_cohort.R). A fourth was added to this list on 2026-09-19
# after issue #244 found it had been live all along under the name "the
# analytic cohort", which it is not. They are:
#
#   linkage_eligible()           WHO THE CROSSWALK RESOLVED TO AN IDENTITY.
#       An NPI plus an allowlisted evidence tier, per
#       R/amcb_cohort_membership.R::is_cohort_member() and
#       COHORT_MEMBERSHIP_TIERS. This is the `cohort_member` column carried in
#       the freeze and declared as `membership_rule` in its manifest. It is a
#       LINKAGE-QUALITY statement -- "the matcher resolved this person and the
#       evidence clears the bar" -- and it is a strict SUPERSET of the study
#       cohort below, because it admits three sensitivity tiers the study does
#       not: sensitivity_nursing, sensitivity_fuzzy, sensitivity_unknown_taxonomy.
#
#       Measured on freeze 1a7bd6a8: 17,028 rows, 13,081 of them ACTIVE, against
#       the canonical 12,171 -- a difference of 910 ACTIVE certificants (821
#       sensitivity_nursing, 89 sensitivity_fuzzy). Read by the geography,
#       birth-activity, composition, affiliation-coverage and credential layers.
#
#       IT IS NOT THE STUDY COHORT AND MUST NOT BE CALLED ONE. Every published
#       estimate -- Table 1, the access measure, the hospital linkage, the age
#       calibration, the exclusion figure, the stats catalog -- uses
#       canonical_active_primary(). Editing COHORT_MEMBERSHIP_TIERS changes
#       which people have geography and activity records computed for them; it
#       does not change who is in the study.
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
# The last two are subsets of the canonical cohort and of nothing else. The
# canonical cohort is in turn a subset of the linkage-eligible set restricted
# to ACTIVE, and cohort_rule_reconciliation() below measures the gap rather
# than leaving a reader to diff two scripts.
# =============================================================================

#' States whose Board of Nursing this project has genuinely queried
#'
#' Adding a state here requires a live_<state>_bon_ingested_*.csv produced by
#' a real request to that board's own data. A state is not "covered" because
#' a file once claimed to have scraped it.
GENUINE_BOARD_STATES <- c("WA", "CO", "TX")

#' The script currently running, for per-consumer pin matching
#' @return [character(1)] its basename, or "" when not run via Rscript.
#' @keywords internal
#' @noRd
freeze_running_script <- function() {
  a <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(a)) basename(sub("^--file=", "", a[1])) else ""
}

#' A declared pin for a freeze other than the manifest's, or NA
#'
#' A PIN IS PER CONSUMER, NOT PER HASH. Keying only on the hash would mean that
#' declaring the 2026-08-10 freeze for one dated experiment also unlocks it for
#' every other consumer in the repository -- including the ones that compute
#' published counts. That is the permissiveness this registry exists to remove,
#' so the row has to name the script that may read it.
#'
#' @param sha256 [character(1)] the hash to look up.
#' @param pins [character(1)] the registry.
#' @param consumer [character(1)] the script asking; defaults to the running one.
#' @return [character(1)] the purpose, or NA_character_ when undeclared.
freeze_pin_purpose <- function(sha256,
                               pins = "artifacts/freeze_pins.tsv",
                               consumer = freeze_running_script()) {
  if (!file.exists(pins)) return(NA_character_)
  d <- utils::read.delim(pins, comment.char = "#", stringsAsFactors = FALSE,
                         colClasses = "character")
  if (!"consumer" %in% names(d)) return(NA_character_)
  hit <- d[tolower(d$sha256) == tolower(sha256) &
             basename(trimws(d$consumer)) == consumer, , drop = FALSE]
  if (!nrow(hit) || !nzchar(trimws(hit$purpose[1]))) return(NA_character_)
  sprintf("%s [%s; %s]", trimws(hit$purpose[1]), hit$scope[1], hit$doc[1])
}

#' Refuse a linkage file that is not the freeze the manifest describes
#'
#' Two ways to read a different freeze on purpose, and they are deliberately
#' not equivalent:
#'
#'   allow_sha256=        passed in code, at one call site, visible in review.
#'   ALLOW_FREEZE_SHA256  an environment variable -- ambient, applying to every
#'                        consumer in the process, invisible in the script, and
#'                        leaving no record of which freeze was read. This is
#'                        how a build came to describe 11,920 midwives instead
#'                        of 12,171 (docs/DATA_VAULT.md). It is still allowed,
#'                        but only for a hash DECLARED in freeze_pins.tsv with
#'                        a stated purpose, and it says so on every run.
#'
#' @param path [character(1)] the linkage CSV.
#' @param manifest [character(1)] its tracked manifest.
#' @param allow_sha256 [character(1)] a different freeze accepted on purpose at
#'   this call site. NULL (the default) consults ALLOW_FREEZE_SHA256 instead,
#'   which additionally requires the hash to be declared.
#' @param pins [character(1)] the pin registry.
#' @param consumer [character(1)] the script asking; defaults to the running one.
#' @return [character(1)] the file's sha256, invisibly.
verify_linkage_freeze <- function(path,
                                  manifest = "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json",
                                  allow_sha256 = NULL,
                                  pins = "artifacts/freeze_pins.tsv",
                                  consumer = freeze_running_script()) {
  if (!file.exists(path)) stop("no linkage file at ", path, call. = FALSE)
  from_env <- is.null(allow_sha256)
  if (from_env) allow_sha256 <- Sys.getenv("ALLOW_FREEZE_SHA256", "")
  m <- jsonlite::read_json(manifest)
  sha <- digest::digest(file = path, algo = "sha256")
  if (identical(sha, m$artifact_sha256)) return(invisible(sha))

  if (!identical(sha, allow_sha256))
    stop(sprintf(paste0("%s has sha256 %s..., but the tracked manifest describes %s... (%s rows).\n",
                        "  Use the current freeze, or set ALLOW_FREEZE_SHA256 to use this one deliberately\n",
                        "  (declare it in %s first)."),
                 path, substr(sha, 1, 8), substr(m$artifact_sha256, 1, 8),
                 format(m$artifact_rows, big.mark = ","), pins), call. = FALSE)

  if (from_env) {
    why <- freeze_pin_purpose(sha, pins, consumer)
    if (is.na(why))
      stop(sprintf(paste0("ALLOW_FREEZE_SHA256 names %s..., which is not declared in %s\n",
                          "  for the script reading it (%s).\n",
                          "  A pin has to be written down before it can be used, and it names ONE\n",
                          "  consumer: add a row with that script, the rows, members, scope and the\n",
                          "  document stating why reading this freeze is legitimate there. A pin for\n",
                          "  another script does not carry over, and nothing pinned may back a\n",
                          "  published count."),
                   substr(sha, 1, 8), pins,
                   if (nzchar(consumer)) consumer else "<not run via Rscript>"),
           call. = FALSE)
    message(sprintf("ALLOW_FREEZE_SHA256: reading the pinned freeze %s... -- %s",
                    substr(sha, 1, 8), why))
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

#' Who the crosswalk resolved, which is not who is in the study
#'
#' The `cohort_member` rule, expressed here so the distinction lives in the file
#' that exists to keep these populations apart. Delegates to
#' [is_cohort_member()] rather than restating the allowlist -- one copy of the
#' rule, or the two definitions drift the way #244 found them drifted.
#'
#' @param linkage [data.frame] the linkage freeze.
#' @return [logical] one value per row, never NA.
#' @family cohorts
linkage_eligible <- function(linkage) {
  need <- c("npi", "linkage_tier")
  miss <- setdiff(need, names(linkage))
  if (length(miss)) stop("linkage is missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  if (!exists("is_cohort_member", mode = "function")) {
    src <- file.path(dirname(dirname(normalizePath(".", mustWork = FALSE))), "R",
                     "amcb_cohort_membership.R")
    cand <- c("R/amcb_cohort_membership.R", "../R/amcb_cohort_membership.R", src)
    hit <- cand[file.exists(cand)]
    if (!length(hit))
      stop("linkage_eligible() needs R/amcb_cohort_membership.R::is_cohort_member()",
           call. = FALSE)
    sys.source(hit[[1L]], envir = environment())
  }
  is_cohort_member(linkage$npi, linkage$linkage_tier)
}

#' Reconcile the linkage-eligible set against the study cohort
#'
#' The one number nobody could quote before #244: how many people the two rules
#' disagree about, and which tiers they are. Reported rather than asserted, so
#' a deliberate change to either rule shows up as a changed count instead of a
#' silent redefinition.
#'
#' @param linkage [data.frame] the linkage freeze, all columns character.
#' @return [list] with `n_linkage_eligible`, `n_linkage_eligible_active`,
#'   `n_canonical`, `n_active_only_in_linkage_eligible`, and `by_tier`, a named
#'   integer vector of the ACTIVE rows in the first and not the second.
#' @family cohorts
cohort_rule_reconciliation <- function(linkage) {
  elig <- linkage_eligible(linkage)
  active <- linkage$status %in% "ACTIVE"
  canon <- canonical_active_primary(linkage)$certification_number
  extra <- linkage[elig & active & !(linkage$certification_number %in% canon), , drop = FALSE]
  extra <- extra[!duplicated(extra$certification_number), , drop = FALSE]
  list(
    n_linkage_eligible = sum(elig),
    n_linkage_eligible_active = sum(elig & active),
    n_canonical = length(canon),
    n_active_only_in_linkage_eligible = nrow(extra),
    by_tier = {
      t <- table(extra$linkage_tier)
      setNames(as.integer(t), names(t))
    })
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
