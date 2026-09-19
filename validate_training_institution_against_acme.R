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
# often enough to appear in Table 1's own top-10 block.
#
# IT COVERS A SMALL SLICE OF THE COHORT, AND SAYS SO NOW. On the 2026-08-10
# build the ten validated institutions account for 469 of 11,920 certificants
# -- 3.9% of the cohort, 38.2% of those with any school recorded -- because
# 10,692 (89.7%) have NO school named by either source. "9 of 10 matched" is
# therefore a statement about roughly one midwife in twenty-five, and reading
# it as reassurance about training_institution as a variable would be a
# mistake. The coverage is computed and printed below rather than left for a
# reader to work out from Table 1, and is the whole of issue #247.
#
# It also cannot check the 759 pooled "other" rows, because the row-level
# source (artifacts/dac_cnm_education.csv) is person-level, gitignored, and
# absent on this machine; see build_table1_midwives.R's own header for why.
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

T1 <- "artifacts/table1_midwives.csv"
t1 <- read_csv(T1, show_col_types = FALSE)

# WHICH TABLE 1 IS BEING VALIDATED. The committed CSV went stale for a month
# once already (#233), and a face-validity check run against a superseded
# top-10 validates institutions that may no longer be in it. This reports the
# vintage it read and, where the freeze is available, whether that vintage is
# the canonical cohort -- rather than silently validating whatever is on disk.
t1_n <- suppressWarnings(as.integer(t1$n[t1$category == "Cohort"][1]))
canon_n <- NA_integer_
.fro <- "artifacts/amcb_npi_linkage_FROZEN.csv"
if (file.exists(.fro) && file.exists("R/lib/cohort_definitions.R")) {
  source("R/lib/cohort_definitions.R")
  canon_n <- tryCatch(
    nrow(canonical_active_primary(read_csv(.fro, show_col_types = FALSE,
                                           progress = FALSE,
                                           col_types = cols(.default = "c")))),
    error = function(e) NA_integer_)
}
cat(sprintf("Table 1 read: %s (cohort n = %s)%s\n\n", T1,
            format(t1_n, big.mark = ","),
            if (is.na(canon_n)) "  [freeze absent; vintage unchecked]"
            else if (identical(t1_n, canon_n)) "  [canonical]"
            else sprintf("  [!! SUPERSEDED: canonical_active_primary() gives %s -- the top ten below may not be the current top ten (#233)]",
                         format(canon_n, big.mark = ","))))

# The block's own name travels with the sources it is built from, and has
# changed once already (the Trilliant directory was added). Match on the prefix
# so a renamed block is not silently read as an empty one -- an empty `named`
# would print "0 of 0 matched", which reads like a pass.
TRAIN_PREFIX <- "Training institution"
block <- t1 %>% filter(startsWith(category, TRAIN_PREFIX))
if (!nrow(block))
  stop(sprintf(paste0(
    "no Table 1 category starts with '%s'. Categories present: %s.\n",
    "  Refusing to report '0 of 0 matched', which reads like a pass."),
    TRAIN_PREFIX, paste(unique(t1$category), collapse = "; ")), call. = FALSE)

named <- block %>%
  filter(!startsWith(characteristic, "Other named institution"),
         !startsWith(characteristic, "No school named")) %>%
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

# --- what share of the cohort this check speaks for --------------------------
n_top    <- sum(named$n, na.rm = TRUE)
n_other  <- sum(block$n[startsWith(block$characteristic, "Other named institution")], na.rm = TRUE)
n_none   <- sum(block$n[startsWith(block$characteristic, "No school named")], na.rm = TRUE)
n_namedall <- n_top + n_other
cat(sprintf(paste0(
  "\n--- coverage ---\n",
  "  cohort                                  %8s\n",
  "  any school named by either source       %8s  (%.1f%% of the cohort)\n",
  "  NO school named                         %8s  (%.1f%% of the cohort)\n",
  "  validated here (the top ten)            %8s  (%.1f%% of the cohort, %.1f%% of those named)\n"),
  format(t1_n, big.mark = ","),
  format(n_namedall, big.mark = ","), 100 * n_namedall / t1_n,
  format(n_none, big.mark = ","), 100 * n_none / t1_n,
  format(n_top, big.mark = ","), 100 * n_top / t1_n,
  if (n_namedall > 0) 100 * n_top / n_namedall else NA_real_))
cat(paste0(
  "  A result here is face validity for that slice and nothing wider. The\n",
  "  percentages Table 1 prints in this block are on the ", format(n_namedall, big.mark = ","),
  " who have a\n  school recorded, not on the cohort -- which is the right convention, and\n",
  "  is worth stating when the unknown row is ", sprintf("%.1f%%", 100 * n_none / t1_n), " of the table.\n"))
