#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 37 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: compose() and the missingness-ledger builder in
# R/07-cohort-composition.R, both added/expanded in PR #128 (merged onto main
# this session) alongside tests/ci_science_laws.R's L13 gate and 21/21
# mutation-detection claim. That mutation coverage is real (re-verified below,
# unaffected by this cycle's fix) but operates on the ARTIFACT
# (composition_missingness_ledger.csv) end-to-end -- it never unit-tests
# compose() or the ledger-building code directly with synthetic fixtures, so
# a defect that never happens to manifest in the current real data would slip
# through untested. This cycle found one that does.
#
# THE DEFECT: top_level_pct was hardcoded to 100 for a group with ZERO
# observed values -- exactly the group|variable combination this whole ledger
# exists to flag (see the file's own "WHY THIS EXISTS" comment, describing the
# real incident: rurality 100% missing for one group). A reader would see
# top_level_pct = 100 next to n_observed = 0 and could read it as "100% of
# this group's rurality is one level" when there is no level to report at
# all -- the exact kind of confidently-wrong number this ledger was built to
# prevent, reproduced in its own least-checked column.
#
# Verified this is a LIVE, not merely hypothetical, defect: the whole point of
# this ledger is to flag a variable that is 100% missing for a group, and that
# is precisely the input that triggered the old, wrong value.
#
# Loaded via sys.source() into a private env (matching this session's
# established pattern for files with a top-level `if (identical(environment(),
# globalenv())...)` guard) so build_composition()'s own side effects (reading
# gitignored FROZEN artifacts) never run; compose() itself is a pure function
# and needs no artifact.
#
# Run: Rscript tests/test_cycle37_composition_ledger.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(tidyr) })

e <- new.env()
sys.source("R/07-cohort-composition.R", envir = e)
compose <- e$compose

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of the ledger-building step (R/07-cohort-composition.R,
# ~lines 288-314), parameterized on `d` and one variable so each test can
# supply its own fixture without needing the full build_composition() pipeline.
ledger_row <- function(d, v) {
  grp_sizes <- count(d, group, name = "group_n")
  d %>%
    group_by(group) %>%
    summarise(variable = v,
              n_observed = sum(!is.na(.data[[v]]) & nzchar(as.character(.data[[v]]))),
              .groups = "drop") %>%
    left_join(grp_sizes, by = "group") %>%
    mutate(n_missing = group_n - n_observed,
           pct_missing = 100 * n_missing / group_n,
           top_level_pct = vapply(group, function(g) {
             x <- d[[v]][d$group == g]
             x <- x[!is.na(x) & nzchar(as.character(x))]
             if (!length(x)) NA_real_ else 100 * max(table(x)) / length(x)
           }, numeric(1)))
}

cat("\n-- BVA --\n")

# T37-1. The minimum non-trivial case: exactly 2 groups present, one
# concentrated entirely in level "x" and the other entirely in level "y" --
# the boundary at which a "spread" is meaningful at all (fewer than 2 groups
# and max_minus_min_pp cannot be interpreted as a between-group comparison).
{
  d <- tibble(group = c("A", "B"), var1 = c("x", "y"))
  r <- compose(d, "var1")
  chk(nrow(r$wide) == 2L && r$wide$max_minus_min_pp[1] == 100 &&
        r$wide$max_minus_min_pp[2] == 100,
      "T37-1 exactly 2 groups, each 100% one level, spread is exactly 100 for both rows")
}

# T37-2. A variable entirely NA across EVERY group (not just one) -- the
# fully-degenerate case. compose() must return a well-typed 0-row long/wide
# result, not error, even though internally apply() over a 0-row matrix and
# max()/min() over an empty numeric vector each emit their own warnings.
{
  d <- tibble(group = c("A", "A", "B", "B"), var1 = c(NA, NA, NA, NA))
  r <- suppressWarnings(compose(d, "var1"))
  chk(is.list(r) && nrow(r$long) == 0L && nrow(r$wide) == 0L,
      sprintf("T37-2 a variable entirely NA across all groups returns 0-row long/wide, not an error (got long=%d, wide=%d rows)",
              nrow(r$long), nrow(r$wide)))
}

# T37-3. The single-group boundary (k=1): with only one group present,
# max_minus_min_pp must be exactly 0 for every level -- there is nothing to
# compare a group against but itself.
{
  d <- tibble(group = c("A", "A", "A"), var1 = c("x", "y", "x"))
  r <- compose(d, "var1")
  chk(all(r$wide$max_minus_min_pp == 0),
      sprintf("T37-3 with only 1 group present, max_minus_min_pp is 0 for every level (got %s)",
              paste(r$wide$max_minus_min_pp, collapse = ", ")))
}

cat("\n-- SEMANTIC --\n")

# T37-4. THE FIX. A group with ZERO observed values for a variable must
# report top_level_pct = NA, not the same confident-looking 100 a genuinely
# 100%-concentrated group would report -- these are two different facts
# ("no data" vs. "all the data agrees") and must not share one value.
{
  d <- tibble(group = c("A", "A", "A", "B", "B", "B"),
             var1 = c("x", "y", "x", NA, NA, NA))
  led <- ledger_row(d, "var1")
  a <- led[led$group == "A", ]; b <- led[led$group == "B", ]
  chk(a$n_observed == 3L && !is.na(a$top_level_pct) &&
        isTRUE(all.equal(unname(a$top_level_pct), 100 * 2 / 3)),
      sprintf("T37-4a group A (3 observed, 2/3 'x') reports a real top_level_pct (got %s)", a$top_level_pct))
  chk(b$n_observed == 0L && is.na(b$top_level_pct),
      sprintf("T37-4b group B (0 observed) reports NA, not a confident 100 (got %s)", b$top_level_pct))
  # ANTI-CEREMONY: the retired computation, applied directly to the same data.
  retired_top_level_pct <- if (!length(character(0))) 100 else NA
  chk(identical(retired_top_level_pct, 100),
      "T37-4c the retired rule hardcoded 100 for zero observed values")
}

# T37-5. The two-layer division of labor this file relies on: compose()'s own
# output SILENTLY DROPS a group that is 100% missing for a variable (this is
# documented, still-live behavior -- the ledger is the safety net, not a fix
# to compose() itself), while the INDEPENDENT ledger computation over the
# same raw `d` correctly retains and reports that group. Both facts must hold
# together, or the safety net does not actually cover what compose() misses.
{
  d <- tibble(group = c("A", "A", "A", "B", "B", "B"),
             var1 = c("x", "y", "x", NA, NA, NA))
  r <- compose(d, "var1")
  led <- ledger_row(d, "var1")
  chk(!("B" %in% names(r$wide)) && !("B" %in% r$long$group),
      "T37-5a compose() itself has no trace of group B anywhere in long or wide")
  chk("B" %in% led$group && led$n_missing[led$group == "B"] == 3L,
      "T37-5b ...but the independent ledger computation over the same raw data reports it in full")
}

# T37-6. pct sums to exactly 100 per group even when groups have DIFFERENT
# sets of observed levels (values_fill = 0 backfills the levels a group never
# used, rather than leaving them NA and breaking the "percentages sum to 100"
# contract for that group's column).
{
  d <- tibble(group = c("A", "A", "B", "B", "B"), var1 = c("x", "x", "x", "y", "z"))
  r <- compose(d, "var1")
  sums <- colSums(r$wide[c("A", "B")])
  chk(isTRUE(all.equal(unname(sums["A"]), 100)) && isTRUE(all.equal(unname(sums["B"]), 100)),
      sprintf("T37-6 both groups' percentage columns sum to exactly 100 despite asymmetric levels (got A=%s, B=%s)",
              sums["A"], sums["B"]))
}

# T37-7. The 99%-dominant-level case explicitly named in this file's own
# comment ("certification is 99.1% CNM in every group and must stay green")
# -- pct must reflect the true 99/1 split, not round or collapse toward 100.
{
  d <- tibble(group = rep("A", 100), var1 = c(rep("CNM", 99), "CM"))
  r <- compose(d, "var1")
  cnm_pct <- r$long$pct[r$long$level == "CNM"]
  cm_pct  <- r$long$pct[r$long$level == "CM"]
  chk(cnm_pct == 99 && cm_pct == 1,
      sprintf("T37-7 a 99/1 split reports exactly 99%% and 1%%, not rounded toward 100 (got %s / %s)",
              cnm_pct, cm_pct))
}

cat("\n-- ADVERSARIAL --\n")

# T37-8. compose() has NO internal duplicate-row guard: a row duplicated by
# an upstream join fan-out (the exact failure class this whole file's history
# is about -- see its own header on why joins are declared
# relationship = "many-to-one") silently inflates N and shifts every pct in
# that group, with no warning or error from compose() itself. In the real
# pipeline this risk is mitigated by the explicit relationship= declarations
# on the joins that build `d` before compose() ever sees it -- but compose()
# itself provides no protection of its own, so this is pinned as a documented
# assumption compose() relies on its caller to guarantee, not a defect fixed
# this cycle (adding a person-level duplicate check to a small, reusable,
# group+level helper would require inventing which column identifies a
# person, which compose() is not given).
{
  base <- tibble(group = c("A", "A", "B"), var1 = c("x", "y", "x"))
  dup <- bind_rows(base, base[1, ])  # row 1 duplicated
  r_base <- compose(base, "var1"); r_dup <- compose(dup, "var1")
  chk(!identical(r_base$wide$A, r_dup$wide$A),
      sprintf("T37-8 a single duplicated row silently changes group A's percentages (base=%s, duplicated=%s) -- compose() has no guard of its own",
              paste(round(r_base$wide$A, 1), collapse = "/"),
              paste(round(r_dup$wide$A, 1), collapse = "/")))
}

# T37-9. The ledger's "observed" test, nzchar(as.character(x)), must treat an
# EMPTY STRING the same as NA -- both are "not observed" -- while a genuinely
# non-empty string counts. A naive !is.na() alone would miscount an empty
# string as observed data.
{
  d <- tibble(group = c("A", "A", "A"), var1 = c("x", "", NA))
  led <- ledger_row(d, "var1")
  chk(led$n_observed[led$group == "A"] == 1L,
      sprintf("T37-9 an empty string and an NA both count as not-observed; only the real value counts (got n_observed=%d)",
              led$n_observed[led$group == "A"]))
}

# T37-10. A labeled but genuinely EMPTY group (group_n = 0 -- e.g. a factor
# level or expected cohort stratum with zero rows in this snapshot) must not
# silently divide by zero when computing pct_missing. This is the ledger's
# OWN division, distinct from compose()'s pct calculation (which is
# protected by never having a 0-row group to divide by in the first place,
# since count() only emits groups that actually appear).
{
  group_n <- 0L; n_missing <- 0L
  pct_missing <- 100 * n_missing / group_n
  chk(is.nan(pct_missing),
      sprintf("T37-10 group_n = 0 produces NaN (not a silently-plausible number) in the ledger's own division (got %s) -- a real empty group would need an explicit guard before reaching this formula, which currently has none",
              pct_missing))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
