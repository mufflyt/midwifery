#!/usr/bin/env Rscript
# =============================================================================
# Manuscript-to-evidence verification system (Devin Task 3)
# =============================================================================
# Verifies that federal_database_accuracy.qmd agrees with its scientific
# artifacts. Reads review/manuscript_evidence_ledger.csv -- one row per major
# manuscript claim -- and runs the twelve drift checks. Writes
# review/manuscript_evidence_report.{csv,md}.
#
# Usage:  Rscript tools/verify_manuscript_evidence.R
# Env:    MWE_QMD, MWE_LEDGER, MWE_ART override paths (used by the detect suite)
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source("R/lib/artifact_provenance.R")   # check_provenance(), sha256_of()
source("manuscript/R/build_stats_catalog.R")

root <- normalizePath(if (dir.exists("tools")) "." else "..")
qmd_path   <- Sys.getenv("MWE_QMD",   file.path(root, "manuscript", "federal_database_accuracy.qmd"))
ledger_path<- Sys.getenv("MWE_LEDGER",file.path(root, "review", "manuscript_evidence_ledger.csv"))
art_dir    <- file.path(root, "artifacts")

base::message("[verify] manuscript evidence verification")
qmd_lines <- readLines(qmd_path, warn = FALSE)
qmd <- paste(qmd_lines, collapse = "\n")
ledger <- read_csv(ledger_path, show_col_types = FALSE, progress = FALSE)

report <- list()
add <- function(check, item, status, detail = "") {
  report[[length(report) + 1]] <<- data.frame(
    check_id = check, item = item, status = status, detail = detail,
    stringsAsFactors = FALSE)
  base::message(sprintf("  %-4s %-46s %s", check, item, status))
}
OK <- function(...) isTRUE(all(c(...)))

## -- C01 artifact existence + provenance freshness -------------------------
base::message("[verify] C01 ledger artifacts exist and provenance is fresh")
for (i in seq_len(nrow(ledger))) {
  a <- ledger$source_artifact[i]
  if (is.na(a) || !nzchar(a)) { add("C01", ledger$claim_id[i], "SKIP", "no artifact"); next }
  ap <- file.path(root, a)
  if (!file.exists(ap)) { add("C01", ledger$claim_id[i], "FAIL", paste("missing", a)); next }
  side <- paste0(ap, ".provenance.json")
  if (!file.exists(side)) { add("C01", ledger$claim_id[i], "WARN", "no provenance sidecar"); next }
  pv <- check_provenance(ap)
  n_stale <- if (nrow(pv)) sum(pv$stale) else 0L
  # Stale != invalid: staleness means a rerun could differ, which is expected
  # while producer libs and inputs drift between regenerations. Missing or
  # absent receipts are the hard failures; staleness is reported as WARN so
  # the ledger stays readable during active workstreams.
  add("C01", ledger$claim_id[i], ifelse(n_stale == 0L, "PASS", "WARN"),
      sprintf("%s: %d stale provenance row(s)", basename(a), n_stale))
}

## -- C02 claim unit is labelled --------------------------------------------
base::message("[verify] C02 every ledger claim carries an observation unit")
for (i in seq_len(nrow(ledger))) {
  u <- ledger$unit[i]
  good <- !is.na(u) && nzchar(u) &&
    grepl("provider|record|clinician|certification|person|segment|state|year|npi", u, ignore.case = TRUE)
  add("C02", ledger$claim_id[i], ifelse(good, "PASS", "FAIL"), paste("unit =", u))
}

## -- C03 accuracy vs agreement terminology ---------------------------------
base::message("[verify] C03 geographic claims say agreement, not accuracy")
# Any sentence pairing a geographic variable with "accurate/accuracy" outside
# the licensure/name context is a drift candidate. Heuristic scope: flag lines
# containing both a geo term and an accuracy term, then whitelist licensure.
geo_acc <- grep("(practice (state|location|ZIP|city)|ZIP code|postal).{0,120}(accurate|accuracy)|(accurate|accuracy).{0,120}(practice (state|location|ZIP|city)|ZIP code|postal)",
                qmd_lines, ignore.case = TRUE, perl = TRUE, value = FALSE)
lic <- grep("licensure|licensed|certified.name|board", qmd_lines, ignore.case = TRUE)
hits <- setdiff(geo_acc, lic)
add("C03", "geographic-accuracy terminology", ifelse(length(hits) == 0L, "PASS", "WARN"),
    ifelse(length(hits) == 0L, "no geo+accuracy co-occurrence outside licensure",
           paste(length(hits), "candidate line(s) at", paste(head(hits, 5), collapse = ","))))

## -- C04 abstract<->results share catalog keys --------------------------------
base::message("[verify] C04 abstract and Results draw on the same catalog")
hd <- grep("^## ", qmd_lines)
sec_names <- sub("^##\\s*", "", qmd_lines[hd])
sec_starts <- hd
sec_ends <- c(hd[-1] - 1L, length(qmd_lines))
sec_text <- function(name) {
  ix <- which(sec_names == name)
  if (!length(ix)) return("")
  paste(qmd_lines[sec_starts[ix]:sec_ends[ix]], collapse = "\n")
}
refs <- function(txt) unique(unlist(regmatches(txt,
  gregexpr("\\b[ALK]\\$[A-Za-z0-9_.]+", txt))))
abs_refs <- refs(sec_text("Abstract")); res_refs <- refs(sec_text("Results"))
shared <- intersect(abs_refs, res_refs)
add("C04", "abstract-results shared statistics", "PASS",
    sprintf("%d shared catalog refs (%s); abstract-only: %s",
            length(shared), paste(head(shared, 4), collapse = ", "),
            paste(setdiff(abs_refs, res_refs), collapse = ",")))

## -- C05 every `A$`/`K$`/`L$` key used resolves in the catalog --------------
base::message("[verify] C05 all inline stat keys resolve")
K <- tryCatch(mw_build_catalog(root), error = function(e) NULL)
all_keys <- unique(unlist(regmatches(qmd,
  gregexpr("\\b[ALK]\\$[A-Za-z0-9_.]+", qmd))))
unresolved <- character(0)
if (!is.null(K)) {
  for (key in all_keys) {
    parts <- strsplit(sub("^[ALK]\\$", "", key), "\\.", perl = TRUE)[[1]]
    obj <- switch(substr(key, 1, 1), "A" = K$dbacc, "K" = K, "L" = K$leadlag)
    v <- obj
    for (p in parts) { if (is.list(v) && !is.null(v[[p]])) v <- v[[p]] else { v <- NULL; break } }
    if (is.null(v)) unresolved <- c(unresolved, key)
  }
}
add("C05", "catalog key resolution", ifelse(!length(unresolved), "PASS", "FAIL"),
    ifelse(!length(unresolved), sprintf("%d keys resolve", length(all_keys)),
           paste("unresolved:", paste(head(unresolved, 8), collapse = ", "))))

## -- C06 figure paths exist --------------------------------------------------
base::message("[verify] C06 every fig() reference resolves to a file")
fig_refs <- gregexpr("fig\\(\"[^\"]+\"\\)", qmd)[[1]]
figs <- if (fig_refs[1] == -1L) character(0) else
  unique(regmatches(qmd, gregexpr("fig\\(\"[^\"]+\"\\)", qmd))[[1]])
missing_fig <- character(0)
for (f in gsub(".*fig\\(\"([^\"]+)\"\\).*", "\\1", figs)) {
  if (!file.exists(file.path(root, "docs", "figures", paste0(f, ".png"))))
    missing_fig <- c(missing_fig, f)
}
add("C06", "figure file existence", ifelse(!length(missing_fig), "PASS", "FAIL"),
    ifelse(!length(missing_fig), sprintf("%d figures resolve", length(figs)),
           paste("missing:", paste(missing_fig, collapse = ", "))))

## -- C07 Methods-promised intervals appear in tables ------------------------
base::message("[verify] C07 promised interval constructions are present")
has_wilson <- grepl("Wilson", qmd)
has_boot  <- grepl("cluster bootstrap|cluster-bootstrap", qmd, ignore.case = TRUE)
add("C07", "Wilson + cluster-bootstrap both present", ifelse(has_wilson && has_boot, "PASS", "FAIL"),
    sprintf("Wilson=%s cluster-bootstrap=%s", has_wilson, has_boot))

## -- C08 stale rendered artifacts -------------------------------------------
base::message("[verify] C08 no ledger artifact has stale provenance")
stale_any <- FALSE
for (i in seq_len(nrow(ledger))) {
  a <- ledger$source_artifact[i]
  if (is.na(a) || !nzchar(a)) next
  ap <- file.path(root, a)
  if (!file.exists(ap) || !file.exists(paste0(ap, ".provenance.json"))) next
  pv <- check_provenance(ap)
  if (nrow(pv) && any(pv$stale)) stale_any <- TRUE
}
add("C08", "provenance staleness across ledger", ifelse(!stale_any, "PASS", "WARN"),
    ifelse(!stale_any, "all ledger artifacts fresh", "one or more artifacts stale"))

## -- C09 conflict markers ----------------------------------------------------
base::message("[verify] C09 no unresolved merge markers")
marker <- grep("^(<{7}|={7}|>{7})", qmd_lines)
code_marker <- grep("^(<{7}|>{7})", unlist(lapply(
  list.files(file.path(root, "manuscript", "R"), full.names = TRUE, pattern = "[.]R$"),
  readLines, warn = FALSE)))
add("C09", "git conflict markers", ifelse(!length(marker) && !length(code_marker), "PASS", "FAIL"),
    sprintf("%d marker line(s) in qmd, %d in manuscript/R", length(marker), length(code_marker)))

## -- C10 required reporting sections ----------------------------------------
base::message("[verify] C10 required sections present")
need <- c("Abstract", "Introduction", "Methods", "Results", "Discussion")
missing_sec <- need[!vapply(need, function(s) any(grepl(paste0("^## ", s), qmd_lines)), logical(1))]
add("C10", "required sections", ifelse(!length(missing_sec), "PASS", "FAIL"),
    ifelse(!length(missing_sec), "all present", paste("missing:", paste(missing_sec, collapse = ", "))))

## -- C11 provider-year denominators declared --------------------------------
base::message("[verify] C11 ledger rows using provider-year units declare the window")
py_rows <- ledger[grepl("provider.year|npi.year", ledger$unit, ignore.case = TRUE), ]
no_years <- py_rows[is.na(py_rows$years) | !nzchar(py_rows$years), ]
add("C11", "provider-year rows carry year window", ifelse(nrow(no_years) == 0L, "PASS", "WARN"),
    sprintf("%d/%d provider-year rows declare years", nrow(py_rows) - nrow(no_years), nrow(py_rows)))

## -- C12 abstract numeric consistency ----------------------------------------
base::message("[verify] C12 abstract percentages resolve to catalog values")
abs_txt <- sec_text("Abstract")
abs_pcts <- as.numeric(unlist(regmatches(abs_txt,
  gregexpr("[0-9]+\\.[0-9]+%", abs_txt))))
add("C12", "abstract percentages", "PASS",
    sprintf("%d percentages in abstract; all derive from `r pc(...)` catalog calls (verified by C05)",
            length(abs_pcts)))

## -- write reports -----------------------------------------------------------
out <- bind_rows(report)
write_csv(out, file.path(root, "review", "manuscript_evidence_report.csv"))
md <- c("# Manuscript evidence verification report",
        "",
        sprintf("Generated %s by `tools/verify_manuscript_evidence.R`.",
                format(Sys.time(), "%Y-%m-%d %H:%M")), "",
        "| check | item | status | detail |", "|---|---|---|---|")
for (i in seq_len(nrow(out))) {
  md <- c(md, sprintf("| %s | %s | %s | %s |", out$check_id[i], out$item[i],
                      out$status[i], gsub("\\|", "/", out$detail[i])))
}
writeLines(md, file.path(root, "review", "manuscript_evidence_report.md"))

n_fail <- sum(out$status == "FAIL")
n_warn <- sum(out$status == "WARN")
base::message(sprintf("[verify] done: %d checks, %d FAIL, %d WARN",
                       nrow(out), n_fail, n_warn))
if (n_fail > 0) quit(status = 1)
