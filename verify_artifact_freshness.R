#!/usr/bin/env Rscript
# Prove an artifact came from a specific invocation before reading its numbers.
#
# Twice a failed run left an older file in place and its counts were read as if
# fresh. A timestamp is not proof; a recorded run_id is.
#
# Usage: Rscript verify_artifact_freshness.R <artifact> <expected_run_id> [started_epoch]
suppressPackageStartupMessages({library(readr); library(jsonlite); library(digest)})

args <- commandArgs(trailingOnly = TRUE)
art <- args[1]; want_run <- args[2]
started <- if (length(args) >= 3) as.numeric(args[3]) else NA_real_
fail <- function(...) { cat("FRESHNESS FAIL: ", sprintf(...), "\n", sep = ""); quit(status = 1) }

if (!file.exists(art)) fail("artifact %s does not exist", art)
mf <- paste0(art, ".manifest.json")
if (!file.exists(mf)) fail("no sidecar manifest %s -- provenance unprovable", mf)
m <- fromJSON(mf)

if (!identical(m$run_id, want_run))
  fail("manifest run_id '%s' != expected '%s' (stale artifact)", m$run_id, want_run)
sha <- digest(file = art, algo = "sha256")
if (!identical(sha, m$artifact_sha256))
  fail("artifact sha256 %s != manifest %s (modified after publication)",
       substr(sha, 1, 16), substr(m$artifact_sha256, 1, 16))
d <- read_csv(art, show_col_types = FALSE, progress = FALSE)
if (nrow(d) != 22309) fail("row count %d != 22,309", nrow(d))
need <- c("name_evidence_class", "linkage_tier", "npi_tax_class", "n_candidates_pre_rank")
missing <- setdiff(need, names(d))
if (length(missing)) fail("refactor-era columns absent: %s", paste(missing, collapse = ", "))
if (!is.na(started) && file.mtime(art) < as.POSIXct(started, origin = "1970-01-01"))
  fail("artifact mtime precedes the run start")

cat("FRESHNESS OK\n")
cat(sprintf("  run_id            : %s\n", m$run_id))
cat(sprintf("  artifact sha256   : %s\n", substr(m$artifact_sha256, 1, 16)))
cat(sprintf("  source sha256     : %s\n", substr(m$source_script_sha256, 1, 16)))
cat(sprintf("  panel             : %s (%s, %s)\n", m$panel, m$panel_definition, m$year_window))
cat(sprintf("  rows              : %s\n", format(m$artifact_rows, big.mark = ",")))
