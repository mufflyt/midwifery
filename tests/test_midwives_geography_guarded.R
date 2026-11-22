#!/usr/bin/env Rscript
# =============================================================================
# midwives_geography_guarded.csv: row count must equal cohort_member exactly
# =============================================================================
# WHY THIS GUARDS SOMETHING REAL. No committed script produced this file for
# an unknown period -- every reader (repin_frozen_cohort.R,
# R/05-stage-progression.R, R/02-geocoding-completeness.R,
# audit_coordinate_provenance.R, verify_linkage_arms.R) just assumed it would
# be there. build_midwives_geography_guarded.R fills that gap by filtering
# artifacts/midwives_geography_FROZEN.csv to cohort-eligible rows -- this test
# asserts the one property repin_frozen_cohort.R's own fail-closed guard
# depends on: the output's row count must equal the frozen linkage's
# cohort_member count EXACTLY, or repin_frozen_cohort.R correctly refuses to
# pin it (a mismatch it is specifically designed to catch).
# =============================================================================
.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages(library(readr))


LINKAGE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
GEO_OUT <- "midwives_geography_guarded.csv"

if (!file.exists(LINKAGE) || !file.exists(GEO_OUT)) {
  cat(sprintf("  --   SKIP: %s and/or %s absent (person-level, gitignored;\n",
              LINKAGE, GEO_OUT),
      "       expected on a fresh checkout, real on a machine holding the frozen cohort)\n", sep = "")
  quit(status = 0L)
}

link <- read_csv(LINKAGE, show_col_types = FALSE, guess_max = Inf)
guarded <- read_csv(GEO_OUT, show_col_types = FALSE)

chk("cohort_member" %in% names(link),
    "T1 the frozen linkage carries cohort_member (reconcile_linkage.R computes it directly)")

if ("cohort_member" %in% names(link)) {
  n_cohort <- sum(link$cohort_member, na.rm = TRUE)
  chk(nrow(guarded) == n_cohort,
      sprintf("T2 midwives_geography_guarded.csv row count (%s) equals cohort_member count (%s) exactly",
              format(nrow(guarded), big.mark = ","), format(n_cohort, big.mark = ",")))
}

chk(!anyDuplicated(guarded$certification_number),
    "T3 no duplicate certification_number in the guarded geography snapshot")

cohort_ids <- link$certification_number[link$cohort_member]
chk(setequal(guarded$certification_number, cohort_ids),
    "T4 the guarded snapshot's certification numbers are EXACTLY the cohort-eligible set, no more, no fewer")

if (fails) { cat(sprintf("\nFAILED (%d)\n", fails)); quit(status = 1L) }
cat("\nPASS (0 failures)\n")
