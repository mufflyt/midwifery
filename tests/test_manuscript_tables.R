#!/usr/bin/env Rscript
# =============================================================================
# Manuscript table contracts
# =============================================================================
# These checks protect the public table layer, where correct artifacts can still
# be misrepresented by stale generated documents or a display choice that hides
# a denominator.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) {
    cat(sprintf("  ok   %s\n", msg))
  } else {
    fails <<- fails + 1L
    cat(sprintf("  FAIL %s\n", msg))
  }
}

qmd <- readLines(file.path(root, "manuscript", "midwife_persistence.qmd"), warn = FALSE)
builder <- readLines(file.path(root, "build_table1_midwives.R"), warn = FALSE)
t1 <- read.csv(file.path(root, "artifacts", "table1_midwives.csv"),
               stringsAsFactors = FALSE, na.strings = "")

cat("\n-- Table 1 generated outputs --\n")

cohort_n <- t1$n[t1$category == "Cohort" &
                   t1$characteristic == "ACTIVE, primary-linked midwives"][1]
md <- readLines(file.path(root, "docs", "table1_midwives.md"), warn = FALSE)
cohort_line <- md[grep("^Cohort:", md)][1]
md_n <- as.integer(gsub(",", "", sub("^.*\\*\\*([0-9,]+)\\*\\*.*$", "\\1", cohort_line)))

chk(identical(md_n, as.integer(cohort_n)),
    "docs/table1_midwives.md reports the same cohort size as artifacts/table1_midwives.csv")
cohort_def <- paste(builder[grep("^coh <- link", builder)[1]:grep("^N <- nrow\\(coh\\)", builder)[1]],
                    collapse = "\n")
chk(grepl("mutate\\(npi = as.character\\(npi\\)\\)", cohort_def),
    "Table 1 normalizes cohort NPI before optional joins")
chk(any(grepl('!"in_dac" %in% names\\(coh\\)', builder)),
    "Table 1 defines an in_dac fallback before optional DAC joins")

cat("\n-- Main manuscript Table 1 --\n")

chk(any(grepl('"Years Observed in NPPES Panel"', builder, fixed = TRUE)),
    "the canonical Table 1 builder emits an observability block")
chk(any(grepl('"Years Observed in NPPES Panel"', qmd, fixed = TRUE)),
    "the mobility manuscript selects the observability block for Table 1")
patient_age_block <- "Median age of the midwife's patients"
chk(any(grepl(patient_age_block, builder, fixed = TRUE)),
    "the canonical Table 1 builder emits the Trilliant patient-age block when available")
chk(any(grepl(patient_age_block, qmd, fixed = TRUE)),
    "the mobility manuscript selects the Trilliant patient-age block for Table 1")
chk(!any(grepl("No claims panel in the Trilliant directory", builder, fixed = TRUE)),
    "the Table 1 builder uses NA for an unavailable patient panel")
chk(!any(grepl("No claims panel in the Trilliant directory", qmd, fixed = TRUE)),
    "the manuscript does not print the Trilliant directory missingness label")
patient_female_block <- "Share of patients female (Trilliant claims panel)"
chk(!any(grepl(patient_female_block, builder, fixed = TRUE)),
    "the canonical Table 1 builder omits the Trilliant patient-sex-mix block")
chk(!any(grepl(patient_female_block, qmd, fixed = TRUE)),
    "the mobility manuscript omits the Trilliant patient-sex-mix block")
work_setting_blocks <- c("Medicare practice group size (CMS DAC)",
                         "Number of practice locations (CMS DAC)",
                         "Any observed hospital work site",
                         "Primary claims-site setting")
for (block in work_setting_blocks)
  chk(any(grepl(block, qmd, fixed = TRUE)),
      sprintf("the mobility manuscript selects the work-setting block: %s", block))
chk(!any(grepl("Hospital affiliation (CMS facility affiliation, CCN)", builder, fixed = TRUE)),
    "the canonical Table 1 builder omits the CMS privilege-derived hospital block")
chk(!any(grepl("Hospital affiliation (CMS facility affiliation, CCN)", qmd, fixed = TRUE)),
    "the mobility manuscript omits the CMS privilege-derived hospital block")
chk(any(grepl("Primary claims-site setting", builder, fixed = TRUE)),
    "the canonical Table 1 builder emits the primary-site setting detail")
chk(any(grepl("not recorded/unresolved/not applicable", qmd, fixed = TRUE)),
    "Table 1 note distinguishes missingness from denominator exclusions")

cat("\n-- Main manuscript Tables 2-4 --\n")

chk(any(grepl("style_manuscript_table", qmd, fixed = TRUE)),
    "main manuscript tables use a shared table formatter")
chk(any(grepl("sprintf\\(\"%s \\(%.1f\\)\"", qmd)),
    "Table 4 renders mover destinations as n (%) cells")
chk(any(grepl("Percentages are row percentages", qmd, fixed = TRUE)),
    "Table 4 caption states the row-percentage denominator")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
