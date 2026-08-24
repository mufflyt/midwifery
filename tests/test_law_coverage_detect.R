#!/usr/bin/env Rscript
# =============================================================================
# Can the coverage gate itself fail?
# =============================================================================
# ci_law_coverage.R exists to catch a law that never ran. If IT cannot fail,
# the whole argument collapses one level up: a coverage report that always says
# 6/6 is worth exactly as much as a law that always passes.
#
# So this plants defects in the coverage contract itself -- an unexercised law,
# a law with no planted defect, a defect that survives, a public law that skips,
# a law that passes on zero subjects, and a registry pointing at a file that
# does not exist -- and requires each to be caught.
#
# The gates here are fakes that print controlled markers. That is deliberate:
# this tests the COVERAGE LOGIC, not the science. The science is tested by the
# real gates, and their mutation harness is tested by test_science_laws_detect.R.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
COV <- file.path(root, "tests", "ci_law_coverage.R")
REP <- file.path(root, "tests", "ci_report.R")
stopifnot(file.exists(COV), file.exists(REP))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

# A scratch repository whose coverage is complete.
cov_scaffold <- function(dir, registry, gate_lines, mut_lines) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  file.copy(COV, file.path(dir, "tests", "ci_law_coverage.R"))
  file.copy(REP, file.path(dir, "tests", "ci_report.R"))
  writeLines(registry, file.path(dir, "tests", "science_law_registry.tsv"))
  writeLines(gate_lines, file.path(dir, "tests", "fake_gate.R"))
  writeLines(mut_lines,  file.path(dir, "tests", "fake_mutation.R"))
  dir.create(file.path(dir, ".git"), showWarnings = FALSE)
}

REGISTRY_OK <- c(
  "law\ttitle\tgate\tmutation\tprivacy",
  "L1\tfirst law\ttests/fake_gate.R\ttests/fake_mutation.R\tpublic",
  "L2\tsecond law\ttests/fake_gate.R\ttests/fake_mutation.R\tpublic")
GATE_OK <- c('cat("[LAW] L1 EXERCISED\\n"); cat("[CONTROL] L1 negative n=10\\n"); cat("[CONTROL] L1 positive n=1\\n")',
             'cat("[LAW] L2 EXERCISED\\n"); cat("[CONTROL] L2 negative n=20\\n"); cat("[CONTROL] L2 positive n=1\\n")')
MUT_OK  <- c('cat("[MUTATION] L1 planted-one DETECTED\\n")',
             'cat("[MUTATION] L2 planted-two DETECTED\\n")')

cov_run <- function(registry = REGISTRY_OK, gate = GATE_OK, mut = MUT_OK) {
  dir <- file.path(tempdir(), paste0("cov_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  cov_scaffold(dir, registry, gate, mut)
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_law_coverage.R 2>&1", shQuote(dir)))),
    stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

cat("\n-- a complete coverage contract passes --\n")
r <- cov_run()
chk(!r$failed, "two laws, both exercised, both with a killed defect")
if (r$failed) cat(r$text, "\n")
chk(grepl("Unexpected skips:            0", r$text), "and it reports zero unexpected skips")

cat("\n-- and every way of breaking it fails --\n")

r <- cov_run(gate = GATE_OK[1])
chk(r$failed && grepl("were not exercised", r$text), "a registered law that emits nothing")

r <- cov_run(gate = c(GATE_OK[1],
  'cat("[LAW] L2 EXERCISED\\n"); cat("[CONTROL] L2 negative n=0\\n"); cat("[CONTROL] L2 positive n=1\\n")'))
chk(r$failed, "a law that passes on zero subjects")

# A law with a negative control and NO positive control. It has proved it did
# not fire; it has not proved it could. Until the coverage gate required this,
# an inert detector counted as fully covered -- which is the same shape as a
# law that never ran.
r <- cov_run(gate = c(GATE_OK[1],
  'cat("[LAW] L2 EXERCISED\\n"); cat("[CONTROL] L2 negative n=20\\n")'))
chk(r$failed && grepl("no POSITIVE control", r$text),
    "a law with a negative control but no positive control")

r <- cov_run(mut = MUT_OK[1])
chk(r$failed && grepl("no planted defect", r$text), "a law with no planted defect")

r <- cov_run(mut = c(MUT_OK[1], 'cat("[MUTATION] L2 planted-two SURVIVED\\n")'))
chk(r$failed && grepl("survive", r$text), "a planted defect that survives")

r <- cov_run(gate = c(GATE_OK[1], 'cat("[LAW] L2 SKIPPED input absent\\n")'))
chk(r$failed && grepl("Unexpected skips:            1", r$text),
    "a PUBLIC law that skips is an unexpected skip")

r <- cov_run(registry = c(REGISTRY_OK, "L3\tthird law\ttests/nonexistent.R\ttests/fake_mutation.R\tpublic"))
chk(r$failed && grepl("does not exist", r$text), "a registry pointing at a missing gate")

cat("\n-- but a registered private dependency may skip --\n")
r <- cov_run(
  registry = c("law\ttitle\tgate\tmutation\tprivacy",
               "L1\tfirst law\ttests/fake_gate.R\ttests/fake_mutation.R\tpublic",
               "L2\tsecond law\ttests/fake_gate.R\ttests/fake_mutation.R\tprivate-ok"),
  gate = c(GATE_OK[1], 'cat("[LAW] L2 SKIPPED person-level input absent\\n")'))
chk(!r$failed, "a private-ok law may skip when its data is absent")
chk(grepl("Expected private skips:      1", r$text), "and the skip is counted, not hidden")
chk(grepl("Unexpected skips:            0", r$text), "while unexpected skips stay at zero")

cat("\n")
if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
