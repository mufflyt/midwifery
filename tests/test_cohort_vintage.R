#!/usr/bin/env Rscript
# =============================================================================
# Cohort vintage: every artifact must describe the SAME freeze
# =============================================================================
# THE DEFECT THIS PREVENTS (found 2026-08-31). The cohort flow figure drew
# 14,764 midwifery-taxonomy + 2,134 nursing-taxonomy merging into an "analytic
# cohort" of 16,892. Those numbers do not add up, and they did not add up
# because they came from opposite sides of a re-freeze:
#
#   artifacts/frozen_cohort/       pinned 2026-08-10 05:31, 16,892 rows
#   refreeze_option2_...T192207    2026-08-10 19:22, 16,892 -> 16,898 (+6)
#
# The snapshot was pinned about fourteen hours before the re-freeze that the
# repository documents as its own Option 2 decision, and was never re-pinned.
# Everything derived from it -- analytic_cohort.csv, composition_rucc_cat.csv,
# the pinned panel constant -- still describes the previous cohort, while
# linkage_completeness_by_status.csv describes the current one.
#
# Recency is no protection: composition_rucc_cat.csv was rebuilt three weeks
# LATER and still carries the old number, because it inherits it through
# analytic_cohort.csv. Only the vintages can catch this, so they are compared
# here.
#
# This test reads only TRACKED metadata -- two JSON sidecars and two aggregate
# CSVs -- so it runs on a clean checkout with no person-level data present.
#
# Run: Rscript tests/test_cohort_vintage.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(jsonlite); library(readr); library(dplyr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
skip <- function(m) cat(sprintf("  skip %s\n", m))

MANIFEST    <- "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json"
FINGERPRINT <- "artifacts/frozen_cohort/INPUT_FINGERPRINT.json"
COMPLETE    <- "artifacts/linkage_completeness_by_status.csv"
COMPOSITION <- "artifacts/composition_rucc_cat.csv"

cat("\n-- the freeze of record --\n")

if (!file.exists(MANIFEST)) {
  skip("no crosswalk manifest; nothing to compare against")
} else {
  man <- fromJSON(MANIFEST)
  members <- as.integer(man$cohort_members)
  chk(!is.na(members) && members > 0,
      sprintf("V1 manifest declares cohort_members [%s, run %s]",
              format(members, big.mark = ","), man$run_id))

  # --- the linkage table -----------------------------------------------------
  cat("\n-- derived aggregates against that freeze --\n")

  if (!file.exists(COMPLETE)) {
    skip("linkage_completeness_by_status.csv absent")
  } else {
    lc <- read_csv(COMPLETE, show_col_types = FALSE)
    lc_cohort <- sum(lc$matched) + sum(lc$matched_nursing_taxonomy)
    chk(lc_cohort == members,
        sprintf("V2 linkage table's cohort == the freeze [%s vs %s]%s",
                format(lc_cohort, big.mark = ","), format(members, big.mark = ","),
                if (lc_cohort == members) "" else
                  sprintf(" | off by %+d -- one of them predates the other",
                          lc_cohort - members)))
  }

  # --- the pinned geography snapshot ----------------------------------------
  # This is the one that was wrong. The fingerprint records the row count of the
  # snapshot every geography artifact is derived from; if it disagrees with the
  # freeze, the flow figure's lower half describes a different cohort from its
  # upper half and NOTHING else reports it.
  if (!file.exists(FINGERPRINT)) {
    skip("frozen_cohort/INPUT_FINGERPRINT.json absent")
  } else {
    fp <- fromJSON(FINGERPRINT)
    fp_rows <- as.integer(fp$rows)
    chk(fp_rows == members,
        sprintf("V3 pinned geography snapshot == the freeze [%s vs %s]%s",
                format(fp_rows, big.mark = ","), format(members, big.mark = ","),
                if (fp_rows == members) "" else
                  sprintf(paste(" | off by %+d. Snapshot pinned %s; freeze is %s.",
                                "Re-pin with repin_frozen_cohort.R on the machine",
                                "holding the person-level files."),
                          fp_rows - members, fp$frozen_at, man$run_id)))
  }

  # --- the composition table -------------------------------------------------
  if (!file.exists(COMPOSITION)) {
    skip("composition_rucc_cat.csv absent")
  } else {
    comp <- read_csv(COMPOSITION, show_col_types = FALSE)
    grp <- c("1_retained", "2_newly_npi_resolved", "3_in_cohort_no_final_npi")
    comp_n <- comp %>% filter(.data$group %in% grp) %>% pull(.data$n) %>% sum()
    chk(comp_n == members,
        sprintf("V4 composition table's cohort == the freeze [%s vs %s]%s",
                format(comp_n, big.mark = ","), format(members, big.mark = ","),
                if (comp_n == members) "" else
                  sprintf(paste(" | off by %+d. It inherits the pinned snapshot",
                                "through analytic_cohort.csv, so rebuilding it",
                                "alone will NOT fix this."), comp_n - members)))
  }
}

cat(sprintf("\n%s (%d failure%s)\n", if (fails) "FAIL" else "PASS", fails,
            if (fails == 1L) "" else "s"))
quit(status = if (fails) 1L else 0L)
