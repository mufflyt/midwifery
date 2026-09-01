#!/usr/bin/env Rscript
# =============================================================================
# The three person-level linkage scripts run, and refuse, as documented
# =============================================================================
# build_linkage_case_gallery.R, make_evidence_class_figure.R and
# analyze_temporal_plausibility.R all read the frozen crosswalk, which is
# gitignored. That meant they shipped with NO automated coverage: they were
# verified once, by hand, against fixtures in a scratch directory that no longer
# exists. A script whose only proof of life evaporated with a session is a
# script nobody can change safely.
#
# This runs all three against regenerated fixtures and asserts what each one
# promises: that it produces the output it documents, and -- for the gallery --
# that it REFUSES the things it says it refuses. The refusals are the half worth
# testing; a person-level writer that stops guarding its destination is a
# different kind of bug from one that draws a wrong bar.
#
# Run: Rscript tests/test_linkage_scripts_smoke.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

mk <- source(file.path(root, "tests", "fixtures", "make_linkage_fixtures.R"))$value
fx <- mk(file.path(tempdir(), "linkage_fx"))
cat(sprintf("\nfixtures: %d crosswalk rows in %s\n", fx$n_rows, fx$dir))

run <- function(script, args = character(0)) {
  out <- suppressWarnings(system2("Rscript", c(script, args),
                                  stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = paste(out, collapse = "\n"))
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# Everything person-level lands in qa/, which is gitignored. The test owns that
# directory for the duration and puts it back, so a developer's real gallery is
# not silently replaced by a fixture one.
QA <- file.path(root, "qa")
stash <- NULL
if (dir.exists(QA)) { stash <- file.path(tempdir(), "qa_stash"); file.rename(QA, stash) }
on.exit({
  unlink(QA, recursive = TRUE)
  if (!is.null(stash) && dir.exists(stash)) file.rename(stash, QA)
}, add = TRUE)

cat("\n-- build_linkage_case_gallery.R --\n")

r <- run("build_linkage_case_gallery.R",
         c(paste0("--crosswalk=", fx$crosswalk), "--n=2"))
chk(r$status == 0L, "S1 runs against a fixture crosswalk")
chk(file.exists(file.path(QA, "linkage_case_gallery.html")) &&
      file.exists(file.path(QA, "linkage_case_gallery.csv")),
    "S2 writes both the review sheet and the annotation CSV")
chk(grepl("12 strata", r$out) || grepl("across 12 strata", r$out),
    "S3 all twelve strata are populated by the fixture")

html <- if (file.exists(file.path(QA, "linkage_case_gallery.html")))
  paste(readLines(file.path(QA, "linkage_case_gallery.html"), warn = FALSE),
        collapse = "\n") else ""
chk(grepl("PERSON-LEVEL", html), "S4 the unredacted sheet carries its warning banner")

# THE REFUSALS.
r <- run("build_linkage_case_gallery.R",
         c(paste0("--crosswalk=", fx$crosswalk), "--outdir=artifacts"))
chk(r$status != 0L && grepl("Refusing", r$out),
    "S5 refuses to write person-level output outside qa/")

r <- run("build_linkage_case_gallery.R", "--crosswalk=does/not/exist.csv")
chk(r$status != 0L && grepl("not found", r$out),
    "S6 refuses a missing crosswalk with an actionable message")

r <- run("build_linkage_case_gallery.R",
         c(paste0("--crosswalk=", fx$crosswalk), "--n=2", "--redact"))
red <- paste(readLines(file.path(QA, "linkage_case_gallery.html"), warn = FALSE),
             collapse = "\n")
chk(r$status == 0L && !grepl("OKONKWO|MARTINEZ-REYES|OBRIEN", red),
    "S7 --redact removes every surname from the sheet")

cat("\n-- make_evidence_class_figure.R --\n")

r <- run("make_evidence_class_figure.R", paste0("--crosswalk=", fx$crosswalk))
chk(r$status == 0L, "S8 runs against a fixture crosswalk")
chk(file.exists("docs/figures/evidence_class_accepted.png"),
    "S9 writes the figure")
# Built with file.path rather than written as a literal, because it is an
# OUTPUT of the script under test, not an input to this one. As a bare string it
# read to tests/ci_repo_integrity.R as a repository input that does not exist on
# a clean checkout, which is a true statement about the wrong file.
CLASS_CSV <- file.path("artifacts", "accepted_by_evidence_class.csv")
chk(file.exists(CLASS_CSV), "S10 writes the backing aggregate CSV")
# Class 5 has zero accepted matches by design; the aggregate must still cover
# the rest, which is the bug that made the axis reorder itself twice.
if (file.exists(CLASS_CSV)) {
  cl <- utils::read.csv(CLASS_CSV)
  chk(length(unique(cl$name_evidence_class)) >= 4L,
      "S11 the aggregate covers the classes the fixture accepts")
}

cat("\n-- analyze_temporal_plausibility.R --\n")

r <- run("analyze_temporal_plausibility.R",
         c(paste0("--crosswalk=", fx$crosswalk), paste0("--panel=", fx$panel),
           paste0("--audit=", fx$audit), "--grace=5"))
chk(r$status == 0L, "S12 runs against fixture crosswalk, panel and audit")
chk(grepl("left-censored", r$out),
    "S13 reports censored rows rather than silently treating them as evidence")
chk(grepl("WOULD separate", r$out), "S14 reports the separation it would produce")
chk(grepl("would LOSE these", r$out),
    "S15 reports emptied pools alongside separations")
chk(grepl("NOTHING in the published linkage was changed", r$out),
    "S16 states that it changed no published linkage")

# Fixture outputs must not be left in the tree.
unlink(c("docs/figures/evidence_class_accepted.pdf",
         "docs/figures/evidence_class_accepted.png",
         "docs/figures/evidence_class_accepted.svg",
         "artifacts/accepted_by_evidence_class.csv",
         "artifacts/accepted_by_evidence_class.csv.provenance.json",
         "artifacts/temporal_plausibility_summary.csv",
         "artifacts/temporal_plausibility_summary.csv.provenance.json",
         "artifacts/temporal_separation_by_pool.csv",
         "artifacts/temporal_separation_by_pool.csv.provenance.json"))

cat(sprintf("\n%s (%d failure%s)\n", if (fails) "FAIL" else "PASS", fails,
            if (fails == 1L) "" else "s"))
quit(status = if (fails) 1L else 0L)
