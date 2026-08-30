#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 27 (session-cycle 4 of 24) -- 4 BVA / 3 semantic / 3 adversarial
# =============================================================================
# Target: resolve_org_ambiguity.R's stratified review-sample generator
# (the `set.seed(SEED)` / `slice_sample()` block near the end of the file).
# "RNG reproducibility" is explicitly prioritized and had zero tests of its
# actual sampling mechanics -- only the fallback-tier POLICY around it is
# checked elsewhere (tests/test_open_payments_type2_bulk.R).
#
# The file cannot run end-to-end here (needs the real, gitignored resolution
# candidates), so these tests reproduce the LITERAL sampling pattern -- a
# single global seed followed by sequential slice_sample() calls, one per
# stratum -- exactly as it appears in the source, and verify the two
# properties a reviewer would reasonably assume a "fixed seed for
# reproducibility" comment promises: that a stratum's sample depends only on
# its own data, and only on its own content (not row order).
suppressPackageStartupMessages(library(dplyr))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

SEED <- 20260811L

# Mirrors the FIXED source exactly: seed re-set and arrange(npi) immediately
# before each stratum's slice_sample(), inside the same lapply shape.
sample_strata_fixed <- function(strata) {
  bind_rows(lapply(names(strata), function(s) {
    d <- strata[[s]]
    if (!nrow(d)) return(NULL)
    set.seed(SEED)
    d %>% arrange(npi) %>% slice_sample(n = min(25L, nrow(d))) %>% mutate(review_stratum = s)
  }))
}

# The RETIRED pattern: one set.seed() before the loop, no arrange().
sample_strata_retired <- function(strata) {
  set.seed(SEED)
  bind_rows(lapply(names(strata), function(s) {
    d <- strata[[s]]
    if (!nrow(d)) return(NULL)
    d %>% slice_sample(n = min(25L, nrow(d))) %>% mutate(review_stratum = s)
  }))
}

mk_stratum <- function(n, prefix = "N") {
  data.frame(npi = sprintf("%s%04d", prefix, seq_len(n)), stringsAsFactors = FALSE)
}

cat("\n-- BVA --\n")

s_small <- list(a = mk_stratum(10))
r_small <- sample_strata_fixed(s_small)
chk(nrow(r_small) == 10L,
    "T27-1: a stratum smaller than the 25-row cap returns exactly its own row count, not 25")

s_cap <- list(a = mk_stratum(25))
r_cap <- sample_strata_fixed(s_cap)
chk(nrow(r_cap) == 25L,
    "T27-2: a stratum with exactly 25 rows returns all 25 (the cap boundary, not 24)")

s_zero <- list(empty = mk_stratum(0), full = mk_stratum(5))
r_zero <- sample_strata_fixed(s_zero)
chk(nrow(r_zero) == 5L && !("empty" %in% r_zero$review_stratum),
    "T27-3: a zero-row stratum is dropped entirely, not an error and not an empty group in the output")

s_repeat <- list(a = mk_stratum(50))
r1 <- sample_strata_fixed(s_repeat)
r2 <- sample_strata_fixed(s_repeat)
chk(identical(r1$npi, r2$npi),
    "T27-4: two runs on byte-identical, already-sorted input give byte-identical samples")

cat("\n-- semantic --\n")

strata_small_tel <- list(telephone = mk_stratum(100, "T"), zip9 = mk_stratum(200, "Z"))
strata_big_tel   <- list(telephone = mk_stratum(150, "T"), zip9 = mk_stratum(200, "Z"))
z1 <- sample_strata_fixed(strata_small_tel)$npi[sample_strata_fixed(strata_small_tel)$review_stratum == "zip9"]
z2 <- sample_strata_fixed(strata_big_tel)$npi[sample_strata_fixed(strata_big_tel)$review_stratum == "zip9"]
chk(identical(sort(z1), sort(z2)),
    "T27-5: the zip9 stratum's sample is unaffected by the UNRELATED telephone stratum growing from 100 to 150 rows -- each stratum reproduces from its own data alone")

d_ordered   <- mk_stratum(50)
set.seed(2); d_shuffled <- d_ordered[sample(nrow(d_ordered)), , drop = FALSE]
r_ordered  <- sample_strata_fixed(list(a = d_ordered))
r_shuffled <- sample_strata_fixed(list(a = d_shuffled))
chk(setequal(r_ordered$npi, r_shuffled$npi),
    "T27-6: identical stratum CONTENT in a different row order (as an upstream join with unguaranteed ordering could produce) selects the same actual NPIs")

# Second call site: the LEFT_AMBIGUOUS sample, taken after the stratified
# loop has already consumed RNG draws proportional to however many strata
# were non-empty. Its own re-seed must make it independent of that.
amb_after_one_stratum <- function() {
  set.seed(SEED)
  invisible(mk_stratum(30) %>% arrange(npi) %>% slice_sample(n = 25))  # simulates one prior stratum's draw
  set.seed(SEED)
  mk_stratum(40, "A") %>% arrange(npi) %>% slice_sample(n = 25)
}
amb_after_three_strata <- function() {
  for (i in 1:3) { set.seed(SEED); invisible(mk_stratum(30 + i) %>% arrange(npi) %>% slice_sample(n = 25)) }
  set.seed(SEED)
  mk_stratum(40, "A") %>% arrange(npi) %>% slice_sample(n = 25)
}
chk(identical(amb_after_one_stratum()$npi, amb_after_three_strata()$npi),
    "T27-7: the second call site (LEFT_AMBIGUOUS sample) is independent of how many strata were sampled before it")

cat("\n-- adversarial --\n")

# Anti-ceremony: the RETIRED pattern must actually fail T27-5 and T27-6, or
# neither test is proving anything.
zr1 <- sample_strata_retired(strata_small_tel)$npi[sample_strata_retired(strata_small_tel)$review_stratum == "zip9"]
zr2 <- sample_strata_retired(strata_big_tel)$npi[sample_strata_retired(strata_big_tel)$review_stratum == "zip9"]
chk(!setequal(zr1, zr2),
    "T27-8a (anti-ceremony): the RETIRED single-seed-before-the-loop pattern DOES let zip9's sample change when telephone's size changes")

sample_one_retired <- function(d) { set.seed(SEED); d %>% slice_sample(n = min(25L, nrow(d))) }
ro1 <- sample_one_retired(d_ordered)
ro2 <- sample_one_retired(d_shuffled)
chk(!setequal(ro1$npi, ro2$npi),
    "T27-8b (anti-ceremony): the RETIRED pattern (no arrange) DOES select different NPIs for the same content in a different row order")

# Enforce the sweep: a future refactor must not silently move the re-seed or
# the arrange() away from immediately preceding each slice_sample() call.
# Comment lines are stripped first -- the first draft of this test grepped
# raw source and counted the comment ABOVE this very fix (which explains the
# fix in prose, mentioning "slice_sample()" three times) as call sites,
# finding 5 instead of the real 2.
src_lines_all <- readLines("resolve_org_ambiguity.R", warn = FALSE)
src_lines <- src_lines_all[!grepl("^\\s*#", src_lines_all)]
slice_idx <- grep("slice_sample\\(", src_lines)
chk(length(slice_idx) == 2L,
    sprintf("T27-9 setup: exactly 2 slice_sample() call sites found in production code (got %d)", length(slice_idx)))
guarded <- vapply(slice_idx, function(i) {
  window <- src_lines[max(1, i - 5):i]
  any(grepl("set\\.seed\\(SEED\\)", window)) && any(grepl("arrange\\(npi\\)", window))
}, logical(1))
chk(all(guarded),
    "T27-9: every slice_sample() call site is preceded, within the same pipe chain or the few lines before it, by both set.seed(SEED) and arrange(npi)")

# The LEFT_AMBIGUOUS site specifically, under reordered input -- distinct
# call site from T27-6, which covers the per-stratum loop only.
amb_ordered   <- mk_stratum(60, "A")
set.seed(3); amb_shuffled <- amb_ordered[sample(nrow(amb_ordered)), , drop = FALSE]
sample_amb <- function(d) { set.seed(SEED); d %>% arrange(npi) %>% slice_sample(n = 25) }
chk(setequal(sample_amb(amb_ordered)$npi, sample_amb(amb_shuffled)$npi),
    "T27-10: the LEFT_AMBIGUOUS sample (the second, distinct call site) is also row-order invariant")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
