#!/usr/bin/env Rscript
# =============================================================================
# AMCB -> NPI crosswalk: auditable counts, A/B diff, and stratified review draw
# =============================================================================
#
# Three jobs, deliberately in one place so the numbers a reader is shown and
# the rows a reviewer is asked to check come from the SAME artifact in the same
# pass. Reporting counts from one run and sampling from another is how a
# review ends up validating a file nobody published.
#
#   1. The counts required to audit the linkage (total, unique people, exact,
#      high-confidence non-exact, ambiguous, unmatched, multi-NPI, and matches
#      rejected on taxonomy/credential evidence).
#   2. A row-level diff against the previous crosswalk, so the effect of the
#      transliteration fix is stated as movement between tiers rather than as
#      two yield numbers that happen to differ.
#   3. A stratified sample for manual review -- 25 exact, 25 high-confidence
#      fuzzy, 25 ambiguous, 25 unmatched -- drawn under a FIXED seed so the
#      draw is reproducible and cannot be re-rolled until it looks good.
#
# Run: Rscript audit_amcb_crosswalk.R
#   CROSSWALK_IN  crosswalk to audit  (default: the current c5guard crosswalk)
#   CROSSWALK_REF baseline to diff    (default artifacts/amcb_npi_linkage_FROZEN.csv)
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}
setwd(root_dir)

# Name carries panel definition and year window, per the matcher's contract.
# STALE DEFAULT (2026-08-10). This pointed at the translit crosswalk, which two
# later builds superseded. The identical defect was fixed in
# enrich_amcb_crosswalk_geography.R the same afternoon and NOT fixed here --
# one sibling patched, the other left. A default is the path most runs take,
# so a stale one silently audits a linkage nobody uses.
XW  <- Sys.getenv(
  "CROSSWALK_IN",
  "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv")
REF <- Sys.getenv("CROSSWALK_REF", "artifacts/amcb_npi_linkage_FROZEN.csv")
OUT_DIR <- "artifacts"
stopifnot(file.exists(XW))

# DIFF AND SAMPLE FILENAMES MUST ENCODE WHAT THEY DESCRIBE (2026-08-10).
# Writing a fixed "amcb_crosswalk_diff_vs_baseline.csv" repeated the defect
# this repo has now hit three times: the accent run diffed against FROZEN, the
# component run diffed against the accent crosswalk, and the second silently
# replaced the first under a name that claims to describe neither. The stem
# derives from BOTH inputs, so two A/B arms cannot collide.
stem <- function(p) sub("\\.csv$", "", sub("^amcb_npi_crosswalk_", "", basename(p)))
short <- function(p) sub("_panel-.*$", "", stem(p))
DIFF_OUT <- file.path(OUT_DIR, sprintf("amcb_crosswalk_diff_%s_vs_%s.csv",
                                       short(XW), short(REF)))
SAMP_OUT <- file.path(OUT_DIR, sprintf("amcb_crosswalk_review_sample_%s.csv",
                                       short(XW)))

cc <- cols(.default = "c")
x <- read_csv(XW, col_types = cc)
n <- nrow(x)
num <- function(v) suppressWarnings(as.numeric(v))
fmt <- function(k) format(k, big.mark = ",")
line <- function(lab, k) cat(sprintf("  %-46s %8s  (%5.1f%%)\n", lab, fmt(k), 100 * k / n))

matched <- !is.na(x$npi) & nzchar(x$npi)

cat("\n================ AUDITABLE COUNTS ================\n")
cat(sprintf("artifact: %s\n\n", XW))
line("total AMCB records", n)
line("unique AMCB customer ids", n_distinct(x$amcb_customer_id))
line("unique normalized (last, first, middle) names",
     nrow(distinct(x, normalized_last_name, normalized_first_name,
                   normalized_middle_name)))
line("unique normalized (last, first) names",
     nrow(distinct(x, normalized_last_name, normalized_first_name)))

cat("\n-- outcome, mutually exclusive --\n")
# Exact = evidence class 1 or 2 (exact first AND last); class 1 additionally
# has a corroborating middle initial. "High-confidence non-exact" is class 3,
# exact surname plus first initial. Class 4 is fuzzy surname and is reported
# separately because it is sensitivity-only evidence, never primary.
ec <- num(x$name_evidence_class)
line("exact unique matches (class 1: +middle initial)", sum(matched & ec == 1, na.rm = TRUE))
line("exact unique matches (class 2: no middle info)",  sum(matched & ec == 2, na.rm = TRUE))
line("high-confidence non-exact (class 3: first initial)", sum(matched & ec == 3, na.rm = TRUE))
line("fuzzy surname (class 4, sensitivity only)",       sum(matched & ec == 4, na.rm = TRUE))
line("surname component (class 5, sensitivity only)",  sum(matched & ec == 5, na.rm = TRUE))
line("ambiguous (candidates existed, none resolved)",
     sum(grepl("^ambiguous", x$npi_match_status)))
line("unmatched (no candidate at all)", sum(x$npi_match_status == "unmatched"))
stopifnot(sum(matched) + sum(grepl("^ambiguous", x$npi_match_status)) +
            sum(x$npi_match_status == "unmatched") == n)

cat("\n-- ambiguity detail --\n")
line("tied on name evidence", sum(x$ambiguity_flag == "tied_on_name_evidence"))
line("lost bijection to a stronger claim",
     sum(x$ambiguity_flag == "lost_bijection_to_stronger_claim"))
line("resolved, but candidate pool was not unique",
     sum(x$ambiguity_flag == "resolved_but_pool_not_unique"))

cat("\n-- multiple-NPI exposure --\n")
# "Multiple-NPI match" has two distinct meanings and both are reported: a
# person with several plausible NPIs, and an NPI claimed by several people.
line("people with >1 plausible candidate NPI", sum(num(x$candidate_count) > 1, na.rm = TRUE))
line("matched people whose pool held >1 NPI",
     sum(matched & num(x$candidate_count) > 1, na.rm = TRUE))
dupe_npi <- x %>% filter(matched) %>% count(npi) %>% filter(n > 1)
cat(sprintf("  %-46s %8s\n", "NPIs assigned to >1 AMCB row (must be 0)", fmt(nrow(dupe_npi))))
stopifnot(nrow(dupe_npi) == 0L)

cat("\n-- taxonomy / credential evidence --\n")
# Nothing is DISCARDED on taxonomy: a nursing-taxonomy match is downgraded to
# a sensitivity stratum, not deleted. Reporting it as "rejected" would overstate
# the filter; reporting nothing would hide it. Both counts are given.
line("matched on a midwifery taxonomy NPI", sum(matched & x$npi_tax_class == "midwife", na.rm = TRUE))
line("matched only on a nursing taxonomy NPI (downgraded)",
     sum(matched & x$npi_tax_class == "nursing", na.rm = TRUE))
line("people whose ONLY candidates were nursing taxonomy",
     sum(num(x$n_midwifery_candidates) == 0 & num(x$n_nursing_only_candidates) > 0, na.rm = TRUE))
cat(sprintf("  %-46s %8s\n", "candidates vetoed by middle-initial conflict",
            "see linkage_candidate_audit.csv"))

cat("\n-- linkage tier --\n")
print(as.data.frame(x %>% count(linkage_tier) %>%
                      mutate(pct = round(100 * n / nrow(x), 1)) %>% arrange(desc(n))))

# --- A/B diff against the baseline -------------------------------------------
if (file.exists(REF)) {
  r <- read_csv(REF, col_types = cc)
  cat(sprintf("\n================ DIFF vs %s ================\n", basename(REF)))
  j <- x %>% select(amcb_id, npi_new = npi, tier_new = linkage_tier) %>%
    full_join(r %>% select(amcb_id, npi_old = npi, tier_old = linkage_tier),
              by = "amcb_id")
  cat(sprintf("rows: %s new, %s baseline, %s joined\n",
              fmt(nrow(x)), fmt(nrow(r)), fmt(nrow(j))))

  same_npi <- (is.na(j$npi_new) & is.na(j$npi_old)) |
    (!is.na(j$npi_new) & !is.na(j$npi_old) & j$npi_new == j$npi_old)
  cat(sprintf("\nNPI assignment unchanged : %s\n", fmt(sum(same_npi, na.rm = TRUE))))
  cat(sprintf("newly matched            : %s\n", fmt(sum(is.na(j$npi_old) & !is.na(j$npi_new)))))
  cat(sprintf("lost a match             : %s\n", fmt(sum(!is.na(j$npi_old) & is.na(j$npi_new)))))
  cat(sprintf("REASSIGNED to a different NPI: %s   <- the number that matters most\n",
              fmt(sum(!is.na(j$npi_old) & !is.na(j$npi_new) & j$npi_new != j$npi_old))))

  cat("\ntier movement (baseline -> new), changes only:\n")
  mv <- j %>% filter(tier_old != tier_new) %>% count(tier_old, tier_new, sort = TRUE)
  print(as.data.frame(mv))
  if (!nrow(mv)) cat("  (none)\n")

  changed <- j %>% filter(!same_npi | tier_old != tier_new)
  write_csv(changed, DIFF_OUT, na = "")
  cat(sprintf("\nrow-level diff written: %s (%s rows)\n", DIFF_OUT, fmt(nrow(changed))))

  # The accent cohort specifically: this is the population the fix targeted, so
  # its movement is the direct test of whether the fix did what was claimed.
  nonascii <- function(v) !is.na(v) & grepl("[^\\x01-\\x7F]", v, perl = TRUE)
  acc_ids <- x$amcb_id[nonascii(x$last_name) | nonascii(x$first_name) |
                         nonascii(x$middle_name)]
  ja <- j %>% filter(amcb_id %in% acc_ids)
  cat(sprintf("\n-- the %d roster rows with non-ASCII names --\n", length(acc_ids)))
  print(as.data.frame(ja %>% count(tier_old, tier_new, sort = TRUE)))

  # THE DIRECT TEST OF THE COMPONENT STRATEGY. The gap it targets was stated as
  # a RATE DIFFERENCE -- 27.1% unmatched for hyphenated surnames against 9.8%
  # for unhyphenated -- so the fix has to be judged on whether that gap closed,
  # not on how many extra matches appeared. A strategy that raised both rates
  # equally would have bought nothing.
  hy <- x %>%
    transmute(amcb_id, hyph = grepl("-", normalized_last_name),
              unm_new = npi_match_status == "unmatched") %>%
    left_join(r %>% transmute(amcb_id, unm_old = npi_match_status == "unmatched"),
              by = "amcb_id")
  cat("\n-- unmatched rate by compound surname, before -> after --\n")
  print(as.data.frame(hy %>% group_by(hyph) %>%
    summarise(n = n(),
              unmatched_before = sum(unm_old, na.rm = TRUE),
              pct_before = round(100 * mean(unm_old, na.rm = TRUE), 1),
              unmatched_after = sum(unm_new),
              pct_after = round(100 * mean(unm_new), 1), .groups = "drop")))
  gb <- with(hy, mean(unm_old[hyph], na.rm = TRUE) - mean(unm_old[!hyph], na.rm = TRUE))
  ga <- with(hy, mean(unm_new[hyph]) - mean(unm_new[!hyph]))
  cat(sprintf("compound-surname penalty: %+.1f pp before -> %+.1f pp after (%s)\n",
              100 * gb, 100 * ga,
              if (abs(ga) < abs(gb)) "narrowed" else "NOT narrowed"))
} else {
  cat(sprintf("\n[skip] baseline %s not found\n", REF))
}

# --- Stratified sample for manual review -------------------------------------
# Fixed seed: a review draw that changes every run is not a review, and cannot
# be re-checked by anyone else.
set.seed(20260810)
take <- function(df, k, stratum) {
  if (!nrow(df)) return(NULL)
  df %>% slice_sample(n = min(k, nrow(df))) %>% mutate(review_stratum = stratum)
}
cols_keep <- intersect(
  c("amcb_customer_id", "amcb_id", "amcb_name_original", "certification", "status",
    "normalized_first_name", "normalized_middle_name", "normalized_last_name",
    "npi", "nppes_matched_first", "nppes_matched_last",
    "nppes_first_name", "nppes_middle_name", "nppes_last_name",
    "nppes_name_changed_since_match",
    "nppes_credential", "nppes_city", "nppes_state", "nppes_location_year",
    "name_evidence_class", "npi_match_method", "npi_match_confidence",
    "npi_tax_class", "candidate_count", "n_at_best_class", "linkage_tier",
    "ambiguity_flag", "match_reason"), names(x))
xs <- x %>% select(all_of(cols_keep))
ecs <- num(x$name_evidence_class)

sample_out <- bind_rows(
  take(xs[matched & ecs %in% c(1, 2) & !is.na(ecs), ], 25, "exact"),
  take(xs[matched & ecs %in% c(3, 4) & !is.na(ecs), ], 25, "high_confidence_non_exact"),
  take(xs[grepl("^ambiguous", x$npi_match_status) | (num(x$candidate_count) > 1 & matched), ],
       25, "ambiguous_or_multiple_candidate"),
  take(xs[x$npi_match_status == "unmatched", ], 25, "unmatched")) %>%
  mutate(reviewer_verdict = "", reviewer_notes = "")

samp_path <- SAMP_OUT
write_csv(sample_out, samp_path, na = "")
cat(sprintf("\nstratified review sample: %s (%s rows, seed 20260810)\n",
            samp_path, fmt(nrow(sample_out))))
print(as.data.frame(count(sample_out, review_stratum)))
cat("\nreviewer_verdict / reviewer_notes are intentionally BLANK: the sample is\n")
cat("not evidence until a human fills them in.\n")
