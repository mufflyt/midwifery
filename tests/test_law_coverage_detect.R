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

cat("\n-- a derived-ok skip is legal, counted, and named --\n")
# D9. `private-ok` and `derived-ok` both permit a skip, and only one of them is
# a statement about privacy. L5 was registered private-ok to turn a red nightly
# green, which made the registry assert that a 31 MB dissolved isochrone surface
# is person-level data. The states are separate so the count of laws NO RUNNER
# ENFORCES stays visible rather than being absorbed into a category that sounds
# unavoidable.
REG_DERIVED <- c(
  "law\ttitle\tgate\tmutation\tprivacy",
  "L1\tfirst law\ttests/fake_gate.R\ttests/fake_mutation.R\tpublic",
  "L2\tsecond law\ttests/fake_gate.R\ttests/fake_mutation.R\tderived-ok")
GATE_DERIVED_SKIP <- c(GATE_OK[1], 'cat("[LAW] L2 SKIPPED input absent\\n")')

r <- cov_run(registry = REG_DERIVED, gate = GATE_DERIVED_SKIP)
chk(!r$failed, "a derived-ok law may skip when its derived input is absent")
chk(grepl("Expected derived skips:      1", r$text),
    "...and the skip is counted under its own heading, not the private one")
chk(grepl("Expected private skips:      0", r$text),
    "...leaving the private count untouched")
chk(grepl("not enforced on any runner", r$text),
    "...and says plainly that no runner is enforcing it")
chk(grepl("Unexpected skips:            0", r$text),
    "...while unexpected skips stay at zero")

# THE LABEL MUST NOT LAUNDER A PUBLIC LAW. derived-ok is a permission attached
# to a named law, not a way for any skip to become acceptable.
r <- cov_run(registry = REG_DERIVED,
             gate = c('cat("[LAW] L1 SKIPPED input absent\\n")',
                      'cat("[LAW] L2 SKIPPED input absent\\n")'))
chk(r$failed && grepl("unexpected skip", r$text),
    "a PUBLIC law skipping is still unexpected even beside a derived-ok one")

cat("\n-- a skipped law is never counted as exercised --\n")
# The summary used to add the skips back into the exercised count, so a report
# could read "10/10 laws exercised" when nine had run. The two lines disagreed
# with each other as well: the header counted BOTH skip kinds as exercised and
# the verdict line counted only private ones, which went unnoticed because no
# private-ok law happened to be skipping. Exercised means ran.
r <- cov_run(registry = REG_DERIVED, gate = GATE_DERIVED_SKIP)
chk(grepl("Laws exercised:              1/2", r$text),
    "a derived-ok skip leaves the exercised count at 1 of 2, not 2 of 2")
chk(grepl("1/2 laws exercised", r$text),
    "...and the verdict line agrees with the header")

REG_PRIVATE <- c(
  "law\ttitle\tgate\tmutation\tprivacy",
  "L1\tfirst law\ttests/fake_gate.R\ttests/fake_mutation.R\tpublic",
  "L2\tsecond law\ttests/fake_gate.R\ttests/fake_mutation.R\tprivate-ok")
r <- cov_run(registry = REG_PRIVATE,
             gate = c(GATE_OK[1], 'cat("[LAW] L2 SKIPPED input absent\\n")'))
chk(grepl("Laws exercised:              1/2", r$text),
    "a private-ok skip is not counted as exercised either")
chk(grepl("1/2 laws exercised", r$text),
    "...and again the two lines agree")

# NOTHING IS LOST BY THE CORRECTION: the skip is still on its own line, so
# exercised plus skipped still accounts for every declared law.
chk(grepl("Expected private skips:      1", r$text),
    "...with the skip still reported, so the total still adds up")

cat("\n-- a gate that dies is reported as dead, not as vacuous --\n")
# D8. Every nightly from 2026-08-26 scored five laws as "no subjects" when all
# five had crashed on their first line with "no package called X". The exit
# status was already in hand and was being discarded, so a gate that DIED and a
# gate that ran and said nothing arrived identically: text with no markers.
r <- cov_run(gate = c('stop("no package called sf")'))
chk(r$failed && grepl("CRASHED", r$text),
    "a gate that dies before emitting anything is reported as CRASHED")
chk(grepl("no package called sf", r$text),
    "...and the reason it died is surfaced, not swallowed")

# THE OTHER HALF OF THE RULE, and the reason a bare non-zero exit is not enough
# to call it a crash. A gate that evaluates its law, finds a violation and exits
# non-zero is a WORKING gate reporting a real result. Coverage asks whether the
# law was checked, not whether it passed, so this must not be reported as a
# crash -- doing so would turn every genuine law failure into a false diagnosis.
r <- cov_run(gate = c(GATE_OK,
  'cat("FAILED (1)\\n"); quit(status = 1)'))
chk(!grepl("CRASHED", r$text),
    "a gate that exits non-zero having emitted evidence is NOT called a crash")

cat("\n-- evidence custody: a replayed log must be evidence for THIS evaluation --\n")
# Replay exists because re-running every gate took coverage past its own budget.
# It introduced a new way to be wrong: a green log left in the directory by an
# earlier commit carries exactly the markers coverage is looking for. These
# defects are all stale-green -- the log is well-formed and says everything
# passed, and none of them may be believed.
cov_run_ev <- function(evidence, registry = REGISTRY_OK,
                       gate = GATE_OK, mut = MUT_OK) {
  dir <- file.path(tempdir(), paste0("cov_ev_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  cov_scaffold(dir, registry, gate, mut)
  ev <- file.path(dir, "evidence"); dir.create(ev, showWarnings = FALSE)
  for (nm in names(evidence)) writeLines(evidence[[nm]], file.path(ev, nm))
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && LAW_EVIDENCE_DIR=evidence Rscript tests/ci_law_coverage.R 2>&1",
                            shQuote(dir)))), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

# A correctly bound log, built the way a gate builds one.
bound <- function(dir_files, src, run = "r1", src_md5 = NULL, reg_md5 = NULL) {
  c(sprintf("[EVIDENCE] source=%s src_md5=%s registry_md5=%s commit=unknown run=%s",
            src,
            if (is.null(src_md5)) dir_files$src else src_md5,
            if (is.null(reg_md5)) dir_files$reg else reg_md5, run),
    dir_files$body)
}

# Hashes are computed inside the scratch repo, so the harness never assumes what
# the gate file contains.
md5_of <- function(lines) {
  f <- tempfile(); writeLines(lines, f); on.exit(unlink(f))
  unname(tools::md5sum(f))
}
GATE_BODY <- c("[LAW] L1 EXERCISED", "[CONTROL] L1 negative n=10",
               "[CONTROL] L1 positive n=1", "[LAW] L2 EXERCISED",
               "[CONTROL] L2 negative n=20", "[CONTROL] L2 positive n=1")
MUT_BODY  <- c("[MUTATION] L1 planted-one DETECTED",
               "[MUTATION] L2 planted-two DETECTED")
H <- list(gate = list(src = md5_of(GATE_OK), reg = md5_of(REGISTRY_OK), body = GATE_BODY),
          mut  = list(src = md5_of(MUT_OK),  reg = md5_of(REGISTRY_OK), body = MUT_BODY))

EV_OK <- list("fake_gate.R.log"     = bound(H$gate, "tests/fake_gate.R"),
              "fake_mutation.R.log" = bound(H$mut,  "tests/fake_mutation.R"))

r <- cov_run_ev(EV_OK)
chk(!r$failed, "correctly bound evidence replays and passes")
if (r$failed) cat(r$text, "\n")

r <- cov_run_ev(list("fake_gate.R.log" = GATE_BODY,
                     "fake_mutation.R.log" = bound(H$mut, "tests/fake_mutation.R")))
chk(r$failed && grepl("no \\[EVIDENCE\\] stamp", r$text),
    "a fabricated log carrying the right markers but no stamp")

r <- cov_run_ev(modifyList(EV_OK, list(
  "fake_gate.R.log" = bound(H$gate, "tests/fake_gate.R",
                            src_md5 = "0000000000000000deadbeef00000000"))))
chk(r$failed && grepl("has changed since it ran", r$text),
    "a green log from a commit where the GATE differed")

r <- cov_run_ev(modifyList(EV_OK, list(
  "fake_gate.R.log" = bound(H$gate, "tests/fake_gate.R",
                            reg_md5 = "0000000000000000deadbeef00000000"))))
chk(r$failed && grepl("registry has changed", r$text),
    "a log generated before the registry changed")

r <- cov_run_ev(modifyList(EV_OK, list(
  "fake_gate.R.log" = bound(H$gate, "tests/fake_mutation.R"))))
chk(r$failed && grepl("was produced by", r$text),
    "a log whose stamp names a different source than its filename")

r <- cov_run_ev(list(
  "fake_gate.R.log"     = bound(H$gate, "tests/fake_gate.R", run = "r1"),
  "fake_mutation.R.log" = bound(H$mut,  "tests/fake_mutation.R", run = "r2")))
chk(r$failed && grepl("different runs", r$text),
    "evidence stitched together from two different runs")

r <- cov_run_ev(modifyList(EV_OK, list(
  "fake_gate.R.log" = c(bound(H$gate, "tests/fake_gate.R"),
                        bound(H$gate, "tests/fake_gate.R")))))
chk(r$failed && grepl("more than one run", r$text),
    "duplicated evidence concatenated into one file")

# ABSENCE IS NOT CORRUPTION. A missing log means the nightly did not tee that
# step, and re-running the gate is the right answer. Only MISMATCH fails closed.
r <- cov_run_ev(list("fake_gate.R.log" = bound(H$gate, "tests/fake_gate.R")))
chk(!r$failed, "a missing log still falls back to executing the gate")
if (r$failed) cat(r$text, "\n")

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
