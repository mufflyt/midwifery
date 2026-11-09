#!/usr/bin/env Rscript
# =============================================================================
# Freeze rule contract
# =============================================================================
# freeze_cohort.R reconstructs the producer of the frozen cohort, which had 77
# readers and no writer. Its rule was recovered from three agreeing sources (the
# manifest's wording, amcb_audit_c5guard.log's class counts, and the artifact
# itself) and it reproduces the existing freeze on 54/54 columns. These cases
# pin the rule so a future edit cannot move cohort membership quietly.
#
# The NA case is here because it was a REAL BUG in the reconstruction, not a
# hypothetical: 5,255 rows carry an empty evidence class, `NA == "5"` is NA, and
# ifelse(NA, a, b) returns NA -- which blanked npi_match_status on every one of
# them. It passed a first verification only because NA and "" compared equal.
# =============================================================================
fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}

# Load apply_freeze_rule() without running the script's body.
src <- readLines("freeze_cohort.R", warn = FALSE)
a <- grep("^apply_freeze_rule <- function", src)[1]
b <- grep("^\\}$", src); b <- b[b > a][1]
eval(parse(text = paste(src[a:b], collapse = "\n")), envir = globalenv())
# The constants come from the script too, so the test cannot drift from it by
# redefining them here.
for (cn in c("MEMBER_CLASSES", "HELD_OUT_CLASS", "HELD_OUT_STATUS")) {
  ln <- grep(sprintf("^%s +<-", cn), src, value = TRUE)[1]
  stopifnot(!is.na(ln)); eval(parse(text = ln), envir = globalenv())
}

x <- data.frame(
  certification_number = sprintf("C%02d", 1:7),
  name_evidence_class  = c("1", "2", "3", "4", "5", NA, "4"),
  npi                  = c("1111111111", "2222222222", "3333333333",
                           "4444444444", "5555555555", "", ""),
  npi_match_status     = c("matched", "matched", "matched",
                           "matched_nursing_taxonomy", "matched", "unmatched", "ambiguous_tied_names"),
  stringsAsFactors = FALSE)
r <- apply_freeze_rule(x)

chk(identical(r$cohort_member, c(TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE)),
    "classes 1-4 with an npi are members; class 5, blank class and npi-less are not")
chk(identical(r$npi[5], ""), "a class-5 npi is removed from the npi column")
chk(identical(r$class5_candidate_npi[5], "5555555555"),
    "and PRESERVED in class5_candidate_npi, so the decision stays reversible")
chk(identical(r$npi_match_status[5], HELD_OUT_STATUS),
    "a held-out row's status is restated, not left reading 'matched' with no npi")
chk(all(r$class5_candidate_npi[-5] == ""),
    "no other row gains a class-5 candidate")

# THE BUG. A blank evidence class must leave the row alone, not blank its status.
chk(identical(r$npi_match_status[6], "unmatched"),
    "a blank (NA) evidence class does NOT blank npi_match_status")
chk(identical(r$npi_match_status[7], "ambiguous_tied_names"),
    "nor does it disturb an ambiguous row's status")
chk(!any(is.na(r$npi_match_status)), "no status becomes NA")
chk(!any(is.na(r$npi)), "no npi becomes NA")
chk(!any(is.na(r$cohort_member)), "membership is never NA -- a person is in or out")

# A class-4 row with no npi is not a member: evidence class alone is not enough.
chk(identical(r$cohort_member[7], FALSE),
    "an evidence class without a resolved npi is not membership")

# Idempotence: freezing a frozen frame must not move anything.
r2 <- apply_freeze_rule(r)
chk(identical(r2$cohort_member, r$cohort_member) &&
    identical(r2$npi, r$npi) &&
    identical(r2$class5_candidate_npi, r$class5_candidate_npi),
    "applying the rule twice changes nothing (idempotent)")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
