#!/usr/bin/env Rscript
# =============================================================================
# oig_phase2_candidate_set.R -- tests
# =============================================================================
# Covers the pure functions oig_phase2_candidate_set_and_intersection_
# analysis.R depends on: the union-based candidate-set fix (no longer a
# tier-priority pick that drops group ZIPs), the 6-bucket three-way
# intersection classifier (source-unavailable must never read as
# disagreement), and the sequential-resolution transition classifier
# (never counts a zero-to-new-candidate as PECOS recovery).
#
# Run: Rscript tests/test_oig_phase2_candidate_set_analysis.R  (exit 1 on fail)
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "oig_phase2_candidate_set.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("-- union_zip5_sets() [spec regression 1, 2, 6: union not priority-pick] --\n")
chk(
  identical(union_zip5_sets(c("80202"), c("80202", "10001")), c("10001", "80202")),
  "direct + group ZIP5s union together, not priority-picked (core bug fix)"
)
chk(
  identical(union_zip5_sets(character(0), c("10001")), "10001"),
  "direct-only clinician: group empty, union keeps the direct ZIP"
)
chk(
  identical(union_zip5_sets(c("10001", NA), c(NA_character_)), "10001"),
  "NA entries dropped from the union, never treated as a candidate ZIP5"
)
chk(
  identical(union_zip5_sets(c("10001", "10001"), c("10001")), "10001"),
  "two orgs/clinics sharing one ZIP5 still collapse to one candidate (regression 3, 4)"
)

cat("-- classify_intersection_cardinality() [spec 5.2 six buckets] --\n")
chk(
  classify_intersection_cardinality(character(0), "10001", "10001") == "source_unavailable",
  "no PECOS candidate ZIP5 -> source_unavailable, never no_common_zip5 (regression 7)"
)
chk(
  classify_intersection_cardinality("10001", character(0), "10001") == "source_unavailable",
  "missing NPPES observation -> source_unavailable (regression 8)"
)
chk(
  classify_intersection_cardinality("10001", "10001", character(0)) == "source_unavailable",
  "missing Physician Compare observation -> source_unavailable (regression 9)"
)
chk(
  classify_intersection_cardinality("10001", "10001", "10001") == "exactly_one",
  "exact three-way agreement on one ZIP5 -> exactly_one (regression 10)"
)
chk(
  classify_intersection_cardinality(c("10001", "10002"), c("10001", "10002"), c("10001", "10002")) == "two",
  "three-way agreement on two ZIP5s -> two, never collapsed to exactly_one (regression 11)"
)
chk(
  classify_intersection_cardinality(
    c("10001", "10002", "10003"), c("10001", "10002", "10003"), c("10001", "10002", "10003")
  ) == "three_to_five",
  "three-way agreement on three ZIP5s -> three_to_five"
)
chk(
  classify_intersection_cardinality(
    paste0("1000", 1:7), paste0("1000", 1:7), paste0("1000", 1:7)
  ) == "more_than_five",
  "three-way agreement on seven ZIP5s -> more_than_five (regression 18, large multi-site group)"
)
chk(
  classify_intersection_cardinality(c("10001", "10002"), "90210", "90210") == "no_common_zip5",
  "all three sources observed but share nothing -> no_common_zip5, not source_unavailable"
)
chk(
  classify_intersection_cardinality(
    paste0("1000", 1:23), "10099", character(0)
  ) == "source_unavailable",
  "large PECOS candidate set (Tier 4, 23 ZIP5s) with PC unavailable is still source_unavailable, never chance-matched as agreement"
)

cat("-- classify_intersection_cardinality() pairwise (variadic) use --\n")
chk(
  classify_intersection_cardinality(paste0("1000", 1:7), c("10003", "10005")) == "two",
  "pairwise intersection (no NPPES singleton involved) can legitimately land on 'two'"
)
chk(
  classify_intersection_cardinality("10001", "10001", "10001") == classify_intersection_cardinality("10001", "10001", "10001"),
  "3-arg call still works after generalizing to variadic ... (backward compatible)"
)

cat("-- classify_sequential_transition() [spec 5.3 five named buckets] --\n")
chk(
  classify_sequential_transition(character(0), c("10001")) == "zero_to_new_candidate",
  "Tier 6 (no PECOS candidate) gaining an NPPES ZIP -> zero_to_new_candidate, never PECOS recovery"
)
chk(
  classify_sequential_transition(c("10001"), character(0)) == "source_unavailable_no_change",
  "adding a source with no observation leaves the candidate set unchanged"
)
chk(
  classify_sequential_transition(paste0("1000", 1:7), "10003") == "multiple_to_one",
  "large multi-site group narrowed to one candidate by a second source -> multiple_to_one"
)
chk(
  classify_sequential_transition(paste0("1000", 1:7), c("10001", "10002", "10003")) == "multiple_to_fewer_still_multiple",
  "multi-site group narrowed but still ambiguous -> multiple_to_fewer_still_multiple"
)
chk(
  classify_sequential_transition(c("10001", "10002"), c("10001", "10002")) == "multiple_no_narrowing",
  "new source agrees with every existing candidate -> no narrowing, not silently dropped"
)
chk(
  classify_sequential_transition(c("10001", "10002"), c("90210")) == "multiple_to_disagreement",
  "new source disagrees with every existing candidate -> multiple_to_disagreement"
)
chk(
  classify_sequential_transition(c("10001"), c("10001")) == "one_to_agreement",
  "single candidate confirmed by the new source -> one_to_agreement"
)
chk(
  classify_sequential_transition(c("10001"), c("90210")) == "one_to_disagreement",
  "single candidate contradicted by the new source -> one_to_disagreement"
)
chk(
  classify_sequential_transition(character(0), character(0)) == "still_zero",
  "no candidate and no new observation -> still_zero, not dropped from the table"
)

cat("-- classify_zip5_count_bucket() --\n")
chk(
  identical(classify_zip5_count_bucket(c(0L, 1L, 5L, NA_integer_)), c("zero", "single_zip5", "multiple_zip5", "zero")),
  "zero/single/multiple buckets, NA treated as zero (no linked location)"
)

cat("-- assert_one_row_per_id() [no silent arbitrary-row .keep_all pick] --\n")
clean_df <- data.frame(npi = c("1", "2", "3"), v = c("a", "b", "c"))
chk(
  identical(assert_one_row_per_id(clean_df, "npi", "ctx"), clean_df),
  "no duplicates -> returns data unchanged"
)
dup_df <- data.frame(npi = c("1", "1", "2"), v = c("a", "b", "c"))
chk(
  inherits(tryCatch(assert_one_row_per_id(dup_df, "npi", "ctx"), error = function(e) e), "error"),
  "a duplicated id errors loudly instead of silently picking the first row"
)

cat("\n")
if (fails == 0L) {
  cat("ALL PASS\n")
} else {
  cat(sprintf("%d FAILED\n", fails))
  quit(status = 1L, save = "no")
}
