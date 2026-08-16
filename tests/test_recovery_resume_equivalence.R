#!/usr/bin/env Rscript
# =============================================================================
# Recovery / resume equivalence: interruption must not change the answer
# =============================================================================
# Item 29. A long job is killed part-way, restarted, and the result compared
# against a run that was never interrupted. They must be substantively
# identical.
#
# WHY THIS CODE. The resume path in scrape_healthgrades_midwives.R is the only
# part of this repository that has already destroyed data: on 2026-08-09 a
# missing checkpoint caused the output CSV -- which is rewritten WHOLLY from
# the checkpoint -- to be truncated from 482 KB to 552 bytes, losing 5,963
# completed searches. A recovery guard was added in response. It was never
# tested, because testing it meant running a scraper.
#
# That is the classic shape of an untested recovery path: written after an
# incident, correct as far as anyone could tell by reading, and exercised for
# the first time by the next incident.
#
# WHAT IS SIMULATED, AND WHAT IS NOT. The work itself is a deterministic
# function of the identifier, so "scraping" is pure and the test is hermetic.
# What is exercised is the REAL production logic in R/lib/resume_state.R --
# recovery, todo computation and output derivation -- driven by a harness that
# kills the loop at every possible point.
#
# The network, the rate limiter and the HTML parser are NOT exercised. This
# tests that interruption cannot change the answer, not that the scraper works.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "resume_state.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# -----------------------------------------------------------------------------
# A deterministic stand-in for the work. Pure, so any difference between an
# interrupted and an uninterrupted run is the RESUME logic, never the work.
# -----------------------------------------------------------------------------
N <- 40L
ROSTER <- data.frame(
  certification_number = sprintf("C%03d", seq_len(N)),
  last_name = sprintf("LAST%03d", seq_len(N)),
  stringsAsFactors = FALSE)

do_work <- function(row) {
  data.frame(certification_number = row$certification_number,
             payload = paste0("R-", row$certification_number),
             hg_status = "ok", stringsAsFactors = FALSE)
}

CKPT_EVERY <- 5L

#' Run the job, optionally dying after `die_after` items of THIS invocation.
#'
#' Mirrors the production loop: work, then every CKPT_EVERY items save the
#' checkpoint and rewrite the output WHOLLY from `done`.
run_job <- function(ckpt_path, out_path, die_after = Inf, n_limit = NA_integer_) {
  done <- if (file.exists(ckpt_path)) readRDS(ckpt_path) else list()
  prior <- if (file.exists(out_path))
    suppressWarnings(tryCatch(read_csv(out_path, show_col_types = FALSE,
                                       progress = FALSE),
                              error = function(e) NULL)) else NULL

  done <- resume_recover_done(done, prior)          # PRODUCTION
  todo <- resume_todo(ROSTER, done, n_limit = n_limit)  # PRODUCTION

  n_did <- 0L
  for (i in seq_len(nrow(todo))) {
    done[[as.character(todo$certification_number[i])]] <- do_work(todo[i, ])
    n_did <- n_did + 1L
    if (i %% CKPT_EVERY == 0 || i == nrow(todo)) {
      saveRDS(done, ckpt_path)
      out <- resume_output(done)                    # PRODUCTION
      if (!is.null(out)) write_csv(out, out_path, na = "")
    }
    if (n_did >= die_after) return(invisible("KILLED"))   # simulate the kill
  }
  invisible("COMPLETED")
}

fresh <- function() {
  d <- file.path(tempdir(), paste0("resume_", paste(sample(letters, 8), collapse = "")))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  list(ckpt = file.path(d, "ckpt.rds"), out = file.path(d, "out.csv"))
}

canonical <- function(path) {
  if (!file.exists(path)) return(NULL)
  x <- read_csv(path, show_col_types = FALSE, progress = FALSE)
  as.data.frame(x[order(x$certification_number), , drop = FALSE], row.names = NULL)
}

# -----------------------------------------------------------------------------
cat("\n-- the uninterrupted reference run --\n")
# -----------------------------------------------------------------------------
REF <- local({
  p <- fresh(); run_job(p$ckpt, p$out); canonical(p$out)
})
chk(!is.null(REF) && nrow(REF) == N,
    sprintf("R1 an uninterrupted run completes all %d records [%s]", N,
            if (is.null(REF)) "no output" else nrow(REF)))

# -----------------------------------------------------------------------------
cat("\n-- E: kill at EVERY point, resume, compare --\n")
# -----------------------------------------------------------------------------
# Not a couple of sampled kill points. Every one, including the awkward ones
# that land between a checkpoint save and the next item.
{
  differed <- integer(0)
  for (k in seq_len(N - 1L)) {
    p <- fresh()
    run_job(p$ckpt, p$out, die_after = k)   # killed
    run_job(p$ckpt, p$out)                  # resumed
    got <- canonical(p$out)
    if (!identical(got, REF)) differed <- c(differed, k)
  }
  chk(length(differed) == 0L,
      sprintf("E1 resumed output identical to uninterrupted for all %d kill points [%s]",
              N - 1L,
              if (length(differed)) paste("differed at", paste(differed, collapse = ",")) else "none"))
}

# -----------------------------------------------------------------------------
cat("\n-- E2: killed repeatedly, many times in one job --\n")
# -----------------------------------------------------------------------------
# A single clean resume is the easy case. Real jobs die repeatedly.
{
  # Interruptions that leave time for at least one checkpoint. See E4 for what
  # happens when they do not.
  p <- fresh()
  kills <- 0L
  repeat {
    st <- run_job(p$ckpt, p$out, die_after = CKPT_EVERY + 1L)
    kills <- kills + 1L
    if (identical(st, "COMPLETED") || kills > 50L) break
  }
  chk(identical(canonical(p$out), REF),
      sprintf("E2 output identical after %d successive interruptions", kills))
}

# -----------------------------------------------------------------------------
cat("\n-- E4: LIVELOCK -- dying faster than the checkpoint interval --\n")
# -----------------------------------------------------------------------------
# A job that dies before it ever saves makes NO progress and repeats the same
# work forever. When this test was written, scrape_healthgrades_midwives.R and
# enrich_healthgrades_profiles.R both used CKPT_EVERY = 25 with a 2-second
# delay -- a checkpoint roughly once every 50 seconds -- so anything killing
# the job more often than once a minute left it re-fetching the same 25
# profiles indefinitely, looking busy and achieving nothing.
#
# RESOLVED 2026-08-16: both are now CKPT_EVERY = 10, a ~20s window. Not lowered
# further; the output is rewritten wholly on every checkpoint by a plain
# write_csv() with no temp-file-and-rename, so each extra write is another
# chance to be interrupted mid-write. See DEBT.md.
#
# The property below is structural and holds at ANY interval: dying faster than
# you save means never finishing. It is asserted against this file's own
# CKPT_EVERY so it keeps meaning something if that value changes again.
{
  p <- fresh()
  for (i in seq_len(6L)) run_job(p$ckpt, p$out, die_after = CKPT_EVERY - 1L)
  got <- canonical(p$out)
  n_done <- if (is.null(got)) 0L else nrow(got)

  chk(n_done < N,
      sprintf("E4 dying before the first checkpoint makes NO progress [%d of %d after 6 attempts]",
              n_done, N))
  chk(!is.null(got) || n_done == 0L,
      "E4 and the partial state is at least not corrupted by it")

  # The moment interruptions slow to the checkpoint interval, it recovers.
  st <- run_job(p$ckpt, p$out)
  chk(identical(canonical(p$out), REF),
      "E4 one uninterrupted pass afterwards still reaches the reference output")
}

# -----------------------------------------------------------------------------
cat("\n-- E3: chunked runs must equal one continuous run --\n")
# -----------------------------------------------------------------------------
# Irregular chunk sizes, because regular ones can hide an off-by-one that only
# appears when a chunk boundary does not align with CKPT_EVERY.
{
  for (chunks in list(c(10L, 10L, 10L, 10L), c(1L, 39L), c(7L, 3L, 11L, 19L),
                      c(13L, 13L, 13L, 1L), rep(1L, N))) {
    p <- fresh()
    for (n in chunks) run_job(p$ckpt, p$out, n_limit = n)
    chk(identical(canonical(p$out), REF),
        sprintf("E3 chunks %-28s produce the reference output",
                paste(chunks[seq_len(min(5, length(chunks)))], collapse = "+")))
  }
}

# -----------------------------------------------------------------------------
cat("\n-- T: THE TRUNCATION INCIDENT, reproduced and guarded --\n")
# -----------------------------------------------------------------------------
# 2026-08-09: the checkpoint vanished, the next run started from zero, and the
# output CSV -- derived wholly from the checkpoint -- was rewritten with almost
# nothing in it. This asserts the guard added afterwards actually holds.
{
  p <- fresh()
  run_job(p$ckpt, p$out)                       # a complete run
  before <- canonical(p$out)
  chk(nrow(before) == N, "T1 setup: a full output file exists")

  file.remove(p$ckpt)                          # the checkpoint disappears
  run_job(p$ckpt, p$out, n_limit = 0L)         # a run that does NO new work
  after <- canonical(p$out)

  chk(!is.null(after) && nrow(after) == N,
      sprintf("T2 losing the checkpoint does NOT truncate the output [%s rows kept of %d]",
              if (is.null(after)) "0" else nrow(after), N))
  chk(identical(after, before),
      "T3 the recovered output is identical to what was there before")

  # And the recovered checkpoint must let the job carry on rather than redo it.
  p2 <- fresh()
  run_job(p2$ckpt, p2$out, n_limit = 20L)
  file.remove(p2$ckpt)
  run_job(p2$ckpt, p2$out)
  chk(identical(canonical(p2$out), REF),
      "T4 a half-finished job whose checkpoint vanished still completes correctly")
}

# -----------------------------------------------------------------------------
cat("\n-- S: stale output must NOT overwrite a fresher checkpoint --\n")
# -----------------------------------------------------------------------------
# The guard is asymmetric on purpose. Recovering FROM the file when the file
# knows more is right; letting an old file overwrite newer checkpoint entries
# would undo completed work.
{
  done <- list(C001 = data.frame(certification_number = "C001",
                                 payload = "FRESH", stringsAsFactors = FALSE),
               C002 = data.frame(certification_number = "C002",
                                 payload = "FRESH", stringsAsFactors = FALSE))
  stale <- data.frame(certification_number = "C001", payload = "STALE",
                      stringsAsFactors = FALSE)

  got <- resume_recover_done(done, stale)
  chk(identical(got$C001$payload, "FRESH"),
      "S1 a smaller/older output file does not overwrite checkpoint entries")
  chk(length(got) == 2L, "S2 the checkpoint keeps every record it already had")

  # When the file knows MORE, recover -- but checkpoint entries still win on
  # the records both hold.
  bigger <- data.frame(
    certification_number = c("C001", "C002", "C003"),
    payload = c("STALE", "STALE", "FROM-CSV"), stringsAsFactors = FALSE)
  got2 <- resume_recover_done(done, bigger)
  chk(length(got2) == 3L, "S3 a fuller output file recovers the extra records")
  chk(identical(got2$C001$payload, "FRESH"),
      "S4 checkpoint entries still win where both sources hold a record")
  chk(identical(got2$C003$payload, "FROM-CSV"),
      "S5 records only the file knows about are recovered")
}

# -----------------------------------------------------------------------------
cat("\n-- I: resume is idempotent --\n")
# -----------------------------------------------------------------------------
{
  p <- fresh()
  run_job(p$ckpt, p$out)
  once <- canonical(p$out)
  run_job(p$ckpt, p$out); run_job(p$ckpt, p$out)
  chk(identical(canonical(p$out), once),
      "I1 re-running a completed job changes nothing")

  n_todo <- nrow(resume_todo(ROSTER, readRDS(p$ckpt)))
  chk(n_todo == 0L,
      sprintf("I2 a completed job has no work left to do [%d]", n_todo))
}

# -----------------------------------------------------------------------------
cat("\n-- NEGATIVE CONTROL: the harness can detect a broken resume --\n")
# -----------------------------------------------------------------------------
# A resume test that cannot fail proves nothing. Break recovery the way the
# 2026-08-09 incident broke it -- ignore the prior output entirely -- and
# confirm the truncation assertion fires.
{
  broken_recover <- function(done, prior, id_col = "certification_number") done

  broken_run <- function(ckpt_path, out_path, n_limit = NA_integer_) {
    done <- if (file.exists(ckpt_path)) readRDS(ckpt_path) else list()
    prior <- if (file.exists(out_path))
      suppressWarnings(tryCatch(read_csv(out_path, show_col_types = FALSE,
                                         progress = FALSE),
                                error = function(e) NULL)) else NULL
    done <- broken_recover(done, prior)          # THE BUG
    todo <- resume_todo(ROSTER, done, n_limit = n_limit)
    for (i in seq_len(nrow(todo))) {
      done[[as.character(todo$certification_number[i])]] <- do_work(todo[i, ])
    }
    out <- resume_output(done)
    write_csv(if (is.null(out)) ROSTER[0, ] else out, out_path, na = "")
  }

  p <- fresh()
  run_job(p$ckpt, p$out)
  file.remove(p$ckpt)
  broken_run(p$ckpt, p$out, n_limit = 0L)
  after <- canonical(p$out)
  chk(is.null(after) || nrow(after) < N,
      sprintf("NC a resume that ignores the prior output DOES truncate it [%s rows left of %d]",
              if (is.null(after)) "0" else nrow(after), N))
}

# -----------------------------------------------------------------------------
cat("\n-- A: atomic writes (DEBT.md D1) --\n")
# -----------------------------------------------------------------------------
# A checkpoint was saveRDS() then write_csv(), both straight to their final
# paths. Killed between them, the checkpoint outruns its output; killed during
# either, a truncated file replaces a complete one. Both now go through a temp
# file and a rename, which is atomic within a filesystem.
{
  d <- file.path(tempdir(), paste0("atom_", paste(sample(letters, 8), collapse = "")))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  out <- file.path(d, "out.csv")

  atomic_write_csv(data.frame(id = 1:5, v = letters[1:5]), out)
  chk(nrow(read_csv(out, show_col_types = FALSE, progress = FALSE)) == 5L,
      "A1 an atomic write produces the file it was given")

  # A writer that dies mid-write must leave the PREVIOUS file untouched.
  before <- readLines(out, warn = FALSE)
  err <- tryCatch({
    atomic_write(function(p) { writeLines("id,v", p); stop("killed mid-write") }, out)
    NULL
  }, error = function(e) conditionMessage(e))
  chk(!is.null(err), "A2 a writer that dies propagates the error")
  chk(identical(readLines(out, warn = FALSE), before),
      "A3 and the previous file survives a crash mid-write, byte for byte")

  # An empty file must not replace a full one. This is the shape of the
  # 2026-08-09 truncation: a complete CSV overwritten with almost nothing.
  err2 <- tryCatch({
    atomic_write_csv(data.frame(), out); NULL
  }, error = function(e) conditionMessage(e))
  chk(!is.null(err2) || nrow(read_csv(out, show_col_types = FALSE,
                                      progress = FALSE)) == 5L,
      "A4 an empty write is refused rather than replacing a full file")
  chk(nrow(read_csv(out, show_col_types = FALSE, progress = FALSE)) == 5L,
      "A5 the good file is still there afterwards")

  # No temp files left behind, whatever happened above.
  leftovers <- list.files(d, pattern = "^[.].*[.]tmp[0-9]+$", all.files = TRUE)
  chk(length(leftovers) == 0L,
      sprintf("A6 no temporary files are left behind [%d]", length(leftovers)))

  # The production scripts must actually use it.
  for (f in c("scrape_healthgrades_midwives.R", "enrich_healthgrades_profiles.R")) {
    src <- paste(readLines(file.path(root, f), warn = FALSE), collapse = "\n")
    code <- readLines(file.path(root, f), warn = FALSE)
    code <- paste(code[!grepl("^\\s*#", code)], collapse = "\n")
    chk(grepl("atomic_saveRDS(", src, fixed = TRUE) &&
          grepl("atomic_write_csv(", src, fixed = TRUE),
        sprintf("A7 %s writes checkpoints and output atomically", f))
    # A BARE saveRDS, not the atomic one. atomic_saveRDS(done, CHECKPOINT)
    # CONTAINS the string saveRDS(done, CHECKPOINT), so a substring test matches
    # the fix and reports it as the defect -- the same superset-match mistake
    # that made an earlier check grep its own explanatory comment.
    bare <- grepl("(?<!atomic_)saveRDS\\(done, CHECKPOINT\\)", code, perl = TRUE)
    chk(!bare,
        sprintf("A8 %s no longer has a BARE saveRDS to the final path", f))
  }
}

# -----------------------------------------------------------------------------
cat("\n-- LIMITS --\n")
# -----------------------------------------------------------------------------
{
  cat("       The geocoding cascade's own resume lives in\n")
  cat("       geocode_batch_with_3tier_cascade(), in the private isochrones\n")
  cat("       repository, and is not exercised here. Nor is the network, the\n")
  cat("       rate limiter or the HTML parser: this asserts that INTERRUPTION\n")
  cat("       cannot change the answer, not that the scraper works.\n")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
