#!/usr/bin/env Rscript

root <- normalizePath(if (dir.exists("tests")) "." else "..")
qmd_path <- Sys.getenv("FDB_QMD", file.path(root, "manuscript", "federal_database_accuracy.qmd"))
den_path <- Sys.getenv("FDB_DENOMINATORS", file.path(root, "review", "denominator_ledger.csv"))
find_path <- Sys.getenv("FDB_FINDINGS", file.path(root, "review", "manuscript_findings_ledger.csv"))
trend_path <- Sys.getenv("FDB_TREND", file.path(root, "artifacts", "dac_agreement_cluster_trend.csv"))
flow_path <- Sys.getenv("FDB_FLOW", file.path(root, "artifacts", "federal_database_accuracy_cohort_flow.csv"))

pass <- 0L; failures <- character()
chk <- function(ok, label) {
  if (isTRUE(ok)) { pass <<- pass + 1L; cat("  ok  ", label, "\n") }
  else { failures <<- c(failures, label); cat("  FAIL", label, "\n") }
}
read_required <- function(path) {
  if (!file.exists(path)) return(NULL)
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}
value <- function(d, id, field = "numerator") {
  z <- d[d$statistic_id == id, field][1]
  n <- suppressWarnings(as.numeric(z))
  if (!is.na(n)) n else z
}

qmd <- if (file.exists(qmd_path)) paste(readLines(qmd_path, warn = FALSE), collapse = "\n") else ""
den <- read_required(den_path)
findings <- read_required(find_path)
trend <- read_required(trend_path)
flow <- read_required(flow_path)

cat("\n-- MAN-01/02/03/06/07 denominator and unit contracts --\n")
chk(!is.null(den), "denominator ledger exists")
if (!is.null(den)) {
  chk(value(den, "COHORT_MIDWIFERY") + value(den, "COHORT_NURSING") ==
        value(den, "COHORT_FINAL"), "MAN-02 cohort tiers reconcile exactly")
  chk(value(den, "PERSIST_2021_2026") == 563 &&
        value(den, "PERSIST_2021_2026", "denominator") == 892,
      "MAN-01 persistence is 563/892, not more than three quarters")
  chk(value(den, "OPEN_PAYMENTS_2025_RECORDS", "unit") == "comparable_source_record" &&
        value(den, "OPEN_PAYMENTS_2025_NPIS", "unit") == "unique_NPI",
      "MAN-03 Open Payments records and unique clinicians are distinct")
  chk(value(den, "LIC_NPPES_7") == 1796 &&
        value(den, "LIC_NPPES_7", "denominator") == 1940,
      "MAN-06 seven-state accuracy uses resolved-only denominator")
  chk(abs(100 * value(den, "MEDICAID_MULTISTATE") /
          value(den, "MEDICAID_MULTISTATE", "denominator") - 16.06508) < 1e-4,
      "MAN-07 multistate percentage reproduces 8581/53414")
  chk(value(den, "MEDICAID_CLASS_CONCORDANT") +
        value(den, "MEDICAID_CLASS_MULTI_CONCORDANT") ==
        value(den, "MEDICAID_CLASS_ANY_CONCORDANT"),
      "Medicaid 27,175 component count reconciles")
}

chk(!is.null(flow), "cohort-flow artifact exists")
if (!is.null(flow)) {
  n <- setNames(flow$n, flow$stage)
  chk(all(c("amcb_records", "midwifery_taxonomy", "nursing_taxonomy", "analytic_cohort") %in% names(n)) &&
        n["midwifery_taxonomy"] + n["nursing_taxonomy"] == n["analytic_cohort"] &&
        n["analytic_cohort"] <= n["amcb_records"],
      "MAN-08 flow branches reconcile")
}

cat("\n-- MAN-04/05/09/10/11/12 reporting contracts --\n")
chk(grepl("Wilson", qmd, fixed = TRUE) && grepl("cluster bootstrap", qmd, ignore.case = TRUE),
    "MAN-04 Methods promise both Wilson and cluster-bootstrap intervals")
chk(grepl("Common comparison source", qmd, fixed = TRUE) &&
      !grepl("served as the reference standard", qmd, fixed = TRUE),
    "MAN-05 NPPES is not labeled geographic truth")
chk(grepl("Certified-name agreement", qmd, ignore.case = TRUE) &&
      !grepl("Attribute.{0,80}Legal name", qmd, ignore.case = TRUE),
    "certified-name terminology is used")
chk(grepl("certified nurse-midwife and certified midwife workforce", qmd, fixed = TRUE),
    "MAN-11 abstract includes both CNMs and CMs")
chk(!grepl("practises|postal code", qmd, ignore.case = TRUE),
    "US spelling and ZIP terminology are consistent")
chk(!grepl("a recent update generally marks a recent move|billing observes a practice move", qmd,
           ignore.case = TRUE), "MAN-10 unverified practice moves are not asserted")
chk(!grepl("Practice state is the only geographic variable|agreement this tight bounds", qmd,
           ignore.case = TRUE), "geographic conclusions are evidence-limited")
chk(lengths(regmatches(qmd, gregexpr("A$persistent_2026_pct", qmd,
                                     fixed = TRUE))) >= 2 &&
      !grepl("more than three quarters", qmd, ignore.case = TRUE),
    "MAN-01/MAN-12 abstract and Results use the same persistence source")

cat("\n-- MAN-09 dependence-aware trend contract --\n")
need_trend <- c("source", "start_year", "end_year", "n_npi_years", "n_npis",
                "slope_pp_per_year", "ci_low", "ci_high", "absolute_change_pp",
                "method")
chk(!is.null(trend) && all(need_trend %in% names(trend)),
    "MAN-09 clustered trend artifact carries estimand and uncertainty")
if (!is.null(trend) && all(need_trend %in% names(trend))) {
  chk(grepl("cluster", trend$method[1], ignore.case = TRUE) &&
        trend$n_npi_years[1] > trend$n_npis[1],
      "trend inference clusters repeated clinician-years")
  chk(!grepl("mw_pval(A$dac_p)", qmd, fixed = TRUE),
      "old aggregate-WLS P value is not retained")
}

chk(!is.null(findings) && identical(findings$finding_id, sprintf("F%02d", 1:12)),
    "F01-F12 findings ledger is complete")

cat(sprintf("\n%d passed, %d failed\n", pass, length(failures)))
if (length(failures)) {
  cat(paste0("  - ", failures, collapse = "\n"), "\n")
  quit(status = 1)
}
cat("PASS (0 failures)\n")
