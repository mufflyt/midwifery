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

# Every artifact the catalog needs to resolve a REGISTERED key. Adding a
# protected quantity without adding its source here fails the green cases --
# which is the scaffold telling you the registry outran the fixture, not a
# defect in the gate.
ART <- c("composition_rucc_cat.csv", "linkage_selection_bounds.csv",
         "linkage_completeness_by_status.csv", "table1_midwives.csv",
         "linkage_coverage_floor.csv")

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

# THE LITERAL COMES FROM THE CATALOG, not from this file. Pinning 89.3 and
# 14,861 here made three red cases fail the moment those values legitimately
# changed -- a test asserting a stale answer rather than a property, which is
# the exact defect the protected-results registry exists to prevent, reproduced
# in its own detector.
local({
  suppressPackageStartupMessages({
    source(file.path(root, "manuscript", "R", "build_stats_catalog.R"))
    source(file.path(root, "manuscript", "R", "inline_stats.R"))
  })
  mw_init_stats(root)
  pct <- mw_stat("cohort.metro_pct", "%.1f")
  cnt <- mw_n("cohort.known_n")
  bare <- gsub(",", "", cnt, fixed = TRUE)

  r <- run_in(mn_scaffold(c("# Paper",
    sprintf("Among the cohort, %s%% practiced in metropolitan counties.", pct), refs)))
  chk(r$code != 0 && grepl(sprintf("types %s", pct), r$text, fixed = TRUE) &&
        grepl("cohort.metro_pct", r$text, fixed = TRUE),
      sprintf("a typed %s%% is caught and named as cohort.metro_pct", pct))

  r <- run_in(mn_scaffold(c("# Paper",
    sprintf("The cohort comprised %s midwives with an assignable county.", cnt), refs)))
  chk(r$code != 0 && grepl(sprintf("types %s", cnt), r$text, fixed = TRUE),
      "a typed count with a thousands separator is caught")

  r <- run_in(mn_scaffold(c("# Paper",
    sprintf("A total of %s records resolved.", bare), refs)))
  chk(r$code != 0 && grepl(sprintf("types %s", bare), r$text, fixed = TRUE),
      "the same count typed without the separator is caught")
})

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
# forever; it may change whenever its source changes, provided every
# representation changes with it. Both artifacts are shifted by the same
# arithmetic, so cohort.metro_pct and bounds.metro_pct move together and the
# prose, being generated, follows.
#
# Derived from whatever the artifacts currently hold rather than from a fixed
# row: the composition gained rows when the county recovery landed, and a
# fixture keyed on one hard-coded line stopped matching.
local({
  comp <- readLines(file.path(root, "artifacts", "composition_rucc_cat.csv"), warn = FALSE)
  hdr <- strsplit(comp[1], ",")[[1]]
  gi <- which(hdr == "group"); li <- which(hdr == "level"); ni <- which(hdr == "n")
  parse_row <- function(x) scan(text = x, what = "", sep = ",", quiet = TRUE)
  metro_rows <- which(vapply(comp[-1], function(x) {
    f <- parse_row(x); grepl("^Metro", f[li]) && f[gi] != "4_removed" }, logical(1))) + 1L
  stopifnot(length(metro_rows) >= 1)

  SHIFT <- 300L   # move every cohort metro cell by the same amount
  comp2 <- comp
  moved <- 0L
  for (i in metro_rows) {
    f <- parse_row(comp[i]); f[ni] <- as.character(as.integer(f[ni]) - SHIFT)
    moved <- moved + SHIFT
    comp2[i] <- paste(ifelse(grepl("[ ,]", f), sprintf('"%s"', f), f), collapse = ",")
  }

  lsb <- readLines(file.path(root, "artifacts", "linkage_selection_bounds.csv"), warn = FALSE)
  h2 <- strsplit(lsb[1], ",")[[1]]
  ki <- which(h2 == "n_linked_in_cat"); nl <- which(h2 == "n_linked"); oi <- which(h2 == "observed_pct")
  row <- parse_row(lsb[2])
  new_k <- as.integer(row[ki]) - moved
  new_n <- as.integer(row[nl]) - moved
  row[ki] <- as.character(new_k); row[nl] <- as.character(new_n)
  row[oi] <- sprintf("%.14f", 100 * new_k / new_n)
  lsb2 <- lsb; lsb2[2] <- paste(ifelse(grepl("[ ,]", row), sprintf('"%s"', row), row), collapse = ",")

  r <- run_in(mn_scaffold(c("# Paper", refs),
                          list("composition_rucc_cat.csv" = comp2,
                               "linkage_selection_bounds.csv" = lsb2)))
  chk(r$code == 0, "a changed canonical value with a regenerated manuscript still passes")
})

cat(sprintf("\n%d passed, %d failed\n", pass, fail_n))
if (fail_n) { for (f in failures) cat(sprintf("  - %s\n", f)); quit(status = 1) }
cat("PASS (0 failures)\n")
