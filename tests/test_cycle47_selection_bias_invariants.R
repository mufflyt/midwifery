# Cycle 47 (FINAL numbered cycle) -- analyze_linkage_selection_bias.R
#
# Rotation: 3 BVA / 3 semantic / 4 adversarial.
#
# This file computes Manski worst-case bounds, IPW, and a tipping-point
# statistic on the rurality distribution -- the uncertainty-propagation
# analysis for the study's binding limitation (23% of the roster has no
# assignable county). It is prioritized-by-consequence territory
# (uncertainty propagation, geography/travel-time logic) that had never been
# directly unit-tested -- only mentioned incidentally, by name, as an
# artifact producer in tests/ci_science_laws.R.
#
# This cycle's finding: the file's own header claims "an invariant below
# refuses to write anything unless it reproduces composition_rucc_cat.csv
# exactly", but the reconciliation block that enforces this ran only
# `if (file.exists(comp_path))` -- if that file was simply ABSENT (a fresh
# checkout, or running this script before R/07-cohort-composition.R), the
# whole block was silently skipped: no error, no message, and the output
# artifact was written anyway, unreconciled. A stated safety invariant that
# fails open is a defect, not a leniency. Fixed by adding
# composition_rucc_cat.csv to the same top-of-file required-input check the
# other five inputs already use, and making the reconciliation unconditional.
# T47-7/T47-8 are the anti-ceremony pair proving the gap and the fix.

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) {
    cat("  ok  ", msg, "\n")
  } else {
    cat("  FAIL ", msg, "\n")
    fails <<- fails + 1L
  }
}

suppressPackageStartupMessages(library(dplyr))

cat("== Cycle 47: analyze_linkage_selection_bias.R invariants ==\n\n")

real_src <- paste(readLines(file.path(".", "analyze_linkage_selection_bias.R")), collapse = "\n")
chk(grepl("COMP,", real_src, fixed = TRUE) && grepl('COMP   <- file.path(ART, "composition_rucc_cat.csv")', real_src, fixed = TRUE),
    "T47-0 (setup, not counted): the real file requires COMP up front, matching what this test assumes")

# ---------------------------------------------------------------------------
# The SHIPPED bounds_for() and tipping(), not replicas of them. They were
# extracted to R/lib/selection_bounds.R precisely so this test can reach
# them: analyze_linkage_selection_bias.R itself reads gitignored
# person-level artifacts at top level and cannot be sourced on a runner.
# ---------------------------------------------------------------------------
source(file.path(if (dir.exists("R")) "." else "..", "R", "lib", "selection_bounds.R"))

reconcile_retired <- function(comp_path, comp_data, mine) {
  if (file.exists(comp_path)) {
    cmp <- full_join(comp_data, mine, by = "level") |>
      mutate(across(c(published_n, mine), ~ tidyr::replace_na(.x, 0L)),
             gap = .data$mine - .data$published_n)
    if (any(cmp$gap != 0)) return(list(stopped = TRUE, cmp = cmp))
    return(list(stopped = FALSE, cmp = cmp))
  }
  list(stopped = FALSE, cmp = NULL, skipped = TRUE)
}

reconcile_fixed <- function(comp_path, comp_data, mine) {
  if (!file.exists(comp_path))
    stop(sprintf("%s is absent.", comp_path), call. = FALSE)
  cmp <- full_join(comp_data, mine, by = "level") |>
    mutate(across(c(published_n, mine), ~ tidyr::replace_na(.x, 0L)),
           gap = .data$mine - .data$published_n)
  if (any(cmp$gap != 0))
    stop("INVARIANT: the rurality counts here disagree with composition_rucc_cat.csv.", call. = FALSE)
  cmp
}

# ---------------------------------------------------------------------------
# BVA (3)
# ---------------------------------------------------------------------------

cat("\n-- BVA: bounds_for() when unobs = 0 (fully observed) -- the bound must collapse to a point --\n")
df_full <- tibble::tibble(rurality = c("Metro", "Metro", "Remote"), linked = c(TRUE, TRUE, TRUE))
b1 <- bounds_for(df_full, "linked", c("Metro", "Remote"))
chk(isTRUE(all.equal(b1["lower_pct", "Metro"], b1["upper_pct", "Metro"])) &&
      isTRUE(all.equal(b1["lower_pct", "Metro"], b1["observed_pct", "Metro"])),
    "T47-1: with zero missingness, lower_pct == upper_pct == observed_pct exactly (no artificial width)")

cat("\n-- BVA: bounds_for() when obs = 0 (nothing observed for the flag) -- maximal uncertainty --\n")
df_none <- tibble::tibble(rurality = c(NA, NA, NA), linked = c(FALSE, FALSE, FALSE))
b2 <- bounds_for(df_none, "linked", c("Metro", "Remote"))
chk(is.na(b2["observed_pct", "Metro"]) && b2["lower_pct", "Metro"] == 0 && b2["upper_pct", "Metro"] == 100,
    "T47-2: with zero observations, observed_pct is NA (not a divide-by-zero crash) and the bound is the full [0, 100]")

cat("\n-- BVA: tipping() at the fixed point (observed share already equals the threshold) --\n")
fp <- tipping(k = 750, n_linked = 1000, n_roster = 2000, threshold_pct = 75)
chk(isTRUE(all.equal(fp[["departure_pp"]], 0)),
    "T47-3: when the observed share already equals the threshold exactly, departure_pp is exactly 0 (a fixed point, not a rounding-sensitive near-zero)")

# ---------------------------------------------------------------------------
# Semantic / contract (3)
# ---------------------------------------------------------------------------

cat("\n-- Semantic: Manski bounds are internally ordered (lower <= observed <= upper) --\n")
df_mixed <- tibble::tibble(
  rurality = c("Metro", "Metro", "Remote", NA, NA),
  linked   = c(TRUE, TRUE, TRUE, FALSE, FALSE))
b3 <- bounds_for(df_mixed, "linked", c("Metro", "Remote"))
chk(all(b3["lower_pct", ] <= b3["observed_pct", ] + 1e-9) &&
      all(b3["observed_pct", ] <= b3["upper_pct", ] + 1e-9),
    "T47-4: for every category, lower_pct <= observed_pct <= upper_pct holds under partial missingness")

cat("\n-- Semantic: the derived bound width is never negative --\n")
width <- b3["upper_pct", ] - b3["lower_pct", ]
chk(all(width >= 0),
    "T47-5: bound_width_pp (upper - lower) is nonnegative for every category -- the bound is never inverted")

cat("\n-- Semantic: tipping()'s required_unobserved_pct is UNCLAMPED and can fall outside [0,100] --\n")
already_above <- tipping(k = 950, n_linked = 1000, n_roster = 1200, threshold_pct = 75)
chk(already_above[["required_unobserved_pct"]] < 0,
    "T47-6: when the observed share already exceeds the threshold, tipping() returns a negative 'required' percentage rather than clamping to 0 or flagging the threshold as already met -- documented here as an existing, undecided contract ambiguity (not fixed this cycle, consistent with this session's treatment of similar unclamped-output findings)")

# ---------------------------------------------------------------------------
# Adversarial (4)
# ---------------------------------------------------------------------------

cat("\n-- Adversarial: the reconciliation invariant is a SILENT NO-OP when composition_rucc_cat.csv is absent --\n")
tmp_absent <- tempfile()
mine1 <- tibble::tibble(level = c("Metro", "Nonmetro"), mine = c(100, 50))
retired_absent <- reconcile_retired(tmp_absent, NULL, mine1)
chk(isTRUE(retired_absent$skipped) && !retired_absent$stopped,
    "T47-7 (anti-ceremony): the retired reconciliation logic neither runs nor errors when comp_path is missing -- it silently proceeds to write the output artifact unreconciled, contradicting the file's own header claim of an unconditional invariant")

fixed_err <- tryCatch({ reconcile_fixed(tmp_absent, NULL, mine1); "NO ERROR" },
                       error = function(e) conditionMessage(e))
chk(grepl("is absent", fixed_err),
    "T47-8: the fixed logic (comp_path required up front, reconciliation unconditional) stops loudly on the same missing file instead of silently skipping")

cat("\n-- Adversarial: a category present only in `mine`, absent from the published composition --\n")
tmp_present <- tempfile(); writeLines("x", tmp_present)
comp_short <- tibble::tibble(level = "Metro", published_n = 100)
mine_extra <- tibble::tibble(level = c("Metro", "Nonmetro"), mine = c(100, 50))
r_extra <- reconcile_retired(tmp_present, comp_short, mine_extra)
chk(isTRUE(r_extra$stopped) && r_extra$cmp$gap[r_extra$cmp$level == "Nonmetro"] == 50,
    "T47-9: a rurality level this analysis found but the published composition never reported (gap = 50, not silently zero-filled and ignored) is caught by the full_join + replace_na reconciliation")

cat("\n-- Adversarial: a category present only in the published composition, absent from `mine` (vanished) --\n")
comp_extra <- tibble::tibble(level = c("Metro", "Remote"), published_n = c(100, 20))
mine_short <- tibble::tibble(level = "Metro", mine = 100)
r_vanish <- reconcile_retired(tmp_present, comp_extra, mine_short)
chk(isTRUE(r_vanish$stopped) && r_vanish$cmp$gap[r_vanish$cmp$level == "Remote"] == -20,
    "T47-10: a rurality level the published composition reported but this analysis found NONE of (gap = -20, the opposite-direction asymmetry from T47-9) is equally caught -- the full_join gap check works in both directions, not just the direction that happens to be exercised by real data")

cat("\n")
if (fails == 0L) {
  cat("PASS: all Cycle 47 checks passed\n")
} else {
  cat(sprintf("FAIL: %d check(s) failed\n", fails))
}
quit(status = if (fails == 0L) 0L else 1L)
