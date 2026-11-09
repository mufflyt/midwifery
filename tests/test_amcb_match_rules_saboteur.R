#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: R/amcb_match_rules.R
# =============================================================================
# tests/test_amcb_gates.R already runs 66 assertions across G3/G4/G6/G7/G8,
# covering every function here at the two-claimant case. These tests target
# what a two-person fixture structurally cannot show: a THREE-way contest on
# one NPI, and a quiet permissiveness in count_rival_npis() that a two-person
# fixture never exercises either.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "amcb_match_rules.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- amcb_award_contested(): a THREE-way contest, not just two --\n")
{
  # Three certificants claim one NPI. A and B tie at the strongest priority;
  # C is strictly weaker. strict_dominance's own code only ever compares the
  # TOP TWO rows after sorting (`key[ix[1]] != key[ix[2]]`) -- correct
  # because a tie between the top two means nobody dominates REGARDLESS of
  # how many weaker rivals also exist, but that is exactly the kind of
  # "only checked pairwise" logic that silently breaks on three-plus-way
  # contests if ever generalised carelessly. Exercise it directly.
  q <- data.frame(
    enthealth_id = c("A", "B", "C"), npi = c("999", "999", "999"),
    resolution_status = "ambiguous_contested_npi",
    method_priority = c(1L, 1L, 2L), score_total_adj = c(5, 5, 3),
    confidence_score = c(0.9, 0.9, 0.5), stringsAsFactors = FALSE)

  # T1. strict_dominance: A and B's genuine tie means NEITHER wins, even
  # though a strictly-weaker third claimant (C) also exists.
  won1 <- amcb_award_contested(q, rule = "strict_dominance")
  chk(nrow(won1) == 0L,
      sprintf("T1 a genuine top-two tie in a three-way contest awards NOTHING under strict_dominance, despite a weaker third claimant [%d awarded]",
              nrow(won1)))

  # T2. greedy: the same three-way contest DOES award, to whichever of the
  # tied leaders sorts first -- the exact behaviour the file's own header
  # names as a known, non-default weakness ("decide identities on sort
  # order"), not a default-path mistake.
  won2 <- amcb_award_contested(q, rule = "greedy")
  chk(nrow(won2) == 1L && won2$enthealth_id[1] == "A",
      sprintf("T2 the same three-way contest DOES award under greedy, to the sort-first tied leader [%s, n=%d]",
              paste(won2$enthealth_id, collapse = ","), nrow(won2)))

  # T3. A genuine strict winner survives a three-way contest exactly as it
  # would a two-way one -- adding a third, even-weaker rival must not
  # change the outcome for a real dominance case.
  q2 <- q; q2$method_priority <- c(1L, 2L, 3L)  # A now strictly dominates both
  won3 <- amcb_award_contested(q2, rule = "strict_dominance")
  chk(nrow(won3) == 1L && won3$enthealth_id[1] == "A",
      "T3 a genuine strict dominance winner is unaffected by a second, even-weaker rival")
}

cat("\n-- count_rival_npis(): permissiveness a two-person fixture never shows --\n")
{
  # T4. Positive control, matching the documented rule directly: a person
  # who matched NOTHING (npi NA) has every one of their vetoed candidates
  # counted as a rival, not zero.
  vet <- data.frame(amcb_id = c("X", "X"), vetoed_npi = c("111", "222"),
                    stringsAsFactors = FALSE)
  matched <- data.frame(amcb_id = "X", npi = NA_character_, stringsAsFactors = FALSE)
  got4 <- count_rival_npis(vet, matched)
  chk(got4$n_rival_npis[got4$amcb_id == "X"] == 2L,
      "T4 a person who matched nothing counts every vetoed candidate as a rival (documented rule)")

  # T5. CONFIRMED FINDING: a person present in vetoed_pairs but ENTIRELY
  # ABSENT from matched (not merely npi=NA there, but no row at all) is
  # silently treated the same as "matched nothing" via the left join's NA
  # fill -- count_rival_npis() cannot distinguish "we determined this person
  # matched nothing" from "we forgot to pass this person's row". Both
  # function arguments are documented as covering the same population; a
  # caller who accidentally subsets `matched` before calling this would get
  # no error, just a silently-inflated rival count for whoever fell out.
  vet5  <- data.frame(amcb_id = "Y", vetoed_npi = "333", stringsAsFactors = FALSE)
  matched5 <- data.frame(amcb_id = character(0), npi = character(0),
                         stringsAsFactors = FALSE)
  got5 <- count_rival_npis(vet5, matched5)
  chk(nrow(got5) == 1L && got5$n_rival_npis[1] == 1L,
      sprintf("T5 CONFIRMED GAP: a person absent from `matched` entirely is treated identically to one who matched nothing [n_rival_npis=%s] -- no error, no distinguishing flag",
              if (nrow(got5)) got5$n_rival_npis[1] else "none"))
}

cat("\n-- require_cols() / assert_nonempty_selection(): the boundary helpers --\n")
{
  # T6. require_cols() on something that is not a data frame at all must
  # name that fact specifically, not fail with a generic subscript error
  # several calls downstream.
  got6 <- tryCatch(require_cols(list(amcb_id = 1), "amcb_id"), error = function(e) conditionMessage(e))
  chk(grepl("not a data frame", got6),
      sprintf("T6 require_cols() on a non-data-frame input names that specifically [%s]", got6))

  # T7. assert_nonempty_selection() must treat NULL the same as a
  # zero-length vector (both have length 0), not let NULL silently skip the
  # check via a different code path.
  got7 <- tryCatch(assert_nonempty_selection(NULL, "file selector"), error = function(e) conditionMessage(e))
  chk(grepl("selected NOTHING", got7),
      sprintf("T7 assert_nonempty_selection(NULL, ...) is caught the same as character(0) [%s]", got7))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
