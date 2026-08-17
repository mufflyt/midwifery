#!/usr/bin/env Rscript
# =============================================================================
# Resolve gitignored test inputs through one explicit environment variable
# =============================================================================
#
# Several tests assert against row-level inputs that are gitignored by policy
# (midwives.csv, healthgrades_midwives.csv, artifacts/amcb_npi_linkage_FROZEN.csv
# and friends: names, addresses, NPIs). A fresh checkout or a git worktree
# therefore CANNOT contain them, and those tests degrade to
# "SKIP: inputs absent" or fail on a missing-file assertion.
#
# That degradation is dangerous for identity-matching work specifically. A unit
# suite with no data proves the code runs; it cannot prove that the same people
# still link to the same NPIs. A change that silently relinks 200 midwives
# passes a data-free suite perfectly.
#
# So: point MIDWIFERY_TEST_DATA_DIR at a directory holding those inputs (real
# files or symlinks, mirroring the repo's relative layout) and the tests resolve
# through it. Unset, everything behaves exactly as before -- repo-relative
# paths, same skips.
#
#   MIDWIFERY_TEST_DATA_DIR=/path/to/data Rscript tests/test_healthgrades_integrity.R
#
# NOTHING here hard-codes a checkout location. The variable is the only
# knob, so a run is reproducible from the manifest of hashes it was frozen
# against rather than from whatever happened to be lying in the working
# directory.
#
# Read-only by contract: tests resolve inputs through mw_data_path() and must
# never write to what it returns. When the target is a symlink into another
# checkout, a write would silently mutate that checkout's data.
# =============================================================================

#' Resolve a repo-relative input path, preferring the external data root
#'
#' @param relpath [character(1)]: path relative to the repo root, e.g.
#'   "healthgrades_midwives.csv" or "artifacts/amcb_npi_linkage_FROZEN.csv".
#' @return [character(1)] the external path when the variable is set AND the
#'   file exists there; otherwise `relpath` unchanged, so unset behaviour is
#'   byte-identical to before.
mw_data_path <- function(relpath) {
  root <- Sys.getenv("MIDWIFERY_TEST_DATA_DIR", "")
  if (!nzchar(root)) return(relpath)
  candidate <- file.path(root, relpath)
  if (file.exists(candidate)) candidate else relpath
}

#' Report which inputs resolved externally, for the run log
#'
#' Printed rather than returned silently: a reader of the test output must be
#' able to tell whether an assertion ran against real data or against nothing.
#'
#' @param relpaths [character]: the inputs a test depends on.
#' @return Invisibly, a data.frame of relpath / resolved / exists.
mw_data_report <- function(relpaths) {
  res <- data.frame(
    relpath  = relpaths,
    resolved = vapply(relpaths, mw_data_path, character(1)),
    stringsAsFactors = FALSE)
  res$exists <- file.exists(res$resolved)
  root <- Sys.getenv("MIDWIFERY_TEST_DATA_DIR", "")
  cat(sprintf("[external data] MIDWIFERY_TEST_DATA_DIR=%s\n",
              if (nzchar(root)) root else "(unset)"))
  for (i in seq_len(nrow(res))) {
    cat(sprintf("[external data]   %-46s %s\n", res$relpath[i],
                if (res$exists[i]) "found" else "MISSING"))
  }
  invisible(res)
}
