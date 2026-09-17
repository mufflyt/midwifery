#!/usr/bin/env Rscript
# Import one reviewer-filled batch/queue CSV into the canonical append-only
# reviews table, then refresh derived state and the status artifact.
#   Rscript analysis/import_adjudication_verdicts.R <filled-batch.csv>
source(file.path("R", "truth_set_checks.R"))
source(file.path("R", "adjudication_queue.R"))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("usage: import_adjudication_verdicts.R <filled-batch.csv>")
s <- import_adjudication_verdicts(args[1], "artifacts/truth")
cat(sprintf("after import: %d/%d adjudicated | %d unresolved | %d needs_resolution | complete: %s\n",
            s$adjudicated_cases, s$total_cases, s$unresolved_cases,
            s$needs_resolution, toupper(s$complete)))
