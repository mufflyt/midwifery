# Manski worst-case bounds and the tipping-point solve for linkage selection
# bias, as reported in the manuscript.
#
# Canonical home. analyze_linkage_selection_bias.R computes the published
# bounds with these, and tests/test_cycle47_selection_bias_invariants.R
# exercises them. Both source THIS file.
#
# Extracted 2026-08-30. They previously lived inside the analysis script and
# closed over its globals (CATS, d, n_roster, n_linked), which made them
# unreachable from a test: that script reads gitignored person-level
# artifacts at top level, so it cannot be sourced on a runner. The cycle-47
# test therefore carried "literal replicas" of both -- reimplementations with
# the globals lifted to parameters -- and so asserted against code no
# published number ever passes through. Taking the parameters explicitly is
# what makes them testable; the arithmetic is unchanged.

# The bound is arithmetic, not a model: of N certificants, k are observed in
# category c and (N - n_obs) are unobserved. The true count is at least k and
# at most k + unobserved.
bounds_for <- function(df, flag = "linked", CATS) {
  n <- nrow(df); obs <- sum(df[[flag]]); unobs <- n - obs
  vapply(CATS, function(cc) {
    k <- sum(df$rurality == cc & df[[flag]], na.rm = TRUE)
    c(observed_pct = if (obs > 0) 100 * k / obs else NA_real_,
      lower_pct = 100 * k / n,
      upper_pct = 100 * (k + unobs) / n)
  }, numeric(3))
}

# Solve for the unobserved share u that moves the roster-wide value to a
# threshold t:  (k + u * unobs) / N = t/100.  Reported as the departure from
# the observed cohort share, in percentage points, because "how different
# would they have to be" is the question a reader actually has.
tipping <- function(k, n_linked, n_roster, threshold_pct) {
  unobs <- n_roster - n_linked
  u <- (threshold_pct / 100 * n_roster - k) / unobs
  c(required_unobserved_pct = 100 * u, departure_pp = 100 * u - 100 * k / n_linked)
}
