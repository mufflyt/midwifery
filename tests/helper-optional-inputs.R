# =============================================================================
# "The input is absent" is not "the code is wrong"
# =============================================================================
# Several suites read person-level or large artifacts that are gitignored by
# design. On a developer machine they are present and the assertions are real.
# On a runner they are absent, and four suites responded to that by failing:
#
#   test_amcb_gates.R           chk(FALSE, "current crosswalk present")
#   test_cycle6_field_quality.R "attribute snapshot missing"
#   test_cycle15_ob_capacity.R  stopifnot(file.exists(...)) -- a hard error
#   test_cycle22_idempotence.R  ran scripts whose inputs were not there
#
# Reporting a defect that has not been demonstrated is its own defect. It also
# has a predictable end state: a suite that is red every night is a suite people
# stop reading, and then a REAL failure in it is invisible too.
#
# The opposite mistake is worse, so this helper is built against it. A skip must
# be LOUD and COUNTED. `optional_inputs_summary()` prints what was skipped, and
# the caller is expected to include the count in its final line, so a run that
# quietly asserted nothing cannot look like a run that asserted everything.
#
# Named helper-* so the nightly's glob sources it rather than executing it.
# =============================================================================

.optional_skips <- new.env(parent = emptyenv())
.optional_skips$n <- 0L
.optional_skips$what <- character(0)

#' Are the inputs an assertion needs actually present?
#'
#' @param paths Character vector of files the block needs. Globs are resolved,
#'   so "artifacts/foo_*.csv" works and an empty match counts as absent.
#' @param what Human description of what will not be checked without them.
#' @return TRUE when every path resolves to at least one existing file.
have_inputs <- function(paths, what) {
  resolved <- unlist(lapply(paths, function(p)
    if (grepl("[*?]", p)) Sys.glob(p) else p))
  missing <- if (!length(resolved)) paths else paths[
    vapply(paths, function(p) {
      r <- if (grepl("[*?]", p)) Sys.glob(p) else p
      !length(r) || !any(file.exists(r))
    }, logical(1))]

  if (!length(missing)) return(TRUE)

  .optional_skips$n <- .optional_skips$n + 1L
  .optional_skips$what <- c(.optional_skips$what, what)
  cat(sprintf("  --   SKIP %s [absent: %s]\n", what,
              paste(basename(missing), collapse = ", ")))
  FALSE
}

#' How many assertion groups were skipped for absent inputs
optional_skip_count <- function() .optional_skips$n

#' Print the skip ledger. Call this before the suite's PASS/FAIL line.
optional_inputs_summary <- function() {
  n <- .optional_skips$n
  if (n == 0L) return(invisible(0L))
  cat(sprintf("\n  NOTE %d assertion group(s) skipped for absent inputs:\n", n))
  for (w in .optional_skips$what) cat(sprintf("       - %s\n", w))
  cat("       These run for real only where the inputs exist.\n")
  invisible(n)
}
