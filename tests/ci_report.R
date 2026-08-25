# =============================================================================
# The shared reporter for the CI check scripts
# =============================================================================
# ci_leak_guard.R and ci_artifact_contracts.R both need the same four lines of
# output plumbing. Defining them twice is precisely the defect H4 exists to
# catch -- and it did catch it, which is why this file exists. Anything that
# grows a third caller belongs here too.
#
# Names are prefixed because `fail` is already taken at top level by
# verify_artifact_freshness.R, and a second definition of a common verb is how
# two files quietly stop meaning the same thing.
# =============================================================================

ci_failures <- character(0)

ci_fail    <- function(...) ci_failures <<- c(ci_failures, sprintf(...))
ci_ok      <- function(...) cat(sprintf("  ok   %s\n", sprintf(...)))
ci_skip    <- function(...) cat(sprintf("  --   %s\n", sprintf(...)))
ci_section <- function(s)   cat(sprintf("\n-- %s --\n", s))

# Exits non-zero when anything failed, so the step fails the job.
ci_finish <- function() {
  cat("\n")
  if (length(ci_failures)) {
    for (f in ci_failures) cat(sprintf("FAIL %s\n", f))
    cat(sprintf("\nFAILED (%d)\n", length(ci_failures)))
    quit(status = 1)
  }
  cat("PASS (0 failures)\n")
}

# Tracked paths matching a git pathspec. Quoted so git expands the glob
# recursively rather than the shell expanding it against the working directory.
ci_tracked <- function(pattern) {
  out <- suppressWarnings(system2("git", c("ls-files", shQuote(pattern)),
                                  stdout = TRUE, stderr = FALSE))
  if (length(out) == 0) character(0) else out
}

# Read a committed CSV as all-character, returning NULL rather than raising.
# ci_semantic_contracts.R and ci_science_contracts.R both need it; defining it
# twice is precisely what H4 exists to catch, and it did.
ci_read_head <- function(path, n = -1L, root = ".") {
  tryCatch(utils::read.csv(file.path(root, path), stringsAsFactors = FALSE,
                           nrows = n, check.names = FALSE,
                           colClasses = "character"),
           error = function(e) NULL)
}

# --- Evidence for the law-coverage registry ---------------------------------
# tests/ci_law_coverage.R parses these. They are printed, not returned, because
# the coverage checker runs each gate as a subprocess and reads its output --
# the same way a reader would, and the same way a runner does.
#
#   [LAW] L3 EXERCISED            the law was evaluated at all
#   [CONTROL] L3 negative n=903   how many subjects it was evaluated ON. Zero is
#                                 a vacuous pass and coverage rejects it.
#   [LAW] L3 SKIPPED reason       evaluated on nothing, deliberately. Legal only
#                                 for a law the registry marks private-ok.
ci_law_exercised <- function(law, n_subjects) {
  cat(sprintf("[LAW] %s EXERCISED\n", law))
  cat(sprintf("[CONTROL] %s negative n=%s\n", law, format(n_subjects)))
}
# A POSITIVE control: proof the law's detector responds to a violation, checked
# on a synthetic bad value before the law is applied to real data. A law with
# only a negative control proves it did not fire; it does not prove it could.
ci_law_positive <- function(law, detected) {
  cat(sprintf("[CONTROL] %s positive n=%d\n", law, as.integer(isTRUE(detected))))
}
ci_law_skipped <- function(law, reason) {
  cat(sprintf("[LAW] %s SKIPPED %s\n", law, reason))
}

# --- EVIDENCE CUSTODY --------------------------------------------------------
# A replayed log must be evidence for the evaluation being performed, not merely
# a correctly named text file. Coverage cannot know that by reading [LAW] lines:
# a green log copied from the previous commit carries exactly the same markers
# as one produced a second ago.
#
# So every gate stamps its own output with what it was evidence FOR. Coverage
# recomputes each field and refuses the log if any disagrees. The binding is
# self-contained -- it travels inside the evidence rather than in a side manifest
# that can be lost, rewritten, or left behind by a failed step.
#
# Content hashes, not timestamps. An mtime says when a file was touched, which
# is the mistake L10 was written to reject; a hash says what it contained.
ci_evidence_source_hash <- function(rel) {
  f <- file.path(getwd(), rel)
  if (!file.exists(f)) return("absent")
  unname(tools::md5sum(f))
}

ci_evidence_commit <- function() {
  out <- suppressWarnings(system2("git", c("rev-parse", "HEAD"),
                                  stdout = TRUE, stderr = FALSE))
  if (length(out) != 1L || !nzchar(out)) "unknown" else out
}

# Printed as the FIRST line a gate emits, so a truncated log cannot look bound.
ci_law_evidence_header <- function(source_rel) {
  cat(sprintf("[EVIDENCE] source=%s src_md5=%s registry_md5=%s commit=%s run=%s\n",
              source_rel,
              ci_evidence_source_hash(source_rel),
              ci_evidence_source_hash("tests/science_law_registry.tsv"),
              ci_evidence_commit(),
              { r <- Sys.getenv("LAW_RUN_ID"); if (nzchar(r)) r else "adhoc" }))
}
