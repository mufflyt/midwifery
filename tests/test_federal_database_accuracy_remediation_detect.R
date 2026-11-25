#!/usr/bin/env Rscript

root <- normalizePath(if (dir.exists("manuscript")) "." else "..")
gate <- file.path(root, "tests", "test_federal_database_accuracy_remediation.R")
base <- list(
  qmd = file.path(root, "manuscript", "federal_database_accuracy.qmd"),
  den = file.path(root, "review", "denominator_ledger.csv"),
  findings = file.path(root, "review", "manuscript_findings_ledger.csv"),
  trend = file.path(root, "artifacts", "dac_agreement_cluster_trend.csv"),
  flow = file.path(root, "artifacts", "federal_database_accuracy_cohort_flow.csv")
)

run_gate <- function(paths) {
  status <- system2("Rscript", gate, stdout = FALSE, stderr = FALSE,
                    env = c(sprintf("FDB_QMD=%s", paths$qmd),
                            sprintf("FDB_DENOMINATORS=%s", paths$den),
                            sprintf("FDB_FINDINGS=%s", paths$findings),
                            sprintf("FDB_TREND=%s", paths$trend),
                            sprintf("FDB_FLOW=%s", paths$flow)))
  identical(status, 0L)
}

mutate_case <- function(id, mutate) {
  d <- tempfile(paste0(id, "-")); dir.create(d)
  paths <- as.list(setNames(file.path(d, basename(unlist(base))), names(base)))
  for (nm in names(base)) file.copy(base[[nm]], paths[[nm]])
  mutate(paths)
  if (run_gate(paths)) stop(id, " was not detected", call. = FALSE)
  cat("  ok  ", id, " detected\n")
}

edit_text <- function(path, pattern, replacement, fixed = TRUE) {
  x <- readLines(path, warn = FALSE)
  y <- sub(pattern, replacement, x, fixed = fixed)
  if (identical(x, y)) stop("mutation pattern not found: ", pattern, call. = FALSE)
  writeLines(y, path)
}

if (!run_gate(base)) stop("baseline remediation gate must pass before mutation tests", call. = FALSE)

mutate_case("MAN-01", function(p) {
  x <- read.csv(p$den, check.names = FALSE); x$numerator[x$statistic_id == "PERSIST_2021_2026"] <- 670
  write.csv(x, p$den, row.names = FALSE, na = "")
})
mutate_case("MAN-02", function(p) {
  x <- read.csv(p$den, check.names = FALSE); x$numerator[x$statistic_id == "COHORT_NURSING"] <- 1818
  write.csv(x, p$den, row.names = FALSE, na = "")
})
mutate_case("MAN-03", function(p) {
  x <- read.csv(p$den, check.names = FALSE); x$unit[x$statistic_id == "OPEN_PAYMENTS_2025_RECORDS"] <- "unique_NPI"
  write.csv(x, p$den, row.names = FALSE, na = "")
})
mutate_case("MAN-04", function(p) {
  x <- readLines(p$qmd, warn = FALSE)
  writeLines(gsub("Wilson", "score interval", x, fixed = TRUE), p$qmd)
})
mutate_case("MAN-05", function(p) edit_text(p$qmd, "served as the common comparison source, not as a truth standard", "served as the reference standard"))
mutate_case("MAN-06", function(p) {
  x <- read.csv(p$den, check.names = FALSE); x$denominator[x$statistic_id == "LIC_NPPES_7"] <- 3193
  write.csv(x, p$den, row.names = FALSE, na = "")
})
mutate_case("MAN-07", function(p) {
  x <- read.csv(p$den, check.names = FALSE); x$numerator[x$statistic_id == "MEDICAID_MULTISTATE"] <- 8580
  write.csv(x, p$den, row.names = FALSE, na = "")
})
mutate_case("MAN-08", function(p) {
  x <- read.csv(p$flow); x$n[x$stage == "analytic_cohort"] <- 16774
  write.csv(x, p$flow, row.names = FALSE)
})
mutate_case("MAN-09", function(p) {
  x <- read.csv(p$trend); x$method <- "ordinary least squares"
  write.csv(x, p$trend, row.names = FALSE)
})
mutate_case("MAN-10", function(p) {
  x <- readLines(p$qmd, warn = FALSE); writeLines(c(x, "Billing observes a practice move."), p$qmd)
})
mutate_case("MAN-11", function(p) edit_text(p$qmd, "certified nurse-midwife and certified midwife workforce", "certified nurse-midwife workforce"))
mutate_case("MAN-12", function(p) edit_text(p$qmd, "A$persistent_2026_pct", "A$state_inconsistent"))

cat("PASS: all 12 deliberate faults were rejected\n")
