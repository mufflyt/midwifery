#!/usr/bin/env Rscript
# =============================================================================
# Mutation suite for tools/verify_manuscript_evidence.R (Task 3 adversarial
# verification). Each case corrupts a fixture copy and proves the verifier
# exits nonzero. Run: Rscript tests/test_manuscript_evidence_detect.R
# =============================================================================
root <- normalizePath(if (dir.exists("tests")) "." else "..")
verifier <- file.path(root, "tools", "verify_manuscript_evidence.R")
qmd_src <- file.path(root, "manuscript", "federal_database_accuracy.qmd")
led_src <- file.path(root, "review", "manuscript_evidence_ledger.csv")

mev_run_gate <- function(qmd, ledger) {
  status <- system2("Rscript", verifier, stdout = FALSE, stderr = FALSE,
                    env = c(sprintf("MWE_QMD=%s", qmd),
                            sprintf("MWE_LEDGER=%s", ledger)))
  identical(status, 0L)
}

base_ok <- mev_run_gate(qmd_src, led_src)
if (!base_ok) stop("baseline verifier must pass before mutation tests", call. = FALSE)
cat("  ok   baseline verifier passes\n")

mev_mutate_case <- function(id, mutate) {
  d <- tempfile(paste0(id, "-")); dir.create(d)
  q <- file.path(d, "ms.qmd"); l <- file.path(d, "ledger.csv")
  file.copy(qmd_src, q); file.copy(led_src, l)
  mutate(q, l)
  if (mev_run_gate(q, l)) stop(id, " was not detected", call. = FALSE)
  cat("  ok  ", id, " detected\n")
}

# V01 -- point a ledger claim at a nonexistent artifact (C01 must FAIL) -----
mev_mutate_case("V01", function(q, l) {
  x <- readLines(l, warn = FALSE)
  x <- sub("artifacts/state_source_audit_coverage.csv",
           "artifacts/does_not_exist.csv", x, fixed = TRUE)
  writeLines(x, l)
})

# V02 -- strip the Wilson promise (C07 must FAIL) ---------------------------
mev_mutate_case("V02", function(q, l) {
  x <- readLines(q, warn = FALSE)
  x <- gsub("Wilson", "score", x, fixed = TRUE)
  writeLines(x, q)
})

# V03 -- inject a git conflict marker (C09 must FAIL) ------------------------
mev_mutate_case("V03", function(q, l) {
  x <- readLines(q, warn = FALSE)
  writeLines(c(x[1:50], "<<<<<<< HEAD", x[51:length(x)]), q)
})

# V04 -- delete the Discussion heading (C10 must FAIL) ----------------------
mev_mutate_case("V04", function(q, l) {
  x <- readLines(q, warn = FALSE)
  writeLines(x[!grepl("^## Discussion", x)], q)
})

# V05 -- blank a unit column entry (C02 must FAIL) ---------------------------
mev_mutate_case("V05", function(q, l) {
  x <- readLines(l, warn = FALSE)
  x <- sub("provider_year", "", x, fixed = TRUE)
  writeLines(x, l)
})

# V06 -- break a fig() path (C06 must FAIL) ----------------------------------
mev_mutate_case("V06", function(q, l) {
  x <- readLines(q, warn = FALSE)
  x <- sub("fig(\"state_source_coverage_by_year\")",
           "fig(\"nonexistent_figure\")", x, fixed = TRUE)
  writeLines(x, q)
})

cat("PASS: all 6 deliberate faults were rejected\n")
