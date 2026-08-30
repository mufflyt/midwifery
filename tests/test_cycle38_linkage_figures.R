#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 38 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: tipping() in analyze_linkage_selection_bias.R (a pure function
# feeding the NEW selection_bounds.{pdf,png,svg} figure added this session in
# PR #131/make_linkage_figures.R), plus the inline data-transformation logic
# in make_linkage_figures.R itself. Neither file had any prior test coverage.
# make_linkage_figures.R cannot be sourced end-to-end (it needs the gitignored
# stats catalog and network-free but artifact-dependent manuscript stats), so
# its inline dplyr transformations are replicated literally, matching this
# session's established pattern; analyze_linkage_selection_bias.R is a flat,
# unguarded top-to-bottom script (no main() guard) so tipping()'s logic is
# also replicated literally rather than sourced.
#
# THE DEFECT (fixed this cycle): tipping() solves for what share of the
# UNOBSERVED roster would need to be metro to reach a target threshold, then
# reports the departure from the observed share. Two degenerate inputs
# divided by zero with NO error or warning: a fully-linked roster (unobs = 0)
# produced Inf/Inf; a fully-unlinked roster (n_linked = 0) produced NaN for
# the departure. Both values flow directly into the manuscript's own caption
# sentence via fig_num("bounds.tip_required")/fig_num("bounds.tip_departure")
# in make_linkage_figures.R ("the unobserved would have to be X% metropolitan
# -- a Y-point departure"). Not reachable by the current roster -- this whole
# analysis exists because linkage is incomplete, so 0%/100%-linked never
# actually happens -- but a sensitivity re-run on a filtered subgroup could
# hit either edge. Fixed with an explicit guard returning NA for both
# outputs when the roster split is degenerate.
#
# Run: Rscript tests/test_cycle38_linkage_figures.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(tidyr) })

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of the FIXED tipping() (analyze_linkage_selection_bias.R,
# ~lines 254-266), parameterized so each test supplies its own d/n_roster/
# n_linked instead of relying on the file's own top-level variables.
tipping_fixed <- function(d, n_roster, n_linked, cc, threshold_pct) {
  k <- sum(d$rurality == cc & d$linked, na.rm = TRUE)
  unobs <- n_roster - n_linked
  if (unobs <= 0 || n_linked <= 0)
    return(c(required_unobserved_pct = NA_real_, departure_pp = NA_real_))
  u <- (threshold_pct / 100 * n_roster - k) / unobs
  c(required_unobserved_pct = 100 * u, departure_pp = 100 * u - 100 * k / n_linked)
}
# The retired (pre-fix) version, for anti-ceremony comparison only.
tipping_retired <- function(d, n_roster, n_linked, cc, threshold_pct) {
  k <- sum(d$rurality == cc & d$linked, na.rm = TRUE)
  unobs <- n_roster - n_linked
  u <- (threshold_pct / 100 * n_roster - k) / unobs
  c(required_unobserved_pct = 100 * u, departure_pp = 100 * u - 100 * k / n_linked)
}

# Literal replica of make_linkage_figures.R's status-level transformation
# (lines ~61-68).
build_st <- function(lc) {
  lc |>
    mutate(resolution = 100 * matched / n,
           ascertainment = 100 * (matched + matched_nursing_taxonomy) / n) |>
    filter(n >= 100) |>
    arrange(resolution)
}

cat("\n-- BVA --\n")

# T38-1. The n >= 100 filter's exact boundary: a status with n = 99 must be
# excluded, n = 100 must be included -- the minimum-sample-size cutoff this
# figure's own caption ("statuses with at least 100 certificants") depends on.
{
  lc <- tibble(status = c("A", "B", "C"), n = c(99L, 100L, 101L),
              matched = c(50L, 60L, 70L), matched_nursing_taxonomy = c(5L, 5L, 5L))
  st <- build_st(lc)
  chk(identical(sort(st$status), c("B", "C")),
      sprintf("T38-1 n=99 is excluded, n=100 and n=101 are included (got %s)",
              paste(sort(st$status), collapse = ", ")))
}

# T38-2. THE FIX, boundary 1: a fully-linked roster (unobs = 0) -- there is
# no unobserved population to reason about at all -- must report NA, not the
# retired Inf/Inf that would have flowed silently into a manuscript caption.
{
  d <- tibble(rurality = c("Metro", "Metro", "Rural"), linked = c(TRUE, TRUE, TRUE))
  r <- tipping_fixed(d, n_roster = 3, n_linked = 3, cc = "Metro", threshold_pct = 75)
  chk(is.na(r["required_unobserved_pct"]) && is.na(r["departure_pp"]),
      sprintf("T38-2 unobs=0 (fully-linked roster) returns NA for both outputs (got %s, %s)",
              r["required_unobserved_pct"], r["departure_pp"]))
}

# T38-3. THE FIX, boundary 2: a fully-unlinked roster (n_linked = 0) -- there
# is no observed cohort to depart from -- must also report NA, not the
# retired NaN for departure_pp.
{
  d <- tibble(rurality = character(0), linked = logical(0))
  r <- tipping_fixed(d, n_roster = 100, n_linked = 0, cc = "Metro", threshold_pct = 75)
  chk(is.na(r["required_unobserved_pct"]) && is.na(r["departure_pp"]),
      sprintf("T38-3 n_linked=0 (fully-unlinked roster) returns NA for both outputs (got %s, %s)",
              r["required_unobserved_pct"], r["departure_pp"]))
}

cat("\n-- SEMANTIC --\n")

# T38-4. Normal-case correctness: tipping()'s own comment states the equation
# it solves, (k + u*unobs)/N = t/100. Hand-verify against a case where the
# answer is computable by inspection: 50 of 100 roster members are linked and
# metro (k=50), 50 are unobserved (unobs=50), N=100 total, threshold=75% --
# solving 50 + 50u = 75 gives u = 0.5 (50%), and departure from the observed
# 100% (k/n_linked = 50/50) is 50 - 100 = -50 points.
{
  d <- tibble(rurality = rep("Metro", 50), linked = rep(TRUE, 50))
  r <- tipping_fixed(d, n_roster = 100, n_linked = 50, cc = "Metro", threshold_pct = 75)
  chk(isTRUE(all.equal(unname(r["required_unobserved_pct"]), 50)) &&
        isTRUE(all.equal(unname(r["departure_pp"]), -50)),
      sprintf("T38-4 the formula reproduces the hand-solved answer (u=50%%, departure=-50pp) exactly (got %.4f, %.4f)",
              r["required_unobserved_pct"], r["departure_pp"]))
}

# T38-6. A value outside [0, 100] is a MEANINGFUL sensitivity answer here
# ("even a 0%-metro unobserved population could not bring the share below
# threshold"), not an error condition to clamp or suppress -- when the
# observed share already exceeds the threshold, required_unobserved_pct must
# be allowed to go negative rather than being silently floored at 0.
{
  d <- tibble(rurality = rep("Metro", 90), linked = rep(TRUE, 90))
  r <- tipping_fixed(d, n_roster = 100, n_linked = 90, cc = "Metro", threshold_pct = 75)
  chk(unname(r["required_unobserved_pct"]) < 0,
      sprintf("T38-6 an already-above-threshold observed share reports a genuinely negative required_unobserved_pct, not clamped to 0 (got %.2f)",
              r["required_unobserved_pct"]))
}

# T38-9. DOCUMENTED, not fixed: METRO <- grep("^Metro", CATS, value =
# TRUE)[1] silently resolves to whichever matching category label happens to
# sort first if more than one rurality category starts with "Metro" -- no
# ambiguity warning. In the real pipeline CATS is a small, fixed, controlled
# label set, so this is a low-probability risk, not fixed here; pinned so a
# future change to the category-labeling scheme does not silently start
# picking a different, wrong category.
{
  CATS <- c("Metro", "Metro (RUCC 1-3)", "Rural")
  METRO <- grep("^Metro", CATS, value = TRUE)[1]
  chk(identical(METRO, "Metro"),
      sprintf("T38-9 with two '^Metro'-matching labels present, the first one in CATS order silently wins (got '%s')", METRO))
}

cat("\n-- ADVERSARIAL --\n")

# T38-5. DOCUMENTED SCIENTIFIC AMBIGUITY, not fixed: a status with an NA
# matched_nursing_taxonomy count produces an NA ascertainment value, which a
# ggplot geom mapped to that aesthetic would silently drop from the rendered
# figure (a "Removed 1 row containing missing values" warning, not an error)
# -- a certification status could vanish from a published dumbbell chart with
# no visible failure. Whether a missing nursing-taxonomy count should be
# treated as 0 (include the status, ascertainment = resolution) or as a
# reason to exclude the status with a visible note is a scientific decision
# this cycle does not make silently.
{
  lc <- tibble(status = c("ACTIVE", "LAPSED"), n = c(200L, 150L),
              matched = c(100L, 80L), matched_nursing_taxonomy = c(10L, NA_integer_))
  st <- build_st(lc)
  chk(is.na(st$ascertainment[st$status == "LAPSED"]) &&
        !is.na(st$resolution[st$status == "LAPSED"]),
      "T38-5 a status with an NA nursing-taxonomy count gets an NA ascertainment (would silently vanish from the plotted dumbbell) while its resolution stays computable")
}

# T38-7. ANTI-CEREMONY for T38-2/T38-3: the retired (pre-fix) formula,
# applied directly to the same two degenerate inputs, produces the exact
# Inf/Inf and NaN this cycle's guard now prevents.
{
  d1 <- tibble(rurality = c("Metro", "Metro", "Rural"), linked = c(TRUE, TRUE, TRUE))
  r1 <- tipping_retired(d1, n_roster = 3, n_linked = 3, cc = "Metro", threshold_pct = 75)
  d2 <- tibble(rurality = character(0), linked = logical(0))
  r2 <- suppressWarnings(tipping_retired(d2, n_roster = 100, n_linked = 0, cc = "Metro", threshold_pct = 75))
  chk(is.infinite(r1["required_unobserved_pct"]) && is.infinite(r1["departure_pp"]),
      sprintf("T38-7a the retired formula produces Inf/Inf for unobs=0 (got %s, %s)",
              r1["required_unobserved_pct"], r1["departure_pp"]))
  chk(is.nan(r2["departure_pp"]),
      sprintf("T38-7b the retired formula produces NaN for departure_pp when n_linked=0 (got %s)",
              r2["departure_pp"]))
}

# T38-8. INVESTIGATED, already safe: a duplicate status label in the input
# CSV (e.g. "ACTIVE" appearing twice from an upstream aggregation defect)
# already fails LOUDLY -- factor(status, levels = status) errors outright on
# a duplicated level ("factor level [2] is duplicated"). Pinned as an
# existing safety property, not a defect this cycle needs to fix.
{
  lc <- tibble(status = c("ACTIVE", "ACTIVE", "LAPSED"), n = c(200L, 300L, 150L),
              matched = c(100L, 150L, 80L), matched_nursing_taxonomy = c(10L, 10L, 5L))
  st <- build_st(lc)
  err <- tryCatch({
    st %>% mutate(status = factor(status, levels = status))
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("duplicated", err),
      sprintf("T38-8 a duplicate status label already fails loudly at the factor() step (got: %s)",
              if (is.na(err)) "no error -- silently accepted" else err))
}

# T38-10. suppressWarnings(as.numeric(...)) in fig_num() silently converts
# any non-numeric catalog value (a typo'd key returning an error string, or a
# formatting defect) into NA with the warning suppressed -- a broken catalog
# reference becomes a blank data point on a published figure rather than a
# caught, visible error.
{
  fig_num_body <- function(x) suppressWarnings(as.numeric(x))
  r <- fig_num_body("not_a_number")
  chk(is.na(r),
      "T38-10 a non-numeric catalog value silently becomes NA (no warning surfaces) rather than an error -- a broken key would render as a blank point, not a caught failure")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
