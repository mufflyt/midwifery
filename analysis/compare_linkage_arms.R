suppressMessages(library(data.table))
source(file.path("R", "analysis_args.R"))   # arg_or()

pick <- function(d) { f <- list.files(file.path(d,"artifacts"),
  pattern="^amcb_npi_linkage_panel-.*\\.csv$", full.names=TRUE); stopifnot(length(f)==1); f }
cf <- pick(arg_or(1, "CONTROL_WORKTREE")); tf <- pick(arg_or(2, "TREATMENT_WORKTREE", "."))
con <- fread(cf, colClasses="character"); trt <- fread(tf, colClasses="character")
cat("control  :", basename(cf), nrow(con), "rows\n")
cat("treatment:", basename(tf), nrow(trt), "rows\n\n")

status_counts <- function(d) d[, .N, npi_match_status]
cat("== npi_match_status: control -> treatment ==\n")
print(merge(status_counts(con), status_counts(trt), by="npi_match_status", all=TRUE, suffixes=c(".con",".trt"))[
  , .(npi_match_status, control=N.con, treatment=N.trt,
      delta=fcoalesce(N.trt,0L)-fcoalesce(N.con,0L))][order(-control)])

MEM <- c('primary_midwifery','sensitivity_nursing','sensitivity_fuzzy','sensitivity_unknown_taxonomy')
cohort <- function(d) d[nzchar(npi) & linkage_tier %in% MEM, .N]
cat(sprintf("\ncohort members: control %s -> treatment %s (delta %+d)\n",
  cohort(con), cohort(trt), cohort(trt)-cohort(con)))

m <- merge(con[, .(amcb_id, s.con=npi_match_status, npi.con=npi, cls.con=name_evidence_class)],
           trt[, .(amcb_id, s.trt=npi_match_status, npi.trt=npi, cls.trt=name_evidence_class)],
           by="amcb_id")
cat("\n== status transitions (control -> treatment) ==\n")
print(m[s.con != s.trt, .N, .(s.con, s.trt)][order(-N)])
cat("\n== REGRESSION: had an NPI in control, none in treatment ==\n")
print(m[nzchar(npi.con) & !nzchar(npi.trt), .N, .(s.con, s.trt)])
cat("\n== REGRESSION: matched to a DIFFERENT NPI ==\n")
print(m[nzchar(npi.con) & nzchar(npi.trt) & npi.con != npi.trt, .N])
cat("\n== evidence class shifts among rows matched in BOTH ==\n")
print(m[nzchar(npi.con) & nzchar(npi.trt), .N, .(cls.con, cls.trt)][order(cls.con, cls.trt)])

cat("\n== new instrumentation (treatment) ==\n")
cat("resolved_by_absence_c2      :", trt[resolved_by_absence_c2=="TRUE", .N], "\n")
cat("unmatched_after_middle_veto :", trt[unmatched_after_middle_veto=="TRUE", .N], "\n")
cat("resolved_by_absence_c5      :", trt[resolved_by_absence_c5=="TRUE", .N],
    " (control:", con[resolved_by_absence_c5=="TRUE", .N], ")\n")

# Optional: a person-level case list from audit_identity_flips.R, if one has
# been produced. Person-level, so it is gitignored and absent by default --
# skipped rather than assumed, because a selector matching nothing has not
# passed, it has not run (see assert_nonempty_selection in R/amcb_match_rules.R).
CASES <- Sys.getenv("VETO_CASE_LIST", "")
if (nzchar(CASES) && file.exists(CASES)) {
  cat("\n== exact-name veto casualties from", basename(CASES), "==\n")
  ids <- unique(fread(CASES, colClasses = "character")$amcb_id)
  print(m[amcb_id %in% ids, .N, .(s.con, s.trt)][order(-N)])
} else {
  cat("\n== veto casualty cross-tab skipped: set VETO_CASE_LIST to a case file ==\n")
}
cat("\n== the parenthesised-nickname rows ==\n")
pr <- con[grepl("[()]", first_name)|grepl("[()]", middle_name)|grepl("[()]", last_name), amcb_id]
print(m[amcb_id %in% pr, .N, .(s.con, s.trt)][order(-N)])
