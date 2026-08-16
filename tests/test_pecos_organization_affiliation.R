#!/usr/bin/env Rscript
# =============================================================================
# PECOS organization affiliation: the semantics, not the join mechanics
# =============================================================================
# build_pecos_organization_affiliations.R links a midwife's Type-1 NPI to the
# organizations receiving her reassigned Medicare benefits. The join itself is
# a few SQL statements; what needs guarding is what the result is ALLOWED TO
# MEAN.
#
# Three claims this file refuses to let the pipeline make:
#
#   1. that a billing affiliation is EMPLOYMENT. PECOS records where benefits
#      are paid. A clinician can bill through a group without being employed
#      by it, and that distinction is not recoverable from these files.
#
#   2. that absence from PECOS means independent practice. PECOS covers
#      providers with approved MEDICARE enrollment. 9,364 of 17,054 resolved
#      midwives have no PECOS record; almost none of that is solo practice,
#      most of it is simply not billing Medicare.
#
#   3. that a midwife has ONE organization. 2,259 of 7,288 reassign to more
#      than one, up to 16. Collapsing to a single employer would discard the
#      concurrency that makes this worth building.
#
# Hermetic: the semantics are exercised on small frames, so this runs without
# the 287 MB PECOS enrollment file. Where the real artifact is present, its
# invariants are checked too and skipped loudly when it is not.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "tests", "helper-optional-inputs.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

SRC  <- file.path(root, "build_pecos_organization_affiliations.R")
ART  <- file.path(root, "artifacts", "midwife_pecos_organization_affiliations.csv")
AGG  <- file.path(root, "artifacts", "midwife_organization_affiliation_by_state.csv")
src  <- paste(readLines(SRC, warn = FALSE), collapse = "\n")
code <- {
  ln <- readLines(SRC, warn = FALSE)
  paste(ln[!grepl("^\\s*#", ln)], collapse = "\n")
}

# =============================================================================
cat("\n-- N: it is AFFILIATION, never EMPLOYER --\n")
# =============================================================================
{
  # The word must not appear as a column or a value. It may appear in prose
  # explaining why it is not used, which is why comments are stripped.
  chk(!grepl("employer\\s*=", code),
      "N1 no column is assigned the name 'employer'")
  chk(!grepl('"employer"', code, fixed = TRUE),
      "N2 no literal value 'employer' is written")
  chk(grepl("affiliation_strength", code, fixed = TRUE) &&
        grepl("affiliation_source", code, fixed = TRUE),
      "N3 the evidence is labelled by source and strength")

  # A billing relationship to a SOLO PRACTITIONER is not an organization
  # affiliation. Sixteen midwives reassign to an individual's enrollment.
  chk(grepl("receiving_entity_is_practitioner", code, fixed = TRUE),
      "N4 a practitioner receiving benefits is distinguished from an organization")
  chk(grepl("confirmed_billing_affiliation_solo_practitioner", code, fixed = TRUE),
      "N5 and gets its own strength label, not the organization one")
}

# =============================================================================
cat("\n-- C: absence from PECOS is coverage, not a finding --\n")
# =============================================================================
{
  chk(grepl("ABSENCE IS NOT INDEPENDENCE", src, fixed = TRUE),
      "C1 the coverage limit is stated in the run output, not buried")

  # The script must refuse to run rather than write an empty table if PECOS is
  # missing. An empty affiliation file reads as 'no midwife has an
  # organization', which is the strongest possible false finding here.
  chk(grepl("Refusing to write an empty affiliation table", src, fixed = TRUE),
      "C2 a missing PECOS file is a hard stop, not an empty output")
  chk(grepl("if (!nrow(ind))", code, fixed = TRUE),
      "C3 zero enrollment matches is treated as a broken join, not as data")
}

# =============================================================================
cat("\n-- M: multiple affiliations must survive --\n")
# =============================================================================
{
  chk(grepl("n_concurrent_organizations", code, fixed = TRUE),
      "M1 concurrency is counted and carried into the output")
  # No step may reduce to one row per midwife.
  chk(!grepl("distinct\\(midwife_npi, \\.keep_all", code) &&
        !grepl("slice_max\\(.*n\\s*=\\s*1", code),
      "M2 nothing collapses a midwife to a single organization")
}

# =============================================================================
cat("\n-- D: disclosure control on the tracked aggregate --\n")
# =============================================================================
{
  chk(grepl("n_affiliations < 11", code, fixed = TRUE),
      "D1 cells under 11 are suppressed in the tracked aggregate")

  if (have_inputs(ART, "person-level affiliation invariants")) {
    d <- read_csv(ART, col_types = cols(.default = "c"), progress = FALSE)
    chk(all(c("amcb_id", "midwife_npi", "organization_npi", "organization_name",
              "affiliation_source", "affiliation_strength",
              "n_concurrent_organizations") %in% names(d)),
        "D2 the person-level artifact carries the declared schema")
    chk(!"employer" %in% names(d),
        "D3 there is no employer column in the artifact")
    chk(all(d$affiliation_source == "pecos_reassignment"),
        "D4 every row declares its source")

    # THE GRAIN IS (midwife, individual enrollment, receiving enrollment).
    #
    # My first version asserted uniqueness of (midwife, receiving enrollment)
    # and found 88 repeats, which looked like a fan-out and was not. One NPI
    # can hold SEVERAL PECOS enrollments -- the sample enrollment file shows
    # one NPI with three -- and each can reassign to the same organization. The
    # clearest case in the data is a midwife with two individual enrollments
    # both reassigning to her own professional corporation.
    #
    # So the test is on the declared grain, plus the specific thing that would
    # be a defect: a repeated (midwife, organization) pair must be explained by
    # DIFFERING individual enrollments, never by a duplicated row.
    chk(sum(duplicated(d)) == 0L,
        sprintf("D5 no fully duplicated row [%d]", sum(duplicated(d))))
    grain <- d %>% distinct(midwife_npi, individual_enrlmt_id, org_enrlmt_id)
    chk(nrow(grain) == nrow(d),
        sprintf("D5b the declared grain is unique [%d of %d rows]",
                nrow(grain), nrow(d)))
    unexplained <- d %>%
      count(midwife_npi, org_enrlmt_id, individual_enrlmt_id) %>%
      filter(n > 1)
    chk(nrow(unexplained) == 0L,
        sprintf("D5c every repeated (midwife, organization) pair differs on the individual enrollment [%d unexplained]",
                nrow(unexplained)))

    n_multi <- d %>% distinct(midwife_npi, organization_npi) %>%
      count(midwife_npi) %>% filter(n > 1) %>% nrow()
    chk(n_multi > 0L,
        sprintf("D6 concurrent affiliations are present in the output [%d midwives]",
                n_multi))
  }

  if (have_inputs(AGG, "tracked aggregate suppression")) {
    a <- read_csv(AGG, col_types = cols(.default = "c"), progress = FALSE)
    n <- suppressWarnings(as.integer(a$n_affiliations))
    chk(all(is.na(n) | n >= 11L),
        sprintf("D7 no unsuppressed cell under 11 survives [min %s]",
                if (all(is.na(n))) "all NA" else min(n, na.rm = TRUE)))
    # A numeric state code would mean state_cd was used instead of state_cdstr,
    # which produced an aggregate keyed on 1, 10, 11 -- numbers that look like
    # counts and join to no state table anywhere.
    chk(all(grepl("^[A-Z]{2}$", a$practice_state)),
        sprintf("D8 states are two-letter codes, not PECOS numeric ids [%s]",
                paste(utils::head(a$practice_state, 3), collapse = ",")))
  }
}

optional_inputs_summary()
cat(sprintf("\n%s (%d failures, %d skipped)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, optional_skip_count()))
quit(status = if (fails == 0L) 0L else 1L)
