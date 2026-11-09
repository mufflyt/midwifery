#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: R/amcb_cohort_membership.R
# =============================================================================
# This file is the smallest of the four in the name-matching/identity family
# and already has solid coverage via tests/test_adversarial_identity_
# resolution.R's B3/B4 sections and test_amcb_gates.R's G5. These tests probe
# what those don't: the explicit length-mismatch guard (which is a genuine
# improvement over amcb_resolver.R's unguarded equivalent -- see
# tests/test_amcb_resolver_saboteur_paths.R S4), and a real crash found by
# direct probing in cohort_membership_summary() on an empty data frame.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "amcb_cohort_membership.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- is_cohort_member(): length guard and fail-closed on absence --\n")
{
  # T1. Unlike amcb_linkage_tier() (see the saboteur suite's S4), this
  # function EXPLICITLY stops on mismatched argument lengths rather than
  # letting R recycle silently. Confirms the guard actually fires.
  got <- tryCatch(is_cohort_member(c("1", "2", "3"), c("primary_midwifery", "primary_midwifery")),
                  error = function(e) conditionMessage(e))
  chk(is.character(got) && grepl("differ in length", got),
      sprintf("T1 mismatched npi/linkage_tier lengths stop loudly, not recycle [%s]", got))

  # T2. A missing (NA) linkage tier must never read as eligible, however the
  # NPI looks.
  chk(identical(is_cohort_member("1000000001", NA_character_), FALSE),
      "T2 an NA linkage_tier is never membership, even with a present NPI")

  # T3. A present NPI in a tier that simply isn't in the allowlist (e.g. a
  # typo'd or future tier name) must fail closed, not open.
  chk(identical(is_cohort_member("1000000001", "some_future_tier_nobody_allowlisted"), FALSE),
      "T3 an unrecognised tier name fails closed (not a member), not open")

  # T4. The one case this whole file exists to make explicit: a present NPI
  # in a quarantined/unmatched tier is a CANDIDATE, not a member.
  chk(identical(is_cohort_member("1000000001", "quarantined"), FALSE) &&
      identical(is_cohort_member("1000000001", "unmatched"), FALSE),
      "T4 having an NPI in a non-allowlisted tier is NOT membership -- the file's entire point")
}

cat("\n-- cohort_membership_summary(): a real crash, found and fixed --\n")
{
  # T5. FIXED (was a confirmed crash). An empty input data frame used to
  # crash this function with an unrelated-looking error ("'names' attribute
  # [2] must be the same length as the vector [1]") -- table() on a
  # zero-length factor returns a table whose as.data.frame() form drops the
  # "tier" column entirely, so `names(tab)[2] <- "n"` failed on a 1-column
  # frame. This is a real, reachable shape (an upstream filter that
  # legitimately produces zero resolved rows, e.g. everyone in a run was
  # quarantined), so the function now short-circuits to a clean "0 of 0"
  # result with the expected schema instead of reaching the table() path.
  empty_df <- data.frame(npi = character(0), linkage_tier = character(0))
  got5 <- tryCatch(cohort_membership_summary(empty_df), error = function(e) conditionMessage(e))
  chk(is.list(got5) && is.data.frame(got5$summary) && nrow(got5$summary) == 0L &&
      identical(names(got5$summary), c("tier", "n", "eligible_tier", "n_members", "n_candidates_excluded")) &&
      got5$n_members == 0L && got5$n_with_npi == 0L && got5$n_candidates_not_members == 0L,
      "T5 FIXED: an empty input data frame now returns a clean 0-row summary with the correct schema, not a crash")

  # T6. Positive control: a non-empty, entirely-ineligible frame reports
  # correctly (0 members, everyone counted as excluded, not silently
  # dropped). Contrasts with T5 -- the function works fine as soon as there
  # is at least one row.
  df6 <- data.frame(npi = c("1", "2"), linkage_tier = c("quarantined", "quarantined"))
  res6 <- cohort_membership_summary(df6)
  chk(res6$n_members == 0L && res6$n_with_npi == 2L &&
      res6$n_candidates_not_members == 2L,
      sprintf("T6 an all-ineligible, non-empty frame reports 0 members / 2 candidates excluded, not silently dropped [members=%d, with_npi=%d, excluded=%d]",
              res6$n_members, res6$n_with_npi, res6$n_candidates_not_members))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
