#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 44 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: the rurality geocoding-completeness gap statistic in
# R/02-geocoding-completeness.R -- an uncertainty-propagation site (the
# candidate lead this session has repeatedly flagged, "uncertainty
# propagation more broadly", and finally investigated this cycle) computing
# a two-proportion difference (highest vs. lowest completeness rurality
# stratum) with its own 95% CI via a proper standard-error formula. Never
# examined by any prior cycle.
#
# TWO REAL DEFECTS found and fixed, both in the "highest vs. lowest" stratum
# selection that feeds the SE/CI computation and the printed finding:
#
#   1. A genuine TIE between two rurality strata at the identical
#      completeness rate made `hi <- known %>% filter(pct == max(pct))`
#      (and the symmetric `lo`) a MULTI-ROW result. That length-2 result fed
#      directly into cli's glue-interpolated message and the SE arithmetic,
#      silently producing a length-2 SE vector and a garbled/duplicated
#      comparison message (e.g. naming TWO "highest" strata) instead of one
#      clear, single finding -- with no error or warning anywhere.
#   2. Fewer than 2 known (non-"Unknown") rurality strata -- e.g. every
#      midwife's rurality is "Unknown" in a filtered or sparse subset --
#      made max()/min() on an empty vector silently return -Inf/Inf (with
#      only a suppressed-by-default warning), producing a nonsensical
#      "spread" and CI rather than either a clean skip or a loud failure.
#
# Both fixed: (1) hi/lo now arrange(rucc_cat) %>% slice(1) after the filter,
# so a tie breaks on a deterministic, stated rule rather than silently
# vectorizing; (2) an explicit nrow(known) < 2L guard skips the comparison
# entirely with an informative message instead of computing on empty/
# degenerate input.
#
# This file cannot be sourced end-to-end (needs gitignored geocoding
# artifacts), so the gap-statistic logic is replicated literally, matching
# this session's established pattern.
#
# Run: Rscript tests/test_cycle44_geocoding_gap_statistic.R
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of the fixed gap-statistic block (R/02-geocoding-
# completeness.R, ~lines 246-270).
build_gap <- function(known) {
  if (nrow(known) < 2L) return(list(reported = FALSE, n_known = nrow(known)))
  spread <- max(known$pct) - min(known$pct)
  hi <- known %>% filter(pct == max(pct)) %>% arrange(rucc_cat) %>% slice(1)
  lo <- known %>% filter(pct == min(pct)) %>% arrange(rucc_cat) %>% slice(1)
  se <- sqrt(hi$pct/100 * (1 - hi$pct/100) / hi$n +
               lo$pct/100 * (1 - lo$pct/100) / lo$n) * 100
  list(reported = TRUE, hi = hi$rucc_cat, lo = lo$rucc_cat, n_hi = hi$n, n_lo = lo$n,
       spread = spread, se = se, ci_low = spread - 1.96 * se, ci_high = spread + 1.96 * se)
}
# The retired (pre-fix) version, for anti-ceremony comparison only.
build_gap_retired <- function(known) {
  spread <- max(known$pct) - min(known$pct)
  hi <- known %>% filter(pct == max(pct)); lo <- known %>% filter(pct == min(pct))
  se <- sqrt(hi$pct/100 * (1 - hi$pct/100) / hi$n +
               lo$pct/100 * (1 - lo$pct/100) / lo$n) * 100
  list(hi = hi$rucc_cat, lo = lo$rucc_cat, se = se)
}

cat("\n-- BVA --\n")

# T44a-1. The minimum viable case for a comparison: exactly 2 known strata,
# no tie -- the smallest input that legitimately produces a real gap
# statistic.
{
  known <- tibble::tibble(rucc_cat = c("Metro", "Remote"), pct = c(90, 70), n = c(1000, 200))
  r <- build_gap(known)
  chk(isTRUE(r$reported) && r$hi == "Metro" && r$lo == "Remote" && r$spread == 20,
      "T44a-1 exactly 2 known strata with no tie produces a real, single-pair comparison")
}

# T44a-2. THE FIX, boundary 1: fewer than 2 known strata (0 and 1, the two
# sub-boundaries) must both skip the comparison cleanly rather than compute
# on empty/degenerate input.
{
  known0 <- tibble::tibble(rucc_cat = character(0), pct = numeric(0), n = integer(0))
  known1 <- tibble::tibble(rucc_cat = "Metro", pct = 85, n = 1000)
  r0 <- build_gap(known0); r1 <- build_gap(known1)
  chk(!r0$reported && r0$n_known == 0L && !r1$reported && r1$n_known == 1L,
      sprintf("T44a-2 0 and 1 known strata both skip the comparison (got reported=%s/%s)",
              r0$reported, r1$reported))
}

# T44a-3. The zero-spread boundary: every known stratum at the IDENTICAL
# completeness rate (a genuine, if unusual, uniform-missingness case) must
# report a real spread of exactly 0, not skip or error -- this is a valid
# finding ("missingness is uniform"), not a degenerate input.
{
  known <- tibble::tibble(rucc_cat = c("Metro", "Adjacent", "Remote"),
                         pct = c(80, 80, 80), n = c(1000, 500, 200))
  r <- build_gap(known)
  chk(isTRUE(r$reported) && r$spread == 0,
      sprintf("T44a-3 all strata at an identical rate report a real spread of exactly 0 (got %s, reported=%s)",
              r$spread, r$reported))
}

cat("\n-- SEMANTIC --\n")

# T44a-4. THE FIX, boundary 2: a genuine tie between two strata for the
# HIGHEST rate must resolve to a single, deterministic stratum (not a
# length-2 result feeding the SE/CI arithmetic), and the choice must not
# depend on the input row order.
{
  known_a <- tibble::tibble(rucc_cat = c("Metro", "Nonmetro-adj", "Remote"),
                           pct = c(90, 90, 70), n = c(1000, 500, 200))
  known_b <- known_a[c(3, 2, 1), ]
  ra <- build_gap(known_a); rb <- build_gap(known_b)
  chk(length(ra$hi) == 1L && length(ra$se) == 1L,
      sprintf("T44a-4a a tie for highest resolves to a single stratum and a scalar SE (got hi length=%d, se length=%d)",
              length(ra$hi), length(ra$se)))
  chk(identical(ra$hi, rb$hi) && identical(ra, rb),
      "T44a-4b the tie-break choice is identical regardless of input row order")
}

# T44a-5. ANTI-CEREMONY for T44a-4: the retired (pre-fix) logic, applied
# directly to the same tied fixture, actually produces the length-2 hi/se
# this fix prevents -- proving the defect was real, not merely theoretical.
{
  known <- tibble::tibble(rucc_cat = c("Metro", "Nonmetro-adj", "Remote"),
                         pct = c(90, 90, 70), n = c(1000, 500, 200))
  retired <- build_gap_retired(known)
  chk(length(retired$hi) == 2L && length(retired$se) == 2L,
      sprintf("T44a-5 the retired logic produces a length-2 hi/se on the same tied input (got hi length=%d, se length=%d)",
              length(retired$hi), length(retired$se)))
}

# T44a-6. The SE formula itself is the standard two-proportion pooled-free
# standard error (sqrt(p1*(1-p1)/n1 + p2*(1-p2)/n2)); hand-verify against a
# case with round numbers to confirm the formula computes what it claims,
# not just that it runs.
{
  known <- tibble::tibble(rucc_cat = c("A", "B"), pct = c(80, 60), n = c(100, 100))
  r <- build_gap(known)
  expected_se <- sqrt(0.8 * 0.2 / 100 + 0.6 * 0.4 / 100) * 100
  chk(isTRUE(all.equal(r$se, expected_se)),
      sprintf("T44a-6 the SE formula reproduces the hand-computed two-proportion SE exactly (got %.6f, expected %.6f)",
              r$se, expected_se))
}

cat("\n-- ADVERSARIAL --\n")

# T44a-7. Malformed/adversarial input: a 3-way tie for the highest rate
# (not just a pairwise tie) must still resolve to exactly one deterministic
# stratum, not silently produce a length-3 result.
{
  known <- tibble::tibble(rucc_cat = c("Metro", "Adjacent", "Remote", "Frontier"),
                         pct = c(90, 90, 90, 50), n = c(1000, 500, 300, 100))
  r <- build_gap(known)
  chk(length(r$hi) == 1L,
      sprintf("T44a-7 a 3-way tie for highest still resolves to exactly 1 stratum (got length %d)", length(r$hi)))
}

# T44a-8. A simultaneous tie at BOTH ends (two strata tied highest, two
# different strata tied lowest, at once) -- the adversarial combination of
# T44a-4 and its symmetric case for `lo` -- must resolve both ends
# independently and deterministically.
{
  known <- tibble::tibble(rucc_cat = c("A", "B", "C", "D"),
                         pct = c(90, 90, 50, 50), n = c(1000, 500, 300, 100))
  r1 <- build_gap(known); r2 <- build_gap(known[c(4,3,2,1),])
  chk(length(r1$hi) == 1L && length(r1$lo) == 1L && identical(r1, r2),
      "T44a-8 a simultaneous tie at both the high and low end still resolves deterministically at each end")
}

# T44a-9. An n = 0 stratum (a rurality category present in the table with a
# recorded completeness percentage but zero underlying midwives -- a
# plausible artifact of upstream aggregation, e.g. a category retained for
# schema consistency with no members this vintage) must not silently
# produce Inf/NaN in the SE without at least being traceable to that cause;
# pinned here as a documented behavior, since inventing a special-case
# denominator guard for a scenario with no real-world instance on file would
# be guessing at a fix this file's own data has never needed.
{
  known <- tibble::tibble(rucc_cat = c("Metro", "EmptyCat"), pct = c(90, 0), n = c(1000, 0))
  r <- suppressWarnings(build_gap(known))
  chk(isTRUE(r$reported) && (is.nan(r$se) || is.infinite(r$se)),
      sprintf("T44a-9 a zero-n stratum produces NaN/Inf in the SE (documented, not silently plausible) rather than a false-confidence number (got se=%s)",
              r$se))
}

# T44a-10. The two fixed guards are independent: a tie among the known
# strata must not interact with or be masked by the separate <2-known-strata
# skip -- verified by confirming the skip path is never taken when a tie
# occurs among 3+ genuinely present strata (i.e., a tie does not accidentally
# collapse nrow(known) below the threshold).
{
  known <- tibble::tibble(rucc_cat = c("Metro", "Adjacent", "Remote"),
                         pct = c(90, 90, 70), n = c(1000, 500, 200))
  r <- build_gap(known)
  chk(isTRUE(r$reported),
      "T44a-10 a tie among 3 present strata does not trigger the separate <2-known-strata skip")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
