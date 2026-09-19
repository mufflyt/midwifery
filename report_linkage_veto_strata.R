#!/usr/bin/env Rscript
# =============================================================================
# Who was ruled IN, and who was only never ruled OUT
# =============================================================================
# match_amcb_to_npi.R asks the question -- "ruled in, or merely not ruled
# out?" -- answers it in two places, and publishes the answer in neither. This
# turns the per-row columns it already writes into a tracked aggregate so the
# strata can be cited without the person-level freeze. Issue #245.
#
# THE ASYMMETRY THIS EXISTS TO CORRECT. A middle-initial conflict vetoes a
# candidate. When every rival is vetoed and the survivor is the one NPI with NO
# middle name recorded, it was not ruled in by agreeing with anything -- it was
# the only one that could not be ruled out. That is a materially weaker claim
# than the evidence class implies, and the surviving row is indistinguishable
# downstream from a genuine unique match.
#
# The class-5 version of this was found, quantified and acted on: those matches
# are quarantined, demoted to class5_candidate_npi, and none reaches the study
# cohort. The class-2 version was found and quantified and NOT acted on --
# correctly, because the surviving claim there rests on agreement of the whole
# given name AND the whole surname, and moving cohort membership on a rule
# nothing had ever reported would be a change made blind.
#
# So the harmless stratum was the one disclosed (the README carries
# resolved_by_absence_c5) and the consequential one was not. This script makes
# both reportable. It does NOT demote anybody: that is a separate, evidenced
# decision, and reporting is the precondition the matcher itself names for
# taking it.
#
# THE OTHER TAIL. unmatched_after_middle_veto is the mirror image: certificants
# published as "no candidate" whose ONLY exact-name candidate was deleted by
# the veto. That is a RECALL claim the artifacts currently overstate, and it
# belongs in the same table.
#
# Aggregate only -- counts by stratum and population, no certification number,
# no NPI, no name.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
# Output : artifacts/linkage_veto_strata.csv
#
# @author Tyler Muffly, MD + Claude Code
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})
source(file.path("R", "lib", "cohort_definitions.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

LINKAGE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
OUT     <- "artifacts/linkage_veto_strata.csv"

if (!file.exists(LINKAGE)) {
  stop(sprintf(paste0(
    "%s not found. These strata are per-row columns of the freeze; there is no\n",
    "  aggregate to fall back on. Run on the machine that holds it rather than\n",
    "  emitting an empty table, which would read as 'no such matches'."), LINKAGE),
    call. = FALSE)
}

link <- read_csv(LINKAGE, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = "c"))
cohort_ids <- canonical_active_primary(link)$certification_number

# The freeze stores logicals as text. tolower() rather than as.logical(), which
# returns NA for "T"/"yes" and would silently undercount every stratum here.
tf <- function(x) tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes")

pops <- list(
  roster       = rep(TRUE, nrow(link)),
  active       = link$status %in% "ACTIVE",
  study_cohort = link$certification_number %in% cohort_ids
)

#' One stratum, counted in each of the three populations.
#' @param flag logical vector over the freeze's rows.
stratum <- function(id, question, consequence, flag) {
  tibble(stratum = id, question = question, consequence = consequence,
         n_roster = sum(flag & pops$roster),
         n_active = sum(flag & pops$active),
         n_study_cohort = sum(flag & pops$study_cohort),
         pct_of_study_cohort = round(100 * sum(flag & pops$study_cohort) /
                                       length(cohort_ids), 2))
}

need <- c("resolved_by_absence_c2", "resolved_by_absence_c5",
          "npi_demoted_absence_c5", "unmatched_after_middle_veto",
          "exact_first_last_multiple_candidates", "n_mid_vetoed_c2", "n_mid_vetoed_c5")
miss <- setdiff(need, names(link))
if (length(miss)) {
  stop(sprintf(paste0(
    "%s lacks column(s): %s.\n",
    "  These are the class-5/class-2 veto machinery added on 2026-08-11 and\n",
    "  2026-08-30. A freeze without them predates the question this script\n",
    "  reports on, and an empty answer would be indistinguishable from a\n",
    "  clean one."), LINKAGE, paste(miss, collapse = ", ")), call. = FALSE)
}

strata <- bind_rows(
  stratum("resolved_by_absence_c2",
          "class 2: every exact-name rival was vetoed on a middle initial, and the survivor records none",
          "PUBLISHED as a full study-cohort member, indistinguishable from a genuine unique match",
          tf(link$resolved_by_absence_c2)),
  stratum("resolved_by_absence_c5",
          "class 5: the same pattern where the surname evidence is already partial",
          "QUARANTINED: demoted to class5_candidate_npi, npi set to NA, reaches no cohort",
          tf(link$resolved_by_absence_c5)),
  stratum("npi_demoted_absence_c5",
          "the demotion the line above describes, as applied",
          "the row keeps its candidate NPI in class5_candidate_npi and carries no npi",
          tf(link$npi_demoted_absence_c5)),
  stratum("unmatched_after_middle_veto",
          "the other tail: the ONLY exact-name candidate was deleted by the veto",
          "PUBLISHED as 'no candidate found', which overstates the recall failure",
          tf(link$unmatched_after_middle_veto)),
  stratum("exact_first_last_multiple_candidates",
          "more than one NPI shared the whole given name and the whole surname",
          "resolved by middle-name evidence or by the veto; context for the two strata above",
          tf(link$exact_first_last_multiple_candidates))
)

# The veto's footprint, which the strata above are a consequence of. Counted
# separately because a row can carry vetoes without being resolved by absence.
vint <- function(x) suppressWarnings(as.integer(x))
footprint <- tibble(
  stratum = c("n_mid_vetoed_c2", "n_mid_vetoed_c5"),
  question = c("exact-name rivals removed by a middle-initial conflict",
               "class-5 rivals removed by a middle-initial conflict"),
  consequence = "count of vetoes, not of people; a row may carry several",
  n_roster = c(sum(vint(link$n_mid_vetoed_c2), na.rm = TRUE),
               sum(vint(link$n_mid_vetoed_c5), na.rm = TRUE)),
  n_active = c(sum(vint(link$n_mid_vetoed_c2)[pops$active], na.rm = TRUE),
               sum(vint(link$n_mid_vetoed_c5)[pops$active], na.rm = TRUE)),
  n_study_cohort = c(sum(vint(link$n_mid_vetoed_c2)[pops$study_cohort], na.rm = TRUE),
                     sum(vint(link$n_mid_vetoed_c5)[pops$study_cohort], na.rm = TRUE)),
  pct_of_study_cohort = NA_real_)

out <- bind_rows(strata, footprint)
print(as.data.frame(out[, c("stratum", "n_roster", "n_active", "n_study_cohort",
                            "pct_of_study_cohort")]))

c2 <- out$n_study_cohort[out$stratum == "resolved_by_absence_c2"]
c5 <- out$n_study_cohort[out$stratum == "resolved_by_absence_c5"]
cat(sprintf(paste0(
  "\nTHE ASYMMETRY: %s study-cohort member(s) resolve at class 2 only because every\n",
  "rival was vetoed, against %s at class 5 -- because the class-5 ones are\n",
  "quarantined by design. The stratum that reaches print is the one that was not\n",
  "being reported.\n"),
  format(c2, big.mark = ","), format(c5, big.mark = ",")))

write_with_provenance(out, OUT, inputs = LINKAGE)
cat(sprintf("\nwritten: %s (%d rows)\n", OUT, nrow(out)))
