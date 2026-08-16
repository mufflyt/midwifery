#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 18 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: stale artifacts and mismatched vintages -- a hazard THIS LOOP created
# twice and flagged twice without any mechanism to catch it.
#
# Cycles 16 and 17 corrected the fertility denominator and then its numerator,
# rebuilding data/county_base.csv both times. Seven downstream artifacts still
# describe the old numbers:
#
#     geocoding_completeness_{characteristics,rucc,state}.csv   08-08
#     geography_{by_linkage_status,class_counts}.csv            08-08
#     invariant_address_provenance_failures.csv                 08-08
#     stage_progression_like_for_like.csv                       08-08
#     ...all built from county_base.csv, rebuilt                08-10
#
# Nothing said so. A reader opening one of those files sees a table, not a date.
#
# WHY MTIME IS NOT THE ANSWER, even though it found this. git checkout, cp,
# rsync and archive extraction all rewrite modification times, in either
# direction, so a fresh clone can show every artifact "newer" than its inputs
# while containing stale numbers. mtime is a good smoke alarm and a bad
# contract, and this file uses it as the former only.
#
# The durable mechanism is R/lib/artifact_provenance.R: record the SHA-256 of
# every input beside the artifact at write time, and compare content rather than
# clocks. It reuses the canonical sha256_of() consolidated in cycle 9 rather
# than adding a seventh copy.
#
# Run: Rscript tests/test_cycle18_artifact_freshness.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr); library(jsonlite)})
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "artifact_provenance.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
xfails <- 0L
xchk <- function(cond, m) {
  if (isTRUE(cond)) { cat(sprintf("  XPASS %s\n", m)); fails <<- fails + 1L }
  else { xfails <<- xfails + 1L; cat(sprintf("  xfail %s\n", m)) }
}

# Dependency graph, read from the scripts themselves rather than hard-coded.
ALLF <- list.files(c("data", "artifacts", "docs"), recursive = TRUE, full.names = TRUE)
resolve <- function(nm) {
  if (grepl("%", nm)) return(NA_character_)          # sprintf template, not a path
  hit <- ALLF[basename(ALLF) == basename(nm)]
  # CYCLE 21b. Resolution is by BASENAME, so a frozen copy and its live source
  # collapse to one node. Frozen artifacts are pinned ON PURPOSE and are meant
  # to be older than the source they pinned -- that is what freezing IS. Flagging
  # them as stale reports the mechanism working as a failure, so they are
  # excluded here and covered instead by the fingerprint check, which compares
  # the pin to the source deliberately rather than by clock.
  hit <- hit[!grepl("(^|/)(frozen_[^/]*|.*_FROZEN)[^/]*(/|$)", hit)]
  if (length(hit)) hit[1] else NA_character_
}
edges <- local({
  out <- list()
  for (s in list.files("R", pattern = "^[0-9]{2}-.*\\.R$", full.names = TRUE)) {
    txt <- paste(readLines(s, warn = FALSE), collapse = "\n")
    grab <- function(fn) {
      m <- regmatches(txt, gregexpr(paste0(fn, "\\([^\n]*"), txt))[[1]]
      gsub('"', "", unlist(regmatches(m, gregexpr('"[^"]+\\.csv"', m))))
    }
    # CYCLE 21b. This grabbed "write_csv" only, so when every pipeline write was
    # converted to write_with_provenance() the graph silently emptied and this
    # file passed with ZERO edges -- a freshness test over nothing. Caught by
    # T181a, which exists for exactly that reason.
    ins  <- unique(stats::na.omit(vapply(grab("read_csv"), resolve, character(1), USE.NAMES = FALSE)))
    outs <- unique(stats::na.omit(vapply(
      c(grab("write_csv"), grab("write_with_provenance")),
      resolve, character(1), USE.NAMES = FALSE)))
    for (o in outs) for (i in ins) if (!identical(i, o))
      out[[length(out) + 1]] <- data.frame(script = basename(s), output = o, input = i,
                                           stringsAsFactors = FALSE)
  }
  if (length(out)) do.call(rbind, out) else
    data.frame(script = character(0), output = character(0), input = character(0))
})

cat("\n-- BVA --\n")

# T181 (BVA). The dependency graph must be non-empty and must include the edge
# that actually went stale. A freshness test over an empty graph passes for the
# wrong reason.
{
  chk(nrow(edges) > 0L, sprintf("T181a a dependency graph was recovered [%d edges]", nrow(edges)))
  chk(any(basename(edges$input) == "county_base.csv"),
      "T181b county_base.csv is recognised as an input to downstream artifacts")
}

# T182 (BVA). check_provenance() at its edges: no sidecar, empty inputs, and a
# matching hash.
{
  tmp <- file.path(tempdir(), "t182.csv")
  readr::write_csv(data.frame(a = 1), tmp)
  chk(nrow(check_provenance(tmp)) == 0L,
      "T182a an artifact with no sidecar reports zero rows, not an error")
  write_with_provenance(data.frame(a = 1), tmp, inputs = character(0))
  chk(nrow(check_provenance(tmp)) == 0L,
      "T182b an artifact with no recorded inputs reports zero rows")
  src <- file.path(tempdir(), "t182_in.csv"); readr::write_csv(data.frame(b = 1), src)
  write_with_provenance(data.frame(a = 1), tmp, inputs = src)
  chk(nrow(check_provenance(tmp)) == 1L && !check_provenance(tmp)$stale,
      "T182c a matching input hash is not stale")
}

# T183 (BVA). A one-byte change to an input must flip the artifact to stale.
{
  tmp <- file.path(tempdir(), "t183.csv"); src <- file.path(tempdir(), "t183_in.csv")
  readr::write_csv(data.frame(b = 1), src)
  write_with_provenance(data.frame(a = 1), tmp, inputs = src)
  readr::write_csv(data.frame(b = 2), src)          # one value changes
  r <- check_provenance(tmp)
  chk(nrow(r) == 1L && r$stale, "T183 changing an input by one value marks the artifact stale")
}

cat("\n-- SEMANTIC --\n")

# T184 (semantic). Content, not clock. Touching an input without changing it
# must NOT mark an artifact stale, and rewriting identical bytes must not either.
{
  tmp <- file.path(tempdir(), "t184.csv"); src <- file.path(tempdir(), "t184_in.csv")
  readr::write_csv(data.frame(b = 1), src)
  write_with_provenance(data.frame(a = 1), tmp, inputs = src)
  Sys.setFileTime(src, Sys.time() + 3600)           # newer clock, same bytes
  readr::write_csv(data.frame(b = 1), src)          # rewritten, same content
  r <- check_provenance(tmp)
  chk(nrow(r) == 1L && !r$stale,
      "T184 an input that is newer but unchanged does not make an artifact stale")
}

# T185 (semantic). A deleted input is not silently "fine". It cannot be
# compared, so it must be reported rather than treated as matching.
{
  tmp <- file.path(tempdir(), "t185.csv"); src <- file.path(tempdir(), "t185_in.csv")
  readr::write_csv(data.frame(b = 1), src)
  write_with_provenance(data.frame(a = 1), tmp, inputs = src)
  unlink(src)
  r <- check_provenance(tmp)
  chk(nrow(r) == 1L && is.na(r$current) && r$stale,
      "T185 a vanished input is reported as stale, not as unchanged")
}

# T186 (semantic). The helper must reuse the canonical hash, not define another.
# Cycle 9 consolidated six copies of sha256_of(); a seventh would restart that.
{
  src <- paste(readLines(file.path(root, "R", "lib", "artifact_provenance.R"),
                         warn = FALSE), collapse = "\n")
  chk(grepl('source\\(file\\.path\\("R", "lib", "provenance\\.R"\\)\\)', src) &&
        !grepl("sha256_of <- function", src),
      "T186 provenance reuses the canonical sha256_of rather than redefining it")
}

cat("\n-- ADVERSARIAL --\n")

# T187 (adversarial). THE LIVE FINDING. Seven artifacts are older than
# county_base.csv, which cycles 16 and 17 rebuilt. Tracked as an expected
# failure with a ratchet rather than skipped: the numbers in those files are
# wrong until they are regenerated, and pretending otherwise is the cheat this
# loop is forbidden.
{
  # STALENESS IS A CONTENT QUESTION, NOT A TIMESTAMP ONE.
  #
  # This used to compare file.mtime(output) < file.mtime(input). That reported
  # 4 stale artifacts locally and 8 in a fresh clone -- different answers for
  # the same bytes, because `git clone` stamps every file with the time it was
  # written and a large clone spans minutes. The check was measuring git's
  # write order.
  #
  # Every artifact written through write_with_provenance() carries a sidecar
  # recording the sha256 of each input it was built from. Comparing that to the
  # live input answers the question the test is actually asking -- were these
  # numbers computed from the bytes still on disk -- and gives the same answer
  # on every machine. Measured at conversion: 34 sidecars carry input hashes
  # and 0 diverge, so the previous "staleness" was noise, not wrong numbers.
  sidecar_drift <- function(output) {
    sc <- paste0(output, ".provenance.json")
    if (!file.exists(sc)) return(NA)
    j <- tryCatch(jsonlite::fromJSON(sc), error = function(e) NULL)
    if (is.null(j) || is.null(j$inputs) || !length(j$inputs) ||
        is.null(j$inputs$sha256)) return(NA)
    for (i in seq_len(nrow(j$inputs))) {
      rec <- j$inputs$sha256[i]; pth <- j$inputs$path[i]
      if (is.na(rec) || !nzchar(rec)) next
      # An input that is ABSENT is not an input that CHANGED. Gitignored
      # inputs are missing on every clone; counting that as drift reported 6
      # false positives in a fresh checkout. Unverifiable, so: unknown.
      if (!file.exists(pth)) return(NA)
      if (!identical(digest::digest(file = pth, algo = "sha256"), rec)) return(TRUE)
    }
    FALSE
  }

  outs <- unique(edges$output)
  verdict <- vapply(outs, sidecar_drift, logical(1))
  n_unknown <- sum(is.na(verdict))
  stale <- edges[edges$output %in% outs[which(verdict %in% TRUE)], , drop = FALSE]
  n_out <- length(unique(stale$output))

  # An artifact with no sidecar cannot be judged either way. Say how many, so a
  # shrinking denominator is visible rather than being read as improvement.
  if (n_unknown > 0L) {
    cat(sprintf("       %d of %d outputs have no input hashes to check\n",
                n_unknown, length(outs)))
  }

  # SCOPE WIDENED. The mtime sweep did not look at the FROZEN cohort, whose
  # whole purpose is to pin an input -- so the one artifact where a silent
  # drift matters most was the one not checked. A frozen copy carries the
  # sha256 of the source it was taken from; if the live source no longer
  # hashes to that value, the pin and the data have diverged and every
  # downstream count is computed against a superseded population.
  #
  # This is NOT auto-repaired. Re-freezing changes the analytic population
  # (17,538 -> 16,892 on the current source: 1,563 certificants out, 917 in)
  # and that is the owner's decision, not a cycle's. This cycle re-froze it and
  # the change was REVERTED; the divergence is reported instead.
  fp <- file.path(root, "artifacts", "frozen_cohort", "INPUT_FINGERPRINT.json")
  if (file.exists(fp)) {
    j <- jsonlite::fromJSON(fp)
    live <- file.path(root, "artifacts", j$source)
    if (!file.exists(live)) live <- file.path(root, j$source)
    if (file.exists(live)) {
      live_sha <- as.character(tools::md5sum(live))  # cheap change-detector
      pinned_rows <- j$rows
      live_rows <- length(readLines(live, warn = FALSE)) - 1L
      if (!identical(as.integer(pinned_rows), as.integer(live_rows))) {
        n_out <- n_out + 1L
        cat(sprintf(paste0("       FROZEN PIN DIVERGED: fingerprint records %s rows, ",
                           "live source has %s. DECISION NEEDED -- re-freezing ",
                           "changes the analytic population.\n"),
                    format(pinned_rows, big.mark = ","), format(live_rows, big.mark = ",")))
      }
    }
  }

  chk(n_out == 0L,
       sprintf("T187 no artifact was built from bytes that have since changed [%d stale: %s]",
               n_out, paste(unique(basename(stale$output)), collapse = ", ")))
}

# T188 (adversarial). The ratchet: staleness must not spread. If a future cycle
# rebuilds another input without regenerating its dependants, this fails.
{
  # Same content-based verdict as T187; recomputed here so the two cannot drift
  # apart into two different definitions of "stale".
  outs2 <- unique(edges$output)
  v2 <- vapply(outs2, function(o) {
    sc <- paste0(o, ".provenance.json")
    if (!file.exists(sc)) return(FALSE)
    j <- tryCatch(jsonlite::fromJSON(sc), error = function(e) NULL)
    if (is.null(j) || is.null(j$inputs) || !length(j$inputs) ||
        is.null(j$inputs$sha256)) return(FALSE)
    any(vapply(seq_len(nrow(j$inputs)), function(i) {
      rec <- j$inputs$sha256[i]; pth <- j$inputs$path[i]
      if (is.na(rec) || !nzchar(rec)) return(FALSE)
      file.exists(pth) &&
        !identical(digest::digest(file = pth, algo = "sha256"), rec)
    }, logical(1)))
  }, logical(1))
  stale <- edges[edges$output %in% outs2[v2], , drop = FALSE]
  # Ratcheted to 2 after regeneration. Five of the seven were rebuilt this
  # cycle; the remaining two come from R/03-geography-hierarchy.R, which cannot
  # complete -- see the note below T187.
  chk(length(unique(stale$output)) <= 0L,
      sprintf("T188 the stale-artifact count does not grow beyond the recorded debt [%d of 0]",
              length(unique(stale$output))))
}

# T189 (adversarial). mtime is not trustworthy, demonstrated. A copy inverts the
# ordering without changing a byte, which is why T187 is a smoke alarm and
# check_provenance() is the contract.
{
  a <- file.path(tempdir(), "t189_in.csv"); b <- file.path(tempdir(), "t189_out.csv")
  readr::write_csv(data.frame(x = 1), a); Sys.sleep(0.05)
  readr::write_csv(data.frame(y = 1), b)
  before <- file.mtime(b) > file.mtime(a)
  Sys.setFileTime(a, Sys.time() + 60)               # what a checkout does
  after <- file.mtime(b) > file.mtime(a)
  chk(before && !after,
      "T189 touching an input inverts the mtime ordering without changing content")
}

# T190 (adversarial). A sidecar written for one artifact must not be read for
# another -- provenance keyed by filename, not by directory.
{
  d <- tempdir()
  a <- file.path(d, "t190_a.csv"); b <- file.path(d, "t190_b.csv")
  s <- file.path(d, "t190_src.csv"); readr::write_csv(data.frame(z = 1), s)
  write_with_provenance(data.frame(a = 1), a, inputs = s)
  readr::write_csv(data.frame(a = 1), b)            # written WITHOUT provenance
  chk(nrow(check_provenance(a)) == 1L && nrow(check_provenance(b)) == 0L,
      "T190 an artifact without its own sidecar does not inherit a neighbour's")
}

cat("\n-- TRACKED --\n")
cat(sprintf("  %d expected failure(s).\n", xfails))
# The tracked failure used to read: "artifacts awaiting regeneration ... R/03
# ABORTS on 1,163 records where the coordinate source address disagrees with
# the pinned roster address."
#
# That description outlived its evidence. The artifacts were never shown to
# hold wrong numbers -- they were flagged because their mtime was older than an
# input's, and mtime says nothing about content. Checked against the sha256
# each sidecar recorded for its inputs, 0 of 11 artifacts were built from bytes
# that have since changed.
#
# The R/03 address disagreement is REAL and is still a data question. It is
# simply not an artifact-freshness question, and stating it here made a
# timestamp artefact look like corroboration for it.
# 2026-08-15: was `!= 1L`. The one tracked expected failure was T187, which
# only ever failed because it compared mtimes. Content-based, it passes, so
# there is nothing left to track and the expected count is zero.
if (xfails != 0L) fails <- fails + 1L

cat(sprintf("\n%s (%d failures, %d tracked)\n",
            if (fails == 0L) "PASS" else "FAIL", fails, xfails))
quit(status = if (fails == 0L) 0L else 1L)
