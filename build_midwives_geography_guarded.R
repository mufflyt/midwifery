#!/usr/bin/env Rscript
# =============================================================================
# Cohort-eligible geography snapshot ("the guarded linkage's geography")
# =============================================================================
# WHY THIS SCRIPT EXISTS. Several scripts (repin_frozen_cohort.R,
# R/05-stage-progression.R, R/02-geocoding-completeness.R,
# audit_coordinate_provenance.R, verify_linkage_arms.R) read
# midwives_geography_guarded.csv, but no committed script has ever produced
# it -- git history shows only readers. Its role ("Run Stage 3 against the
# guarded linkage", commit 7cb1670, 2026-08-08) makes clear what it always
# was: artifacts/midwives_geography_FROZEN.csv (Stage 3's real, current
# output) FILTERED to cohort-eligible rows only, matching the identifiability
# guard the "guarded" name refers to. Filling in the missing producer, not
# guessing at new data -- the schema and the row semantics are already fully
# specified by every script that already reads this file.
#
# WHY THE ROW COUNT MUST MATCH cohort_members EXACTLY. repin_frozen_cohort.R
# refuses to pin a source whose row count disagrees with the frozen linkage's
# own declared cohort_members -- correctly: pinning a mismatched source would
# replace one vintage mismatch with another. midwives_geography_FROZEN.csv
# itself is NPI-matched (17,181+ rows: everyone with a resolved NPI,
# including class-5/sensitivity rows that never entered the cohort), not
# cohort-filtered, so it fails that check directly. Filtering by
# cohort_member (R/amcb_cohort_membership.R::is_cohort_member(), the same
# rule every other cohort-membership decision in this project uses) is what
# makes the two numbers agree.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (for cohort_member)
#          artifacts/midwives_geography_FROZEN.csv (Stage 3's geography)
# Output : midwives_geography_guarded.csv (repo root, matching every existing
#          reader's hardcoded path -- NOT artifacts/, though
#          repin_frozen_cohort.R's own SOURCE constant said otherwise; see
#          that script's own fix in this same change)
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path("R", "amcb_cohort_membership.R"))

linkage <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE,
                    guess_max = Inf)
if (!"cohort_member" %in% names(linkage))
  stop("artifacts/amcb_npi_linkage_FROZEN.csv has no cohort_member column -- ",
       "re-run reconcile_linkage.R first (it computes this directly now).",
       call. = FALSE)

geo <- read_csv("artifacts/midwives_geography_FROZEN.csv", show_col_types = FALSE)

cohort_ids <- linkage$certification_number[linkage$cohort_member]
out <- geo %>% filter(certification_number %in% cohort_ids)

stopifnot(
  "row count must equal the frozen linkage's own cohort_member count" =
    nrow(out) == length(cohort_ids),
  "no duplicate certification_number" = !anyDuplicated(out$certification_number)
)

write_csv(out, "midwives_geography_guarded.csv", na = "")
cat(sprintf("wrote midwives_geography_guarded.csv (%s of %s geography rows are cohort-eligible)\n",
            format(nrow(out), big.mark = ","), format(nrow(geo), big.mark = ",")))
