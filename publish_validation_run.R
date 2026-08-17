#!/usr/bin/env Rscript
# =============================================================================
# Publish a completed validation run's shareable aggregates
# =============================================================================
# Run as: Rscript publish_validation_run.R [--run=artifacts/validation/run-XXX]
#
# WHY THIS IS A SEPARATE COMMAND. The verifier deliberately cannot write the
# tracked canonical CSVs -- two concurrent verifiers once raced on exactly those
# paths and could have left a set blended from two different runs. Removing that
# capability from the verifier is the fix, so the ability is not handed back to
# it behind a flag; publishing is a distinct action a person or a CI job takes
# once, against a run that has already promoted.
#
# WHAT IS PUBLISHED. Only the aggregates. `osmde_still_unmeasured.csv` is
# person-level (certification numbers) and stays gitignored in the run
# directory, same treatment as every other row-level artifact in this repo.
#
# Source of truth is artifacts/validation/latest, which by construction points
# at a run where every gate passed.
#
# Inputs : artifacts/validation/latest/  (or --run=)
# Outputs: artifacts/osmde_validation_table.csv
#          artifacts/osmde_full_cohort_coverage_by_rucc.csv
#          artifacts/osmde_full_cohort_coverage_by_state.csv
#          artifacts/osmde_polygon_quality_by_rucc.csv
#          artifacts/osmde_strict_containment_failures.csv
# =============================================================================
suppressPackageStartupMessages({ library(readr) })
source(file.path("R", "lib", "validation_run.R"))
source(file.path("R", "lib", "resume_state.R"))   # atomic_write_csv

args <- commandArgs(trailingOnly = TRUE)
hit  <- grep("^--run=", args, value = TRUE)
run  <- if (length(hit)) sub("^--run=", "", hit[1]) else
  validation_run_latest("artifacts/validation")

if (is.na(run) || !dir.exists(run))
  stop("no promoted validation run found. Run verify_osmde_full_cohort_coverage.R first.")
cat(sprintf("publishing from: %s\n", run))

# Aggregates only. Adding a person-level file to this vector would quietly start
# committing certification numbers, so the list is explicit rather than a glob.
PUBLISH <- c("osmde_validation_table.csv",
             "osmde_tolerance_provenance.csv",
             "osmde_full_cohort_coverage_by_rucc.csv",
             "osmde_full_cohort_coverage_by_state.csv",
             "osmde_polygon_quality_by_rucc.csv",
             # The coordinate-bearing detail file is deliberately ABSENT: it
             # names 2,852 practice locations, which this repo treats as
             # person-derived data. The hashed summary carries every
             # measurement needed to audit the tolerance decision.
             "osmde_strict_containment_summary.csv")

missing <- PUBLISH[!file.exists(file.path(run, PUBLISH))]
if (length(missing))
  stop("run is missing expected outputs, refusing to publish a partial set: ",
       paste(missing, collapse = ", "))

# PUBLISHING COPIES BYTES. IT DOES NOT RE-SERIALISE.
#
# The first version read each CSV with read_csv() and wrote it back with
# write_csv(). That round trip is not identity: one value came out of the
# validated run as 0.042659999999999997 and was republished as
# 0.04265999999999999. Nothing about the analysis changed, but the published
# file was no longer bit-for-bit the file the gates ran against -- which is
# precisely the property publication exists to provide. A reviewer hashing the
# tracked artifact against the run directory would have found a mismatch and
# had no way to tell float formatting from a real edit.
#
# Copy to a temp name in the destination directory, then rename: atomic on
# POSIX, so an interrupted publish leaves the previous complete file intact.
for (f in PUBLISH) {
  src <- file.path(run, f)
  dst <- file.path("artifacts", f)
  tmp <- paste0(dst, ".publishing")
  if (!file.copy(src, tmp, overwrite = TRUE))
    stop("could not stage ", tmp)
  if (!file.rename(tmp, dst)) { unlink(tmp); stop("could not publish ", dst) }
  stopifnot("published bytes differ from the validated run" =
              identical(tools::md5sum(src)[[1]], tools::md5sum(dst)[[1]]))
  # Provenance sidecars travel with their artifact. Publishing the CSV alone
  # silently dropped them, leaving tracked artifacts with no record of inputs.
  for (sc in paste0(c(src), ".provenance.json")) {
    if (file.exists(sc)) file.copy(sc, paste0(dst, ".provenance.json"), overwrite = TRUE)
  }
  cat(sprintf("  %-46s %s bytes  (hash verified)\n", f,
              format(file.size(dst), big.mark = ",")))
}
writeLines(basename(run), "artifacts/osmde_published_validation_run.txt")
cat(sprintf("\npublished %s files from run %s\n", length(PUBLISH), basename(run)))
cat("run id recorded in artifacts/osmde_published_validation_run.txt\n")
