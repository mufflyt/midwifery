#!/usr/bin/env Rscript
# =============================================================================
# Does the identity corpus detect a matcher that collapses or invents people?
# =============================================================================
# The corpus asserts a law. This asserts the corpus can fail, which is the only
# thing that makes the law worth anything -- and the coverage registry refuses a
# law with no planted defect.
#
# The two mutations are the two ways identity resolution goes wrong, and they
# fail in opposite directions:
#
#   COLLAPSE   evidence that should separate two people stops separating them,
#              so two certificants become one. This is how ANDERSON matched
#              SANDERSON on a live roster.
#   INVENT     evidence that cannot separate two people is treated as though it
#              does, so an ambiguous pair is forced through to a winner. This is
#              the failure SCI2 polices statically -- picking from several.
#
# A third mutation removes the credential gate entirely, which is the specific
# guard that keeps a namesake physician out of a midwife's record.
# =============================================================================

EVIDENCE_SOURCE <- "tests/test_identity_corpus_detect.R"

# EVIDENCE CUSTODY. Stamps this run with what it is evidence FOR -- the file's
# own content hash, the registry's, and the commit -- so tests/ci_law_coverage.R
# can prove a replayed log belongs to the evaluation it is being used for
# instead of trusting its filename. The helper is sourced, never re-declared:
# two copies of a custody check are two things that can disagree.
local({
  r <- file.path(getwd(), "tests", "ci_report.R")
  if (file.exists(r)) {
    e <- new.env(); sys.source(r, envir = e)
    e$ci_law_evidence_header(EVIDENCE_SOURCE)
  }
})

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)

GATE   <- file.path(root, "tests", "test_identity_collision_corpus.R")
CORPUS <- file.path(root, "tests", "fixtures", "identity_collision_corpus.tsv")
MID    <- file.path(root, "R", "lib", "ab_middle_name_common.R")
CRED   <- file.path(root, "credential_compatibility.R")
# ab_middle_name_common.R sources the canonical sha256_of() at load time, so the
# scaffold needs it too. Copied rather than stubbed: a stub would be a second
# definition of a canonical helper, which is what H4 exists to prevent.
PROV   <- file.path(root, "R", "lib", "provenance.R")
stopifnot(file.exists(GATE), file.exists(CORPUS), file.exists(MID), file.exists(CRED),
          file.exists(PROV))

caught <- 0L; planted <- 0L; fails <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- c(fails, m); cat(sprintf("  FAIL %s\n", m)) } }

id_scaffold <- function(dir) {
  for (d in c("tests/fixtures", "R/lib")) dir.create(file.path(dir, d), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE,   file.path(dir, "tests", "test_identity_collision_corpus.R"))
  file.copy(CORPUS, file.path(dir, "tests", "fixtures", "identity_collision_corpus.tsv"))
  file.copy(MID,    file.path(dir, "R", "lib", "ab_middle_name_common.R"))
  file.copy(CRED,   file.path(dir, "credential_compatibility.R"))
  file.copy(PROV,   file.path(dir, "R", "lib", "provenance.R"))
  dir.create(file.path(dir, ".git"), showWarnings = FALSE)
}

id_run <- function(edits = list()) {
  dir <- file.path(tempdir(), paste0("idc_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  id_scaffold(dir)
  for (nm in names(edits)) writeLines(edits[[nm]], file.path(dir, nm))
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript tests/test_identity_collision_corpus.R 2>&1",
                            shQuote(dir)))), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

kills <- function(label, mutation_id, edits) {
  planted <<- planted + 1L
  r <- id_run(edits)
  if (r$failed) caught <<- caught + 1L
  cat(sprintf("[MUTATION] L7 %s %s\n", mutation_id, if (r$failed) "DETECTED" else "SURVIVED"))
  chk(r$failed, sprintf("L7  %s", label))
  if (!r$failed) cat("       the corpus passed; the mutation survived\n")
}

# A middle-name classifier with one behaviour replaced. Everything else in the
# file is left alone, so the mutation is the defect and not the rewrite.
mutant_middle <- function(body) c(
  "has_middle <- function(x) !is.na(x) & nzchar(trimws(x))",
  "middle_state <- function(roster_mid, cand_mid) {",
  "  r <- has_middle(roster_mid); c <- has_middle(cand_mid)",
  "  ri <- substr(toupper(trimws(roster_mid)), 1, 1)",
  "  ci <- substr(toupper(trimws(cand_mid)), 1, 1)",
  body,
  "}")

cat("\n-- the unmutated corpus passes --\n")
r <- id_run(); chk(!r$failed, "an unperturbed scaffold produces no failures")
if (r$failed) cat(r$text, "\n")

cat("\n-- planted defects --\n")

# COLLAPSE: a real middle-name conflict stops separating two people.
kills("a middle-name conflict is treated as agreement (two people collapse into one)",
      "collapse-conflict-into-agreement",
  list("R/lib/ab_middle_name_common.R" = mutant_middle(
    '  dplyr::case_when(!r & !c ~ "both_missing", r & !c ~ "missing_npi_side",
       !r & c ~ "missing_roster_side", TRUE ~ "initial_agreement")')))

# INVENT: pairs that nothing separates are declared separated, which is what
# forcing an ambiguous record through a resolver looks like at this layer.
kills("indistinguishable pairs are reported as conflicting (a distinction is invented)",
      "invent-distinction-from-nothing",
  list("R/lib/ab_middle_name_common.R" = mutant_middle(
    '  dplyr::case_when(ri == ci & r & c ~ "initial_agreement", TRUE ~ "conflict")')))

# The credential gate stops rejecting a namesake physician.
kills("the credential gate admits a physician namesake",
      "credential-gate-removed",
  list("credential_compatibility.R" = c(
    "normalize_credential_class <- function(credential) 'UNKNOWN'",
    "are_credentials_compatible_midwifery <- function(a, b) TRUE",
    "classify_credentials <- function(credential) 'UNKNOWN'")))

# And the corpus itself going missing must fail, not skip.
kills("the frozen corpus is deleted", "corpus-absent",
  list("tests/fixtures/identity_collision_corpus.tsv" = character(0)))

cat(sprintf("\n%d/%d identity mutations detected\n", caught, planted))
if (length(fails)) {
  cat(sprintf("\nFAILED (%d)\n", length(fails)))
  for (f in fails) cat(sprintf("  - %s\n", f)); quit(status = 1)
}
cat("PASS (0 failures)\n")
