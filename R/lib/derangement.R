# derange() -- a value-based derangement, used as the negative control for
# name-based record linkage.
#
# Canonical home. link_theses_to_amcb.R computes the permutation control with
# it, and tests/test_cycle30_permutation_derangement.R exercises it. Both
# source THIS file: a test that hand-copies the function tests the copy, and
# stays green while the shipped function regresses.
#
# A plain sample() is a permutation, not a DERANGEMENT: it has ~1 expected
# fixed point regardless of vector length (~62% chance of at least one, for
# n = 10, 30, or 100), so roughly six times in ten a "negative" control built
# on sample() silently leaves at least one row's given_tokens matched back to
# its own true surname -- a real match hiding inside what is meant to be a
# clean null. For a small institution, one such contaminated row is a
# non-trivial share of that institution's reported permutation rate, and it
# understates how much of the real match rate is genuine signal rather than
# name collision.

derange <- function(x, max_tries = 1000L) {
  # length(x) <= 1 has no derangement at all: sample() on a single element
  # always returns that same element (a guaranteed fixed point), so the
  # rejection loop below would never terminate. Neither case can be
  # meaningfully permuted against anything, so return as-is rather than hang.
  if (length(x) <= 1L) return(x)
  # A VALUE-based derangement -- not merely an index-based one -- can be
  # mathematically impossible for a multiset: two identical given_tokens
  # ("John", "John") can NEVER both fail to match themselves under any
  # permutation, so unbounded rejection sampling would hang forever on real
  # first-name data, where repeated names are the norm, not the exception.
  # Capped, with a best-effort fallback (fewest residual matches found) so
  # this can never hang and a residual match is never silently invisible.
  best <- sample(x); best_n <- sum(best == x)
  for (i in seq_len(max_tries)) {
    if (best_n == 0L) return(best)
    perm <- sample(x)
    n <- sum(perm == x)
    if (n < best_n) { best <- perm; best_n <- n }
  }
  if (best_n > 0L) warning(sprintf(
    "derange(): no zero-fixed-point permutation found in %d tries (%d residual match(es) out of %d) -- likely a dominant repeated value; using the best found",
    max_tries, best_n, length(x)), call. = FALSE)
  best
}
