# Cycle 46 -- manuscript/R/build_stats_catalog.R interval/trend statistics
#
# Rotation: 3 BVA / 4 semantic / 3 adversarial.
#
# Continuation of Cycle 45 (which fixed manuscript/R/inline_stats.R, the
# formatting layer). This cycle targets the arithmetic layer underneath it:
# mw_wilson() (Wilson score CI), mw_trend() (Cochran-Armitage trend test),
# and mw_diff() (two-proportion difference + CI) in
# manuscript/R/build_stats_catalog.R. These three feed every CI and p-value
# that reaches the manuscript via mw_stat()/mw_pval().
#
# This cycle's finding, discovered by direct empirical testing before writing
# any test: both mw_wilson() and mw_diff() take z as a normal deviate but use
# it LINEARLY (not squared) in the half-width term. A non-positive z silently
# SWAPS the lower and upper bound instead of erroring -- the same defect
# class independently in two functions. Neither is exercised by any real
# call site (both always use the z=1.96 default), so this is latent, but the
# same one-line stop() guard closes it in both places. T46-8/T46-9 are the
# anti-ceremony companions, reproducing the retired (unguarded) bodies to
# prove the inversion actually happens before confirming the fixed versions
# stop instead.

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) {
    cat("  ok  ", msg, "\n")
  } else {
    cat("  FAIL ", msg, "\n")
    fails <<- fails + 1L
  }
}

ROOT <- if (dir.exists("manuscript")) "." else ".."
source(file.path(ROOT, "manuscript", "R", "inline_stats.R"))

# The SHIPPED mw_wilson(), mw_trend() and mw_diff() -- not replicas of them.
# This test used to carry literal copies, on the reasoning that the real file
# "needs gitignored artifacts to source end-to-end". Only mw_build_catalog()
# needs them: build_stats_catalog.R's top level does nothing but load packages
# and set MW_ART, so the file sources cleanly on a bare runner and the pure
# arithmetic helpers can be taken straight from it. Bound out of the sourced
# environment rather than redefined at top level, so every assertion below
# runs against the code the manuscript actually calls.
.cat <- new.env()
sys.source(file.path(ROOT, "manuscript", "R", "build_stats_catalog.R"), envir = .cat)
mw_wilson <- .cat$mw_wilson
mw_trend  <- .cat$mw_trend
mw_diff   <- .cat$mw_diff

cat("== Cycle 46: build_stats_catalog.R interval/trend statistics ==\n\n")

cat("-- The functions under test are the shipped ones, exercised directly --\n")
chk(inherits(try(mw_wilson(50, 100, z = -1.96), silent = TRUE), "try-error"),
    "T46-0 (setup, not counted): the SHIPPED mw_wilson() raises on a non-positive z -- a behavioural check on the real function, not a grep for the guard's text")

# ---------------------------------------------------------------------------
# BVA (3)
# ---------------------------------------------------------------------------

cat("\n-- BVA: mw_wilson() at x=0 (proportion floor) --\n")
lo_hi_0 <- mw_wilson(0, 100)
chk(isTRUE(all.equal(lo_hi_0[1], 0)),
    "T46-1: x=0 successes clips the Wilson lower bound to exactly 0, not a negative percentage")

cat("\n-- BVA: mw_wilson() at x=n (proportion ceiling) --\n")
lo_hi_n <- mw_wilson(100, 100)
chk(isTRUE(all.equal(lo_hi_n[2], 100)),
    "T46-2: x=n successes clips the Wilson upper bound to exactly 100, not above 100")

cat("\n-- BVA: mw_trend() at the minimum non-degenerate size (2 strata) vs. below it (1 stratum) --\n")
two_strata <- mw_trend(c(50, 30), c(100, 100))
one_stratum <- mw_trend(c(5), c(10))
chk(is.finite(two_strata$z) && is.finite(two_strata$p),
    "T46-3: 2 strata (the minimum a trend test can compare) yields a finite z and p")
chk(is.nan(one_stratum$z) && is.na(one_stratum$p),
    "T46-3b: 1 stratum (below the minimum -- nothing to trend across) yields NaN, not a spurious finite answer")

# ---------------------------------------------------------------------------
# Semantic / contract (4)
# ---------------------------------------------------------------------------

cat("\n-- Semantic: the Wilson CI always contains the raw sample proportion --\n")
x <- 63; n <- 200
ci <- mw_wilson(x, n)
chk(ci[1] <= 100 * x / n && 100 * x / n <= ci[2],
    "T46-4: mw_wilson(63, 200)'s interval brackets the raw 31.5% point estimate")

cat("\n-- Semantic: mw_diff()'s CI is internally ordered (lo <= estimate <= hi) --\n")
d <- mw_diff(136, 200, 90, 200)
chk(d[2] <= d[1] && d[1] <= d[3],
    "T46-5: mw_diff()'s three returned values are ordered lo, estimate, hi under the default positive z")

cat("\n-- Semantic: mw_trend() is order-sensitive (it is a trend test, not a symmetric one) --\n")
fwd <- mw_trend(c(50, 40, 30), c(100, 100, 100))
rev <- mw_trend(c(30, 40, 50), c(100, 100, 100))
chk(isTRUE(all.equal(fwd$z, -rev$z)) && !isTRUE(all.equal(fwd$z, rev$z)),
    "T46-6: reversing the stratum order negates z -- the function is genuinely testing trend across ORDERED strata, as documented, not an order-invariant statistic")
chk(isTRUE(all.equal(fwd$p, rev$p)),
    "T46-7: reversing the stratum order leaves the two-sided p-value unchanged (|z| is order-invariant even though z's sign is not)")

# ---------------------------------------------------------------------------
# Adversarial (3)
# ---------------------------------------------------------------------------

cat("\n-- Adversarial: mw_wilson() with a non-positive z, vs. its retired (unguarded) body --\n")
mw_wilson_retired <- function(x, n, z = 1.96) {
  p <- x / n
  d <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / d
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(100 * (centre - half), 100 * (centre + half))
}
retired_bad <- mw_wilson_retired(63, 200, z = -1.96)
chk(retired_bad[1] > retired_bad[2],
    "T46-8 (anti-ceremony): the retired mw_wilson() body silently returns lo > hi for z = -1.96 -- an inverted interval with no error")
fixed_err <- tryCatch({ mw_wilson(63, 200, z = -1.96); "NO ERROR" },
                       error = function(e) conditionMessage(e))
chk(grepl("must be positive", fixed_err),
    "T46-8b: the fixed mw_wilson() stops loudly on the same negative z instead of inverting the interval")

cat("\n-- Adversarial: the same z-sign defect, independently, in mw_diff() (recurs across both interval functions) --\n")
mw_diff_retired <- function(x1, n1, x2, n2, z = 1.96) {
  p1 <- x1 / n1; p2 <- x2 / n2
  d <- 100 * (p1 - p2)
  se <- 100 * sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
  c(d, d - z * se, d + z * se)
}
retired_diff_bad <- mw_diff_retired(136, 200, 90, 200, z = -1.96)
chk(retired_diff_bad[2] > retired_diff_bad[3],
    "T46-9 (anti-ceremony): the retired mw_diff() body silently returns lo > hi for z = -1.96, the identical defect class as T46-8")
fixed_diff_err <- tryCatch({ mw_diff(136, 200, 90, 200, z = -1.96); "NO ERROR" },
                            error = function(e) conditionMessage(e))
chk(grepl("must be positive", fixed_diff_err),
    "T46-9b: the fixed mw_diff() stops loudly on the same negative z instead of inverting the interval")

cat("\n-- Adversarial: mw_trend()'s degenerate NaN is safely absorbed end-to-end by mw_pval() --\n")
deg <- mw_trend(c(5), c(10))
chk(is.na(deg$p) && identical(mw_pval(deg$p), "**[PENDING: P]**"),
    "T46-10: a single-stratum mw_trend() NaN p-value is caught by mw_pval()'s existing is.na() branch and renders as a visible PENDING marker, not NaN text or a crash, in the current, already-shipped pipeline")

cat("\n")
if (fails == 0L) {
  cat("PASS: all Cycle 46 checks passed\n")
} else {
  cat(sprintf("FAIL: %d check(s) failed\n", fails))
}
quit(status = if (fails == 0L) 0L else 1L)
