#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 40 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: T44 in tests/test_cycle5_key_resolution.R -- the repo's own ratchet
# against a bare distinct(key, .keep_all = TRUE) resolving a data conflict by
# row order. Its glob scanned only R/, never the repo root, where most of the
# standalone pipeline scripts actually live. Two real order-dependent
# conflicts were found and fixed at the root level this session (cycle 28's
# NPI deactivation report, cycle 39's two sites in match_open_payments_to_
# facility.R) without this sweep ever having seen either site -- it was
# auditing less than a third of the codebase's actual .keep_all usage.
#
# FIX (applied to tests/test_cycle5_key_resolution.R itself this cycle):
# widened the glob to also scan repo-root .R files (non-recursive -- tests/,
# manuscript/, @archive/ are each a different concern with their own
# conventions). This turned 46 sites in R/ into 155 total, and the offender
# count (after the arrange() exemption) from 11 into 110 -- discovered debt,
# not newly created debt, matching this file's own established "the ratchet
# caught it" precedent from 2026-08-15 (14 -> 11 the other direction).
#
# This cycle's own tests exercise the SWEEP MECHANISM itself (the detection
# heuristic: single-line regex, comment exemption, arrange()-lookback window,
# file-set construction) using small synthetic fixture files, since the
# sweep's logic is the thing under test, not any one production file's
# content.
#
# Run: Rscript tests/test_cycle40_keepall_sweep_scope.R
# =============================================================================

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of T44's detection logic (tests/test_cycle5_key_
# resolution.R, ~lines 95-121), parameterized on a file list so each test can
# supply its own synthetic fixtures.
detect_offenders <- function(files) {
  offenders <- character(0)
  for (f in files) {
    src <- readLines(f, warn = FALSE)
    hits <- grep("distinct\\(.*\\.keep_all = TRUE", src)
    for (i in hits) {
      if (grepl("^\\s*#", src[i])) next
      window <- src[max(1, i - 4):i]
      if (!any(grepl("arrange\\(", window))) {
        offenders <- c(offenders, sprintf("%s:%d", basename(f), i))
      }
    }
  }
  offenders
}

td <- tempfile("t40_"); dir.create(td)
on.exit(unlink(td, recursive = TRUE), add = TRUE)
mk <- function(name, lines) { p <- file.path(td, name); writeLines(lines, p); p }

cat("\n-- BVA --\n")

# T40-1. A single offending file, standing alone, is correctly detected and
# reported with the right file:line label -- the minimum non-empty case.
{
  f <- mk("solo.R", c("x <- df %>%", "  distinct(key, .keep_all = TRUE)"))
  r <- detect_offenders(f)
  chk(identical(r, "solo.R:2"),
      sprintf("T40-1 a single offending site is detected with the correct file:line label (got '%s')",
              paste(r, collapse = ", ")))
}

# T40-2. The arrange()-lookback window's exact boundary: an arrange() exactly
# 4 lines before the distinct() call (the edge of `max(1, i-4):i`) counts as
# "stated" and is NOT flagged; one 5 lines before falls just outside the
# window and IS flagged. This is the literal boundary the sweep's own
# `window <- src[max(1, i - 4):i]` slice draws.
{
  f_in <- mk("in_window.R", c("x <- df %>%", "  arrange(key)", "  # a", "  # b", "  # c",
                              "  distinct(key, .keep_all = TRUE)"))
  f_out <- mk("outside_window.R", c("x <- df %>%", "  arrange(key)", "  # a", "  # b", "  # c", "  # d",
                                    "  distinct(key, .keep_all = TRUE)"))
  chk(length(detect_offenders(f_in)) == 0L,
      "T40-2a an arrange() exactly 4 lines before distinct() is inside the lookback window -- not flagged")
  chk(length(detect_offenders(f_out)) == 1L,
      "T40-2b the identical arrange() one line further back (5 lines) falls outside the window -- flagged")
}

# T40-3. A file with zero .keep_all sites at all contributes nothing to the
# offender list -- no spurious empty-string entries, no error on a file with
# no hits.
{
  f <- mk("clean.R", c("x <- df %>% distinct(key)", "y <- 2"))
  r <- detect_offenders(f)
  chk(length(r) == 0L, "T40-3 a file with no .keep_all sites contributes zero offenders, cleanly")
}

cat("\n-- SEMANTIC --\n")

# T40-4. THE FIX. The widened file list must genuinely include BOTH an R/
# subdirectory file AND a repo-root file -- confirming the fix actually
# broadens coverage rather than merely renaming the same single directory.
{
  root <- "."
  files <- c(
    list.files(file.path(root, "R"), pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
    list.files(root, pattern = "\\.R$", recursive = FALSE, full.names = TRUE))
  chk(any(grepl("^\\./R/", files)) && any(!grepl("^\\./R/", files) & grepl("\\.R$", files)),
      sprintf("T40-4 the widened file list contains both R/-subdirectory and repo-root files (%d total)",
              length(files)))
}

# T40-5. The BASELINE constant in tests/test_cycle5_key_resolution.R must
# match the TRUE current offender count under the widened scan -- a live
# drift check. This cycle's own inventory found 110; by the time this PR
# merges, other .keep_all-fixing cycles (independently authored in parallel,
# merged out of authoring order -- so far 28, 32, 39, and now 41) have
# already landed and correctly REDUCED the true count, currently to 105. A
# mismatch here means either new debt was introduced since the last recount
# (the ratchet should have caught that on its own) or the codebase changed
# in a way this test's own copy of the baseline has not been told about --
# either direction is worth recounting fresh rather than trusting either
# number.
{
  root <- "."
  files <- c(
    list.files(file.path(root, "R"), pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
    list.files(root, pattern = "\\.R$", recursive = FALSE, full.names = TRUE))
  n <- length(detect_offenders(files))
  chk(n == 105L,
      sprintf("T40-5 the widened sweep's true current count matches the recorded baseline (got %d, expected 105)", n))
}

# T40-6. DOCUMENTED LIMITATION, not fixed this cycle: the detection regex
# `grep("distinct\\(.*\\.keep_all = TRUE", src)` matches per LINE (src is a
# vector of lines from readLines()), so a distinct() call whose `.keep_all =
# TRUE` argument sits on a DIFFERENT line than `distinct(` is structurally
# invisible to this sweep -- not a bug introduced this cycle, but a real,
# demonstrable blind spot in the detection heuristic itself, worth knowing
# about rather than assuming the sweep sees every stylistic variant.
{
  f <- mk("multiline.R", c("x <- df %>%", "  distinct(", "    key,",
                           "    .keep_all = TRUE", "  )"))
  r <- detect_offenders(f)
  chk(length(r) == 0L,
      "T40-6 a multi-line distinct(...) call with .keep_all on its own line is invisible to the line-based regex (a known limitation, not this cycle's defect)")
}

# T40-7. No filename collision between the R/ subdirectory and the repo root
# would cause the offender report's `basename(f)` label to conflate two
# genuinely different files under one ambiguous name in the printed debt
# list -- verified against the real repository, not a synthetic fixture.
{
  r_names <- basename(list.files("R", pattern = "\\.R$", recursive = TRUE))
  root_names <- basename(list.files(".", pattern = "\\.R$", recursive = FALSE))
  collisions <- intersect(r_names, root_names)
  chk(length(collisions) == 0L,
      sprintf("T40-7 no filename collides between R/ and the repo root (would make the offender report ambiguous) (found: %s)",
              if (length(collisions)) paste(collisions, collapse = ", ") else "none"))
}

cat("\n-- ADVERSARIAL --\n")

# T40-8. Two real offenders independently found and fixed earlier THIS
# SESSION -- check_npi_deactivation.R (cycle 28) and
# match_open_payments_to_facility.R (cycle 39) -- were bare .keep_all sites
# the (then-unwidened) sweep never saw. By the time this PR merges, both
# fixes have already landed on main (merged ahead of this branch in the
# queue), so the widened sweep's job now is to correctly report them as
# CLEAN, not to still find them as offenders -- confirming the widened file
# list actually reaches both files (the earlier, narrower R/-only glob would
# have silently never scanned either one, fixed or not) and that the fixes
# hold up under the sweep's own detection logic.
{
  root <- "."
  files <- c(
    list.files(file.path(root, "R"), pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
    list.files(root, pattern = "\\.R$", recursive = FALSE, full.names = TRUE))
  offenders <- detect_offenders(files)
  reached_both <- any(grepl("\\./check_npi_deactivation\\.R$", files)) &&
    any(grepl("\\./match_open_payments_to_facility\\.R$", files))
  chk(reached_both &&
        !any(grepl("^check_npi_deactivation\\.R:", offenders)) &&
        !any(grepl("^match_open_payments_to_facility\\.R:", offenders)),
      "T40-8 the widened sweep reaches both cycle 28's and cycle 39's fix targets, and correctly reports both clean now that those fixes have merged")
}

# T40-9. Adversarial malformed input to the sweep itself: a file that does
# not exist (a stale path in the file list, e.g. from a deleted script) must
# not crash the whole sweep with an unhandled error -- readLines() on a
# missing file errors, so this documents that the CURRENT sweep has no
# defensive handling for that case, which matters if this test suite is ever
# run against a partial/sparse checkout.
{
  bogus <- file.path(td, "does_not_exist.R")
  err <- tryCatch({ detect_offenders(bogus); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err),
      sprintf("T40-9 a nonexistent file path in the scan list raises an error (documented, not silently skipped): %s",
              if (is.na(err)) "no error -- silently succeeded" else "confirmed"))
}

# T40-10. A .keep_all site paired with an arrange() call that names a
# DIFFERENT, unrelated variable (not actually establishing a real tie-break
# for THIS distinct() call, just an incidental arrange() somewhere in the
# 4-line lookback) is still exempted by the current heuristic -- the sweep
# checks only for the LITERAL STRING "arrange(" appearing nearby, not that it
# meaningfully precedes and applies to the same pipeline. This is a real,
# demonstrable gap in the heuristic's precision (a false negative is
# possible), not fixed this cycle, but worth pinning as a known limitation
# alongside T40-6.
{
  f <- mk("unrelated_arrange.R", c(
    "other_thing <- some_df %>% arrange(unrelated_col)",
    "x <- df %>%",
    "  distinct(key, .keep_all = TRUE)"))
  r <- detect_offenders(f)
  chk(length(r) == 0L,
      "T40-10 an arrange() on a wholly unrelated pipeline, merely nearby in the file, is enough to exempt a distinct() call from being flagged -- a real precision gap in the heuristic, documented not fixed")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
