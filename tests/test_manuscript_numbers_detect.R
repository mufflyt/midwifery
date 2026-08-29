#!/usr/bin/env Rscript
# =============================================================================
# Does the manuscript-number gate actually refuse?
# =============================================================================
# A gate that passes on a correct manuscript has shown it does not fire. It has
# not shown it could. Each way of getting this wrong is planted in a scratch
# manuscript and the gate must reject it -- and, just as importantly, must NOT
# reject the legitimate literals a paper is full of. A checker that fires on
# "2023 Census cartographic boundary files" is one nobody keeps.
#
# The green cases are the load-bearing half of this file.
# =============================================================================

root <- normalizePath(if (dir.exists("tests")) "." else "..")
GATE <- file.path(root, "tests", "ci_manuscript_numbers.R")
stopifnot(file.exists(GATE))

pass <- 0L; fail_n <- 0L; failures <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) { pass <<- pass + 1L; cat(sprintf("  ok   %s\n", m)) }
  else { fail_n <<- fail_n + 1L; failures <<- c(failures, m); cat(sprintf("  FAIL %s\n", m)) } }

ART <- c("composition_rucc_cat.csv", "linkage_selection_bounds.csv",
         "linkage_completeness_by_status.csv", "table1_midwives.csv")

#' A scratch repository whose manuscript is correct, then whatever is overridden
#'
#' mn_ prefixed: ci_hygiene H4 fails on a top-level function defined in two
#' tracked files, and `scaffold` is already taken by
#' tests/test_science_contracts_detect.R. It caught this one -- but only after
#' the file was staged, because H4 reads git ls-files and an unstaged file is
#' invisible to it.
#' @keywords internal
#' @noRd
mn_scaffold <- function(qmd_lines, artifact_edits = list()) {
  d <- file.path(tempdir(), paste0("mn_", as.integer(stats::runif(1) * 1e9)))
  for (s in c("tests", "manuscript/R", "artifacts"))
    dir.create(file.path(d, s), recursive = TRUE, showWarnings = FALSE)
  for (f in c("ci_report.R", "lib_manuscript_numbers.R", "ci_manuscript_numbers.R"))
    file.copy(file.path(root, "tests", f), file.path(d, "tests", f))
  file.copy(file.path(root, "manuscript", "R", "build_stats_catalog.R"),
            file.path(d, "manuscript", "R", "build_stats_catalog.R"))
  for (f in c("protected_results.tsv", "allowed_literals.tsv"))
    file.copy(file.path(root, "manuscript", f), file.path(d, "manuscript", f))
  for (a in ART) {
    src <- file.path(root, "artifacts", a)
    if (file.exists(src)) file.copy(src, file.path(d, "artifacts", a))
  }
  for (nm in names(artifact_edits))
    writeLines(artifact_edits[[nm]], file.path(d, "artifacts", nm))
  writeLines(qmd_lines, file.path(d, "manuscript", "paper.qmd"))
  d
}

# The gate resolves its root from getwd(), so each scenario runs inside its own
# scratch repository. Running it from here would silently check the real one.
run_in <- function(dir) {
  wd <- getwd(); on.exit(setwd(wd), add = TRUE); setwd(dir)
  out <- tempfile()
  code <- suppressWarnings(system2("Rscript", c(file.path("tests", "ci_manuscript_numbers.R")),
                                   stdout = out, stderr = out))
  txt <- paste(readLines(out, warn = FALSE), collapse = "\n")
  unlink(out)
  list(code = code, text = txt)
}

# Every registered quantity referenced once, so P2 is satisfied in every
# scenario and only the property under test can fail.
refs <- local({
  reg <- readLines(file.path(root, "manuscript", "protected_results.tsv"), warn = FALSE)
  reg <- reg[!grepl("^#", reg) & nzchar(trimws(reg))][-1]
  keys <- vapply(strsplit(reg, "\t"), `[`, character(1), 1)
  sprintf("Generated: `r mw_safe_stat(\"%s\")`", keys)
})

cat("\n-- green: the things a paper legitimately contains --\n")

r <- run_in(mn_scaffold(c("# Paper", refs)))
chk(r$code == 0, "a manuscript that generates every protected value passes")

r <- run_in(mn_scaffold(c("# Paper",
  "Data covered 2007 to 2025, using the 2023 Census cartographic boundary files",
  "and the 2020 ZCTA relationship file. Proportions carry 95% Wilson intervals.",
  "RUCC bands are 1--3, 4--6 and 7--9; the threshold was 60% of land area.",
  "See Appendix 1, Table 3 and Figure 2. The SHA-256 is recorded.", refs)))
chk(r$code == 0, "years, RUCC bands, a 95% CI label, a 60% threshold and section numbers pass")

cat("\n-- red: a protected result typed instead of generated --\n")

r <- run_in(mn_scaffold(c("# Paper",
  "Among the cohort, 89.3% practiced in metropolitan counties.", refs)))
chk(r$code != 0 && grepl("types 89.3", r$text, fixed = TRUE) &&
      grepl("cohort.metro_pct", r$text, fixed = TRUE),
    "a typed 89.3 is caught and named as cohort.metro_pct")

r <- run_in(mn_scaffold(c("# Paper",
  "The cohort comprised 14,861 midwives with an assignable county.", refs)))
chk(r$code != 0 && grepl("types 14,861", r$text, fixed = TRUE),
    "a typed count with a thousands separator is caught")

r <- run_in(mn_scaffold(c("# Paper", "A total of 14861 records resolved.", refs)))
chk(r$code != 0 && grepl("types 14861", r$text, fixed = TRUE),
    "the same count typed without the separator is caught")

cat("\n-- red: one estimand with two values --\n")

lsb <- readLines(file.path(root, "artifacts", "linkage_selection_bounds.csv"), warn = FALSE)
hdr <- strsplit(lsb[1], ",")[[1]]
oi <- which(hdr == "observed_pct")
bent <- lsb
row <- strsplit(lsb[2], ",")[[1]]; row[oi] <- "77.7"; bent[2] <- paste(row, collapse = ",")
r <- run_in(mn_scaffold(c("# Paper", refs),
                     list("linkage_selection_bounds.csv" = bent)))
chk(r$code != 0 && grepl("P4", r$text, fixed = TRUE),
    "cohort.metro_pct and bounds.metro_pct disagreeing is caught by P4")

cat("\n-- green: the canonical value changed, and the prose moved with it --\n")

# THE POINT OF GENERATING RATHER THAN FREEZING. A protected value is not pinned
# forever; it may change whenever its source changes, provided every manuscript
# representation changes with it. Here both the composition and the bounds move
# together and the prose, being generated, follows.
comp <- readLines(file.path(root, "artifacts", "composition_rucc_cat.csv"), warn = FALSE)
comp2 <- sub("^1_retained,Metro \\(RUCC 1-3\\),13277,15347,.*$",
             "1_retained,Metro (RUCC 1-3),13000,15347,84.7", comp)
# BOTH SIDES, and getting this wrong the first time is the scenario working.
# Moving the metropolitan count without moving the denominator it is a share of
# leaves cohort.metro_pct at 13000/14584 and bounds.metro_pct at 13000/14861,
# and P4 correctly refused it. A regeneration that touches one artifact and not
# the other is not a regeneration; it is the drift this gate exists to catch.
lsb2 <- lsb
row2 <- strsplit(lsb[2], ",")[[1]]
ki <- which(hdr == "n_linked_in_cat"); nl <- which(hdr == "n_linked")
new_known <- 13000 + 1075 + 509
row2[ki] <- "13000"
row2[nl] <- as.character(new_known)
row2[oi] <- sprintf("%.14f", 100 * 13000 / new_known)
lsb2[2] <- paste(row2, collapse = ",")
r <- run_in(mn_scaffold(c("# Paper", refs),
                     list("composition_rucc_cat.csv" = comp2,
                          "linkage_selection_bounds.csv" = lsb2)))
chk(r$code == 0, "a changed canonical value with a regenerated manuscript still passes")

cat(sprintf("\n%d passed, %d failed\n", pass, fail_n))
if (fail_n) { for (f in failures) cat(sprintf("  - %s\n", f)); quit(status = 1) }
cat("PASS (0 failures)\n")
