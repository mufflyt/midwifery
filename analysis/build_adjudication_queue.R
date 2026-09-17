#!/usr/bin/env Rscript
# Build the current unresolved-case queue (blinded, batch-tagged) and the
# machine-readable status artifact. Run from the repo root:
#   Rscript analysis/build_adjudication_queue.R
source(file.path("R", "truth_set_checks.R"))
source(file.path("R", "adjudication_queue.R"))
q <- adjudication_queue("artifacts/truth")
dir.create("artifacts/adjudication", showWarnings = FALSE, recursive = TRUE)
utils::write.csv(q, "artifacts/adjudication/adjudication_queue.csv",
                 row.names = FALSE, na = "")
s <- adjudication_status("artifacts/truth")
cat(sprintf("queue: %d unresolved of %d | adjudicated %d (match %d / nonmatch %d / insufficient %d) | needs_resolution %d | complete: %s\n",
            s$unresolved_cases, s$total_cases, s$adjudicated_cases,
            s$match, s$nonmatch, s$insufficient, s$needs_resolution,
            toupper(s$complete)))
