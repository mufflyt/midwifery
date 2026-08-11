#!/usr/bin/env Rscript
# =============================================================================
# FROZEN dependency runner: completeness and stale-artifact detection
# =============================================================================
# The runner's value rests on two claims, and both are tested here rather than
# assumed:
#
#   1. It knows every script that depends on the frozen cohort. If it misses
#      one, the re-freeze leaves an artifact built from the old cohort and
#      NOTHING reports it -- the rebuild says "complete".
#   2. It can tell a fresh artifact from a stale one. A freshness check that
#      cannot detect staleness is the same as no check.
#
# Run: Rscript tests/test_frozen_dependency.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr); library(jsonlite)})
source(file.path(root, "R", "frozen_dependency_graph.R"))
source(file.path(root, "R", "lib", "artifact_provenance.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- discovery --\n")

rep <- frozen_dependency_report(".")
chk(rep$n_consumers > 0, sprintf("T1 consumers discovered [%d]", rep$n_consumers))

# The scanner must not appear in its own inventory. It names the frozen file and
# carries the network regex as literals, so a naive sweep classified it as a
# network-dependent consumer and broke the completeness check for a reason with
# nothing to do with the data.
chk(!any(basename(rep$consumers$script) %in%
           c("frozen_dependency_graph.R", "rebuild_frozen_dependents.R")),
    "T2 the scanner does not scan itself")

# Comment-only mentions are not dependencies. build_cd_provider_counts.R names
# the frozen file in a comment; counting it would inflate the rebuild set.
chk(!"build_cd_provider_counts.R" %in% rep$consumers$script,
    "T3 a comment-only mention is not counted as a consumer")

cat("\n-- completeness against the declared order --\n")

# Parse the declared order out of the runner without executing it: sourcing it
# would run the dry run as a side effect of the test.
runner <- paste(readLines("rebuild_frozen_dependents.R", warn = FALSE), collapse = "\n")
# (?s) so "." spans newlines -- without it the block never matches and every
# downstream assertion silently compares against an EMPTY declared set.
blk <- regmatches(runner, regexpr("(?s)REBUILD_ORDER <- list\\(.*?\\ndeclared <-", runner, perl = TRUE))
declared <- unique(gsub('"', '', unlist(regmatches(blk,
  gregexpr('"[A-Za-z0-9_./-]+\\.R"', blk)))))
chk(length(declared) > 0, sprintf("T4 declared order parsed [%d scripts]", length(declared)))

discovered <- frozen_rebuildable(rep$consumers)$script
chk(setequal(declared, discovered),
    sprintf("T5 declared set == discovered rebuildable set [%d vs %d]%s",
            length(declared), length(discovered),
            if (setequal(declared, discovered)) "" else
              paste0(" | missing: ", paste(setdiff(discovered, declared), collapse = ","),
                     " | extra: ", paste(setdiff(declared, discovered), collapse = ","))))

# length() guard first: all(file.exists(character(0))) is TRUE, so without it
# this reports OK on an empty declared set -- a vacuous pass, the exact trap G4
# exists to catch, reproduced here in my own test.
chk(length(declared) > 0 && all(file.exists(declared)),
    sprintf("T6 every declared script exists [%d declared, %d missing]",
            length(declared), sum(!file.exists(declared))))

# Network scripts must never enter a deterministic rebuild: re-running a
# scraper is a NEW OBSERVATION, not a rebuild.
chk(!any(rep$network_excluded %in% declared),
    sprintf("T7 no network/scraping script is in the rebuild order [%d excluded]",
            rep$n_network_excluded))

cat("\n-- stale detection --\n")

# NEGATIVE CONTROL, on a temp artifact so nothing real is touched: an artifact
# whose recorded input hash no longer matches must be reported stale. Without
# this the freshness check could pass by never detecting anything.
{
  td <- file.path(tempdir(), paste0("provchk", Sys.getpid()))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  owd2 <- setwd(td); on.exit(setwd(owd2), add = TRUE)
  writeLines("a,b\n1,2", "input.csv")
  write_with_provenance(data.frame(x = 1), "out.csv", inputs = "input.csv")
  fresh <- check_provenance("out.csv")
  chk(nrow(fresh) > 0 && !any(fresh$stale), "T8 a freshly built artifact is not stale")
  writeLines("a,b\n9,9", "input.csv")            # input changes underneath it
  after <- check_provenance("out.csv")
  chk(nrow(after) > 0 && any(after$stale),
      "T9 NEGATIVE CONTROL: changing an input makes the artifact stale")
  setwd(owd2)
}

cat("\n-- the runner is safe by default --\n")

chk(grepl('REBUILD_APPLY', runner) &&
      grepl('APPLY\\s*<-\\s*identical\\(Sys\\.getenv\\("REBUILD_APPLY", "0"\\), "1"\\)', runner),
    "T10 execution is opt-in via REBUILD_APPLY, dry run by default")
chk(grepl("FROZEN CHANGED DURING A REBUILD", runner, fixed = TRUE),
    "T11 the runner aborts if FROZEN moves during a rebuild")
chk(grepl("incomplete rebuild", runner, fixed = TRUE),
    "T12 the runner fails on an incomplete rebuild")
chk(grepl("refusing to rebuild while dependency completeness fails", runner, fixed = TRUE),
    "T13 the runner refuses to apply when completeness fails")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
