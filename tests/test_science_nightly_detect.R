# =============================================================================
# Does ci_science_nightly.R actually detect anything?
# =============================================================================
# The nightly science gates recompute published numbers. A gate whose structure
# detection never matches -- a percentage column it does not recognise, a
# denominator it never establishes -- reports "0 failures" on a broken artifact
# exactly as it does on a sound one, and 0 failures is what everybody reads.
# test_science_contracts_detect.R makes that argument for the per-push gates;
# this file makes it for the nightly ones.
#
# One planted defect per gate, each asserted to be caught BY NAME -- exit status
# alone would let SCN3 take credit for a defect only SCN1 noticed.
#
# And the converse. Every near-miss here is a shape that a first draft of these
# gates got wrong, pinned so the precision cannot regress:
#
#   a percentage whose denominator is upstream and not in the file at all
#     (pct_uninsured against an ACS table) -- unreproducible is not wrong, and
#     demanding reproduction flagged 33 columns, most of them correct;
#   a rate that correctly writes NA where its denominator is zero;
#   a small group legitimately sitting in one level;
#   an unresolved count in a one-row summary of overlapping indicators, which
#     has no denominator to partition;
#   an interval computed with qnorm(0.975) rather than 1.96, which differs in
#     the fourth decimal and is not a different denominator.
#
# Runs the real gate in a temporary git repository so ci_tracked() shells out to
# a real `git ls-files` rather than a stub. Base R only.
# =============================================================================

root <- normalizePath(".")
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git"))
  root <- normalizePath("..")

GATE   <- file.path(root, "tests", "ci_science_nightly.R")
REPORT <- file.path(root, "tests", "ci_report.R")
stopifnot(file.exists(GATE), file.exists(REPORT))

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else { failures <<- c(failures, msg); cat(sprintf("  FAIL %s\n", msg)) }
}

# -----------------------------------------------------------------------------
# A scaffold that PASSES every gate.
#
# Minimal on purpose. A copy of the real repository carries the three baselined
# sites, and a planted defect would be indistinguishable from a baselined one --
# the mistake the SCI equivalent documents having made.
#
# Wilson bounds below were computed OUTSIDE R, from the closed form, so this
# file does not verify the gate's arithmetic against a copy of the gate's
# arithmetic. z = 1.96; 25.0% of 1000, 75.0% of 120, 75.0% of 60.
# -----------------------------------------------------------------------------
SCN_CLEAN <- list(

  # group/level/n/N: exercises SCN1 (n/N), SCN3 (strata sum to N) and SCN4
  # (every group spans four levels). g4 is the SCN4 near-miss -- a single-level
  # group of 50, below the 100-member floor, which must NOT be flagged.
  "artifacts/composition_demo.csv" = c(
    "group,level,n,N,pct",
    "g1,a,400,1000,40", "g1,b,300,1000,30", "g1,c,200,1000,20", "g1,d,100,1000,10",
    "g2,a,200,500,40",  "g2,b,150,500,30",  "g2,c,100,500,20",  "g2,d,50,500,10",
    "g3,a,80,200,40",   "g3,b,60,200,30",   "g3,c,40,200,20",   "g3,d,20,200,10",
    "g4,a,50,50,100"),

  # SCN2. The last row is the near-miss: a zero denominator whose rate is
  # correctly left empty rather than written as 0.
  "artifacts/rate_demo.csv" = c(
    "unit,num,den,pct",
    "u1,50,200,25", "u2,30,150,20", "u3,10,40,25", "u4,3,10,30", "u5,0,0,"),

  # SCN5.
  "artifacts/interval_demo.csv" = c(
    "stratum,n,n_hit,pct,ci_low,ci_high",
    "s1,1000,250,25.0,22.41526427373505,27.776080655584483",
    "s2,120,90,75.0,66.55869783172575,81.89028861547777",
    "s3,60,45,75.0,62.76768905451521,84.22361442158815"),

  # SCN6.
  "artifacts/ascertainment_demo.csv" = c(
    "stage,n,n_resolved,n_unresolved,pct",
    "st1,1000,600,400,60", "st2,500,200,300,40",
    "st3,200,50,150,25",   "st4,100,30,70,30"),

  # SCN7. 1000 - 150 removed = 850 retained, + 50 added = 900.
  "artifacts/cohort_flow_1000_to_900.csv" = c(
    "reason,n", "withdrawn,120", "reassigned,30"),

  # NEAR-MISS for SCN1: the denominator lives in an ACS table, not in this file.
  # No pair of these columns reproduces the percentage, and that is correct.
  "artifacts/upstream_demo.csv" = c(
    "unit,population,pct_uninsured",
    "u1,52341,12.7", "u2,18902,9.4", "u3,7734,15.1",
    "u4,240118,8.8", "u5,3312,21.6"),

  # NEAR-MISS for SCN6: overlapping indicator counts in a one-row summary. It
  # names an unresolved count but publishes no percentage, so there is no
  # denominator anybody claimed and nothing to partition.
  "artifacts/indicator_demo.csv" = c(
    "built_at,cohort_n,with_hospital,hospitals_linked,ccn_unresolved,any_critical",
    "2026-08-11T08:54:40,11920,1665,902,4,138")
)

scn_scaffold <- function(dir) {
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "artifacts"), recursive = TRUE, showWarnings = FALSE)
  file.copy(GATE,   file.path(dir, "tests", "ci_science_nightly.R"))
  file.copy(REPORT, file.path(dir, "tests", "ci_report.R"))
  for (nm in names(SCN_CLEAN)) writeLines(SCN_CLEAN[[nm]], file.path(dir, nm))
  system2("git", c("-C", shQuote(dir), "init", "-q"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
}

# Runs the gate inside `dir` and returns its output with the exit status
# attached. The `cd` is load-bearing: the gate resolves its own root as
# getwd(), and system2("Rscript", <path>) would leave the working directory at
# the caller's, so every case would run against the real repository and every
# plant would go undetected while every near-miss passed vacuously. That is
# recorded as having happened once already.
scn_gate_output <- function(dir) {
  out <- suppressWarnings(system2(
    "sh", c("-c", shQuote(sprintf("cd %s && Rscript tests/ci_science_nightly.R 2>&1",
                                  shQuote(dir)))),
    stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

# Replaces whole files in a fresh scaffold and runs the gate.
scn_with_planted <- function(edits) {
  dir <- file.path(tempdir(), paste0("scn_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scn_scaffold(dir)
  for (nm in names(edits)) writeLines(edits[[nm]], file.path(dir, nm))
  system2("git", c("-C", shQuote(dir), "add", "-A"), stdout = FALSE, stderr = FALSE)
  scn_gate_output(dir)
}

# A plant must fail the gate AND be attributed to the right gate.
scn_caught <- function(label, code, edits) {
  r <- scn_with_planted(edits)
  chk(r$failed && grepl(sprintf("%s:", code), r$text, fixed = TRUE),
      sprintf("%s: %s", code, label))
  if (!r$failed) cat("       gate passed; it did not notice\n")
  else if (!grepl(sprintf("%s:", code), r$text, fixed = TRUE))
    cat(sprintf("       gate failed but not as %s -- another gate took the hit\n", code))
}

# A near miss must leave the gate green.
scn_allowed <- function(label, edits) {
  r <- scn_with_planted(edits)
  chk(!r$failed, sprintf("near miss allowed: %s", label))
  if (r$failed) cat(paste0("       ", grep("^FAIL", strsplit(r$text, "\n")[[1]],
                                           value = TRUE), "\n"))
}

# -----------------------------------------------------------------------------
cat("\n-- the clean scaffold passes --\n")
# FIRST, and fatal. Every assertion below is meaningless if the baseline is red:
# a plant would "be caught" by whatever was already broken.
local({
  dir <- file.path(tempdir(), paste0("scn_clean_", as.integer(stats::runif(1) * 1e9)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  scn_scaffold(dir)
  r <- scn_gate_output(dir)
  chk(!r$failed, "an unperturbed scaffold produces no failures")
  if (r$failed) cat(r$text, "\n")
})

cat("\n-- one planted defect per gate --\n")

scn_caught("a percentage that stops following from n/N on the last row", "SCN1",
  list("artifacts/composition_demo.csv" = sub("^g3,d,20,200,10$", "g3,d,20,200,12",
       SCN_CLEAN[["artifacts/composition_demo.csv"]])))

scn_caught("a rate published as 0 where the denominator is 0", "SCN2",
  list("artifacts/rate_demo.csv" = sub("^u5,0,0,$", "u5,0,0,0",
       SCN_CLEAN[["artifacts/rate_demo.csv"]])))

# N raised to 600 with the percentages recomputed against it, so n/N still
# reproduces and ONLY the exhaustiveness rule is broken: the strata still sum
# to 500. A breakdown that quietly drops rows looks exactly like this.
scn_caught("strata that no longer sum to the denominator beside them", "SCN3",
  list("artifacts/composition_demo.csv" = c(
    "group,level,n,N,pct",
    "g1,a,400,1000,40", "g1,b,300,1000,30", "g1,c,200,1000,20", "g1,d,100,1000,10",
    "g2,a,200,600,33.333333333333336", "g2,b,150,600,25",
    "g2,c,100,600,16.666666666666668", "g2,d,50,600,8.333333333333334",
    "g3,a,80,200,40",   "g3,b,60,200,30",   "g3,c,40,200,20",   "g3,d,20,200,10",
    "g4,a,50,50,100")))

scn_caught("a 500-member group collapsed onto one level", "SCN4",
  list("artifacts/composition_demo.csv" = c(
    "group,level,n,N,pct",
    "g1,a,400,1000,40", "g1,b,300,1000,30", "g1,c,200,1000,20", "g1,d,100,1000,10",
    "g2,a,500,500,100",
    "g3,a,80,200,40",   "g3,b,60,200,30",   "g3,c,40,200,20",   "g3,d,20,200,10",
    "g4,a,50,50,100")))

scn_caught("an interval that does not reproduce from its own denominator", "SCN5",
  list("artifacts/interval_demo.csv" = sub("22.41526427373505", "20.0",
       SCN_CLEAN[["artifacts/interval_demo.csv"]], fixed = TRUE)))

scn_caught("an unresolved count that no longer completes its denominator", "SCN6",
  list("artifacts/ascertainment_demo.csv" = sub("^st1,1000,600,400,60$",
       "st1,1000,600,300,60", SCN_CLEAN[["artifacts/ascertainment_demo.csv"]])))

scn_caught("a flow ledger removing more than the cohort held", "SCN7",
  list("artifacts/cohort_flow_1000_to_900.csv" = c(
    "reason,n", "withdrawn,900", "reassigned,300")))

# The other half of SCN7: arithmetic that is individually possible but leaves
# people unaccounted -- 950 survive the removals and the cohort ends at 900.
scn_caught("a flow ledger whose survivors exceed the destination cohort", "SCN7",
  list("artifacts/cohort_flow_1000_to_900.csv" = c(
    "reason,n", "withdrawn,40", "reassigned,10")))

cat("\n-- near misses that must stay green --\n")

# Pinned because the first draft of SCN5 held every interval to Wilson at
# z = 1.96 with no tolerance and would have failed anyone using qnorm(0.975).
scn_allowed("an interval computed with qnorm(0.975) rather than 1.96",
  list("artifacts/interval_demo.csv" = c(
    "stratum,n,n_hit,pct,ci_low,ci_high",
    "s1,1000,250,25.0,22.41530989836914,27.776028025908616",
    "s2,120,90,75.0,66.55886333587439,81.89017834319043",
    "s3,60,45,75.0,62.767929922952185,84.22347746994333")))

# Pinned because a percentage nobody can reproduce is the COMMON case -- a
# county rate against an ACS denominator that is not in the file. Requiring
# reproduction outright flagged 33 columns, and the great majority were right.
scn_allowed("a percentage whose denominator is upstream and absent",
  list("artifacts/upstream_demo.csv" = c(
    "unit,population,pct_uninsured",
    "u1,52341,12.7", "u2,18902,9.4", "u3,7734,15.1",
    "u4,240118,8.8", "u5,3312,21.6", "u6,99999,4.2")))

# Pinned because zero divides by anything: a column that is mostly zero will
# appear to be explained by any pair of unrelated counts, and an early draft
# "reproduced" 735 rows of a county file through study_midwives / sum(ahrf_cah).
scn_allowed("a mostly-zero percentage that no real pair explains",
  list("artifacts/upstream_demo.csv" = c(
    "unit,population,other,pct_share",
    "u1,52341,17,0", "u2,18902,4,0", "u3,7734,9,0",
    "u4,240118,31,0", "u5,3312,2,0", "u6,881,1,13.7")))

# Pinned because demanding a partition from a summary of overlapping indicators
# is the false positive that reached the first green run of this gate.
scn_allowed("an unresolved count in a summary that publishes no percentage",
  list("artifacts/indicator_demo.csv" = c(
    "built_at,cohort_n,with_hospital,hospitals_linked,ccn_unresolved,any_critical,multi_hospital",
    "2026-08-11T08:54:40,11920,1665,902,4,138,230")))

# Pinned because SCN4's floor is what separates a failed join from a small
# stratum that really is uniform.
scn_allowed("a 50-member group legitimately sitting in one level",
  list("artifacts/composition_demo.csv" = c(
    "group,level,n,N,pct",
    "g1,a,400,1000,40", "g1,b,300,1000,30", "g1,c,200,1000,20", "g1,d,100,1000,10",
    "g2,a,200,500,40",  "g2,b,150,500,30",  "g2,c,100,500,20",  "g2,d,50,500,10",
    "g3,a,80,200,40",   "g3,b,60,200,30",   "g3,c,40,200,20",   "g3,d,20,200,10",
    "g4,a,50,50,100",   "g5,b,40,40,100")))

# -----------------------------------------------------------------------------
cat("\n")
if (length(failures)) {
  cat(sprintf("FAILED (%d)\n", length(failures)))
  for (f in failures) cat(sprintf("  - %s\n", f))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
