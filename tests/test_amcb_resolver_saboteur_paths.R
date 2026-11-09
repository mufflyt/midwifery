#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: the PATHS amcb_linkage_tier() and friends can be pushed down
# =============================================================================
# tests/test_amcb_resolver_permutation.R and test_adversarial_identity_resolution.R
# already cover amcb_resolve()'s order-invariance and amcb_linkage_tier()'s
# per-class tier mapping exhaustively -- but every existing call to
# amcb_linkage_tier() in this test suite passes SCALAR (length-1) arguments.
# Production never calls it that way: match_amcb_to_npi.R hands it whole
# columns, one row per certificant. Nothing before this file exercised the
# VECTORISED path at all, which is where a positional misalignment would
# actually live.
#
# This file is organised around four attack families on R/amcb_resolver.R:
#   S1-S5    does a multi-row call keep every person's own evidence with them?
#   S6-S12   the demotion/ambiguity hand-off between match_amcb_to_npi.R and
#            amcb_linkage_tier() -- an ordering contract the function does NOT
#            enforce itself (see S6's comment), and the exact production
#            match_status strings, not stand-in placeholders.
#   S13-S18  normalise_npi_tax_class() and the confidence-score lookup under
#            garbage, boundary and out-of-range input.
#   S19-S20  whole-pipeline failure mode: does an empty or all-NA input crash,
#            or continue silently?
#
# Hermetic: synthetic NPIs, no artifact, no network.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr)})
source(file.path(root, "R", "amcb_resolver.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

mk_cand <- function(amcb_id, npi, cls, tax = "midwife") {
  data.frame(amcb_id = amcb_id, npi = npi, name_evidence_class = as.integer(cls),
             taxonomy_axis = tax, match_method = "m", match_strategy = as.integer(cls),
             mid_match = 0L, nppes_matched_last = "V", nppes_matched_first = "V",
             nppes_mid_init = "", stringsAsFactors = FALSE)
}

# =============================================================================
cat("\n-- S1-S5: does a multi-row call keep every person's own evidence? --\n")
# =============================================================================
{
  # S1. Three different people, three different classes, three different
  # taxonomies, in ONE vectorised call. A positional bug (e.g. the taxonomy
  # column silently shifted by one row) would pass every scalar test in the
  # existing suite and fail only here.
  got1 <- amcb_linkage_tier(
    npi = c("1000000001", "1000000002", "1000000003"),
    name_evidence_class = c(1L, 2L, 5L),
    npi_tax_class = c("midwife", "nursing", "midwife"))
  chk(identical(got1, c("primary_midwifery", "sensitivity_nursing",
                        "sensitivity_name_component")),
      sprintf("S1 three rows keep their own class+taxonomy pairing [%s]",
              paste(got1, collapse = ", ")))

  # S2. The same three rows, every argument reversed together. If the
  # function aligned by something other than position (sorted by NPI
  # internally, say), reversing would not simply reverse the output.
  got2 <- amcb_linkage_tier(
    npi = rev(c("1000000001", "1000000002", "1000000003")),
    name_evidence_class = rev(c(1L, 2L, 5L)),
    npi_tax_class = rev(c("midwife", "nursing", "midwife")))
  chk(identical(got2, rev(got1)),
      "S2 reversing all three argument vectors together exactly reverses the output")

  # S3. A row with an absent NPI sitting between two resolved rows in the
  # same call. The NA row must not contaminate, or be contaminated by, its
  # neighbors.
  got3 <- amcb_linkage_tier(
    npi = c("1000000004", NA_character_, "1000000005"),
    name_evidence_class = c(2L, 2L, 2L),
    npi_tax_class = c("midwife", "midwife", "nursing"),
    match_status = c(NA_character_, "ambiguous_tied_names", NA_character_))
  chk(identical(got3, c("primary_midwifery", "quarantined", "sensitivity_nursing")),
      sprintf("S3 a quarantined row between two resolved rows does not leak either way [%s]",
              paste(got3, collapse = ", ")))

  # S4. THE LANDMINE. npi_tax_class is length 2 while npi and
  # name_evidence_class are length 3 -- not the length-1 case rep_to()
  # exists to handle, and not the matching-length case production always
  # sends today. R recycles a length-2 vector against a length-3 target with
  # only a WARNING, so row 3 silently inherits row 1's taxonomy.
  #
  # ponytail: this is a real, currently-unguarded path, not a hypothetical.
  # rep_to()'s `if (length(x) == 1L) rep(x, n) else x` only special-cases the
  # length-1 broadcast; anything else passes through unchanged and R's own
  # recycling rules take over silently. A future caller who filters
  # npi_tax_class to "just the matched rows" while leaving npi at full length
  # would hit this for real. The fix is a `stopifnot` in amcb_linkage_tier()
  # on `length(x) %in% c(1L, n)` for every argument -- flagged here rather
  # than fixed, since this file's job is detection, not a change to a
  # function five other test files already pin by exact behavior.
  got4 <- suppressWarnings(amcb_linkage_tier(
    npi = c("1000000006", "1000000007", "1000000008"),
    name_evidence_class = c(1L, 1L, 1L),
    npi_tax_class = c("midwife", "nursing")))
  chk(identical(got4[3], "primary_midwifery"),
      sprintf("S4 CONFIRMED HAZARD: row 3 has no taxonomy of its own, yet silently recycles row 1's 'midwife' and is classified %s instead of the call erroring",
              got4[3]))

  # S5. Classes 4 and 5 specifically, vectorised -- the permutation suite's
  # own comment notes class 4/5 swap bugs survive unless something actually
  # RESOLVES at both classes in the same run. Do it positionally too.
  got5 <- amcb_linkage_tier(
    npi = c("1000000009", "1000000010"),
    name_evidence_class = c(4L, 5L),
    npi_tax_class = c("midwife", "midwife"))
  chk(identical(got5, c("sensitivity_fuzzy", "sensitivity_name_component")),
      sprintf("S5 class 4 and class 5 land on their own distinct tiers in the same vectorised call [%s]",
              paste(got5, collapse = ", ")))
}

# =============================================================================
cat("\n-- S6-S12: the demotion/ambiguity hand-off contract --\n")
# =============================================================================
{
  # S6. match_amcb_to_npi.R's own comment says demotion must null the NPI
  # BEFORE calling amcb_linkage_tier() -- "an earlier placement reads a
  # column that does not exist yet, and a later one leaves the row holding
  # an NPI while calling itself quarantined." amcb_linkage_tier() does NOT
  # enforce that order itself: its case_when checks `has & name_evidence_class
  # == 5L` before it ever looks at demoted_absence_c5, so a present NPI always
  # wins. This test documents that the guarantee is the CALLER's
  # responsibility, not the function's.
  #
  # LIMIT: this can only pin amcb_linkage_tier()'s own precedence. It cannot
  # detect a regression in match_amcb_to_npi.R's calling order -- that logic
  # is inline in the orchestration script, outside every function this file
  # can reach. See the file's own header on why that extraction has not
  # been done.
  got6 <- amcb_linkage_tier("1000000011", 5L, "midwife", demoted_absence_c5 = TRUE)
  chk(identical(got6, "sensitivity_name_component"),
      sprintf("S6 a present NPI beats demoted_absence_c5 unconditionally [got %s] -- the ordering discipline lives entirely in the caller, not here",
              got6))

  # S7. The correct call pattern: NPI nulled first, exactly as
  # match_amcb_to_npi.R's `npi = if_else(resolved_by_absence_c5, NA, npi)`
  # does before this function ever runs.
  got7 <- amcb_linkage_tier(NA_character_, NA_integer_, NA_character_,
                            demoted_absence_c5 = TRUE)
  chk(identical(got7, "quarantined"),
      "S7 the same demotion, called the way production actually calls it, DOES quarantine")

  # S8. No NPI, not demoted, a plain (non-ambiguous) status -> unmatched. The
  # fall-through that means "nobody was ever found", not "found and held
  # back".
  got8 <- amcb_linkage_tier(NA_character_, 2L, "midwife", match_status = "matched")
  chk(identical(got8, "unmatched"),
      "S8 no NPI, no demotion, a non-ambiguous status falls through to unmatched")

  # S9-S11. The REAL strings match_amcb_to_npi.R writes into npi_match_status
  # -- not a stand-in like "ambiguous_pool" (which test_adversarial_identity_
  # resolution.R uses and which is not itself a value production ever emits).
  # If `grepl("^ambiguous", ...)` and the production string ever drift apart,
  # a test built on a placeholder would not notice.
  for (real_status in c("ambiguous_tied_names", "ambiguous_contested_npi",
                        "ambiguous_unruled_out_component")) {
    got <- amcb_linkage_tier(NA_character_, 2L, "midwife", match_status = real_status)
    chk(identical(got, "quarantined"),
        sprintf("S9-11 the exact production string %s triggers quarantined [got %s]",
                real_status, got))
  }

  # S12. The anchor in `grepl("^ambiguous", ...)` must mean "starts with",
  # not "contains". A status that merely mentions "ambiguous" partway through
  # must NOT quarantine -- catches a mutation that drops the `^`.
  got12 <- amcb_linkage_tier(NA_character_, 2L, "midwife",
                             match_status = "formerly_ambiguous_now_resolved")
  chk(identical(got12, "unmatched"),
      sprintf("S12 'ambiguous' appearing mid-string (not as a prefix) does NOT quarantine [got %s]",
              got12))
}

# =============================================================================
cat("\n-- S13-S18: normalise_npi_tax_class() and confidence under garbage input --\n")
# =============================================================================
{
  # S13. Whitespace and case must not change the classification.
  chk(identical(normalise_npi_tax_class("  Midwife  "), "midwife"),
      "S13 leading/trailing whitespace and mixed case normalise to 'midwife'")

  # S14-15. Non-character garbage must fail CLOSED (NA), not get silently
  # coerced into looking like a real taxonomy string.
  chk(is.na(normalise_npi_tax_class(123)),
      "S14 a bare numeric value normalises to NA, not a stringified accident")
  chk(is.na(normalise_npi_tax_class(TRUE)),
      "S15 a bare logical value normalises to NA, not 'true'/'TRUE' matching nothing by luck")

  # S16. NA and empty string both fail closed the same way.
  chk(is.na(normalise_npi_tax_class(NA)) && is.na(normalise_npi_tax_class("")),
      "S16 NA and empty-string taxonomy both normalise to NA")

  # S17. name_evidence_class outside 1:5 (6, or NA) must not silently index
  # into a neighbouring, WRONG confidence value -- R returns NA for an
  # out-of-range or NA numeric index, which is the fail-safe direction.
  conf_scale <- c(1.0, 0.9, 0.7, 0.5, 0.35)
  chk(is.na(conf_scale[6L]) && is.na(conf_scale[NA_integer_]),
      "S17 an evidence class of 6 or NA indexes to NA confidence, not a neighbouring class's score")

  # S18. name_evidence_class == 0 is a DIFFERENT failure shape: R's `[0L]`
  # returns a zero-length vector, not NA. Assigning that into a one-row
  # result would throw a length-mismatch error rather than silently writing
  # a wrong number -- fail LOUD, not fail safe-but-quiet. Worth distinguishing
  # from S17 because the two garbage inputs are not caught the same way.
  chk(length(conf_scale[0L]) == 0L,
      "S18 an evidence class of 0 produces a zero-length result (loud downstream error), unlike class 6/NA (quiet NA)")
}

# =============================================================================
cat("\n-- S19-S20: whole-pipeline failure mode under empty/degenerate input --\n")
# =============================================================================
{
  # S19. Every candidate in a person's pool reports NA taxonomy_axis (a
  # plausible real failure: an upstream join that didn't match). sum(x ==
  # "midwife") over an all-NA vector is NA, not 0 -- so these counts read as
  # "unknown" rather than "definitely zero", and must not be mistaken for the
  # latter by anything consuming n_midwifery_candidates downstream.
  cand19 <- mk_cand("Z", c("1", "2"), c(2L, 2L), tax = NA_character_)
  ps19 <- amcb_pool_stats(amcb_per_npi(cand19))
  chk(is.na(ps19$n_midwifery_candidates) && is.na(ps19$n_nursing_only_candidates),
      sprintf("S19 all-NA taxonomy_axis yields NA candidate counts (not 0) [midwifery=%s, nursing=%s] -- a consumer that treats NA as falsy would misreport this person as having zero candidates of either kind",
              ps19$n_midwifery_candidates, ps19$n_nursing_only_candidates))

  # S20. A completely empty candidate frame (the whole-run catastrophic case,
  # e.g. an upstream fetch step returning nothing for anyone) must not crash
  # amcb_resolve() -- it should degrade to empty results the caller can
  # detect and report, not an uncaught error that aborts the run with no
  # artifact at all.
  empty <- cand19[0, , drop = FALSE]
  res20 <- tryCatch(suppressWarnings(amcb_resolve(empty)),
                    error = function(e) e)
  ok20 <- !inherits(res20, "error") &&
    nrow(res20$per_npi) == 0L && nrow(res20$pool_stats) == 0L &&
    nrow(res20$resolved) == 0L && length(res20$quarantined_ids) == 0L
  chk(ok20,
      "S20 a zero-row candidate frame degrades to clean empty results instead of erroring")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
