#!/usr/bin/env Rscript
# =============================================================================
# Face-validity check: named training institutions against ACME's current
# accredited-program list
# =============================================================================
# WHAT THIS DOES AND DOES NOT PROVE. training_institution (Table 1) comes from
# two sources that were never designed to record nurse-midwifery education
# specifically: CMS DAC's education field is built for MD/DO medical schools,
# and Healthgrades' profile field is self-reported and uncurated. Neither is
# checked against any list of institutions that actually offer an accredited
# midwifery program. This script is that check, for the ten institutions named
# often enough to appear in Table 1's own top-10 block -- it cannot check the
# 759 pooled "other" rows, because the row-level source
# (artifacts/dac_cnm_education.csv) is person-level, gitignored, and absent on
# this machine; see build_table1_midwives.R's own header for why.
#
# data/acme_accredited_midwifery_programs.csv is NOT scraped. It was manually
# transcribed from https://theacme.org/accredited-midwifery-education-programs/
# on 2026-09-12 (fetched via a single page read, 52 programs, all of them
# transcribed -- none invented, none inferred). Given this project's own
# fabricated-BON-data episode earlier tonight
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md), this header says
# explicitly what a script name alone cannot: how this file was actually
# produced.
#
# A MISMATCH IS NOT PROOF OF AN ERROR. ACME's list is a CURRENT snapshot. This
# cohort spans certification dates across decades (Table 1's own "Years Since
# AMCB Initial Certification" block shows respondents 30+ years post-
# certification), and a program can lose accreditation, close, or merge long
# after training someone who still practices today. A name absent from the
# current list is a flag for a human to look into, not a finding this script
# can resolve on its own.
#
# ALREADY INVESTIGATED: Emory University. Absent from ACME's current list, but
# confirmed via Emory's own published sources to have run an ACME-accredited
# nurse-midwifery program from 1977 through at least 2016 (370+ graduates by
# Fall 2015, 37 students still enrolled that year, described then as the only
# on-the-ground program in the Southeastern US). This is a genuinely closed
# program, not a data-quality defect in training_institution -- resolved, not
# open.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

norm <- function(x) {
  y <- toupper(str_squish(as.character(x)))
  y <- str_replace_all(y, "[^A-Z0-9 ]", " ")
  str_squish(str_replace(y, "^THE ", ""))
}

acme <- read_csv("data/acme_accredited_midwifery_programs.csv", show_col_types = FALSE) %>%
  mutate(norm_name = norm(institution))

t1 <- read_csv("artifacts/table1_midwives.csv", show_col_types = FALSE)
named <- t1 %>%
  filter(category == "Training institution (CMS DAC + Healthgrades)",
         !characteristic %in% c("Other named institution",
                                "No school named by CMS DAC or Healthgrades")) %>%
  mutate(norm_name = norm(characteristic))

cat("=== Table 1's named training institutions vs. ACME's current accredited-program list ===\n\n")

# A SUBSTRING match, not exact equality: Table 1's names are shortened
# ("University of Illinois" for ACME's "University of Illinois at Chicago";
# "State University of New York Downstate" for ACME's "SUNY Downstate Health
# Sciences University" -- caught separately below since SUNY isn't a
# substring). Exact-equality would flag both as mismatches for a difference in
# how the same institution is written, not a real absence from the list.
alias <- c(
  "STATE UNIVERSITY OF NEW YORK DOWNSTATE" = "SUNY DOWNSTATE HEALTH SCIENCES UNIVERSITY",
  "STATE UNIVERSITY OF NEW YORK AT STONY BROOK" = "STONY BROOK UNIVERSITY"
)

found <- character(0); missing <- character(0)
for (i in seq_len(nrow(named))) {
  nm <- named$norm_name[i]
  nm_aliased <- if (nm %in% names(alias)) alias[[nm]] else nm
  hit <- any(str_detect(acme$norm_name, fixed(nm_aliased))) ||
         any(str_detect(nm_aliased, fixed(acme$norm_name)))
  if (hit) found <- c(found, named$characteristic[i])
  else missing <- c(missing, named$characteristic[i])
}

cat(sprintf("%d of %d matched a currently-accredited ACME program:\n", length(found), nrow(named)))
for (f in found) cat(sprintf("  ok   %s\n", f))

# Investigated once, above in this file's own header -- re-flagging Emory on
# every run as "investigate" would make a resolved question look perpetually
# open to the next reader.
RESOLVED <- c("Emory University" = "ran an ACME-accredited program 1977-2016+; since closed, not a data error")

if (length(missing)) {
  still_open <- setdiff(missing, names(RESOLVED))
  resolved_hits <- intersect(missing, names(RESOLVED))
  for (m in resolved_hits)
    cat(sprintf("\n  ok   %s: not on ACME's current list, but resolved (%s)\n", m, RESOLVED[[m]]))
  if (length(still_open)) {
    cat(sprintf("\n%d NOT found on ACME's current list (investigate, don't assume error):\n", length(still_open)))
    for (m in still_open) cat(sprintf("  ??   %s\n", m))
  }
}
