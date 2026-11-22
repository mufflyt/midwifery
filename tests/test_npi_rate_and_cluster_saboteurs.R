#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-21 NPI-rate, cluster-scope and leaver-count fixes
# =============================================================================
# Three defects found by reviewing the Green Journal rewrite. None of them
# raised an error, none of them produced an implausible-looking number, and
# two of them were published:
#
#   N1 A share of RECORDS must divide records by records. The public Medicaid
#      NPI-population rate divided COUNT(DISTINCT NPI) -- providers -- by
#      COUNT(*) -- enrollment spells -- so any state filing many spells per
#      provider read near zero. North Dakota printed 1.0% against a true
#      96.8%, and Supplemental Figure S6 plus the Results prose showed a file
#      that was almost everywhere empty when it is almost everywhere full.
#      The states that looked complete were only the ones filing few spells.
#
#   N2 A CLUSTERED interval has to be computed where a cluster has more than
#      one member. The bootstrap ran inside group_by(source, year), where
#      agree_cell holds exactly one row per NPI, so it resampled singletons
#      and reproduced the i.i.d. interval it was introduced to replace --
#      n_npi_years == n_npis in all 30 rows, and the "clustered" width came
#      out NARROWER than Wilson. The estimator was also a mean of per-NPI
#      means, which targets a different quantity than the NPI-year pct_agree
#      it is printed beside.
#
#   N3 A column named for leavers must be a sub-count of leavers.
#      n_lost_visible_in_nppes never excluded the providers who stayed, so it
#      counted 9,013 of 9,770 observed provider-years as "lost" where 106
#      actually left. Table S4 happened to read the neighbouring column, so
#      nothing printed wrong -- the next consumer to reach for the obviously
#      named one would have published 98% attrition.
#
# Each saboteur mutates the thing it guards and checks the guard fires, so a
# check that cannot fail is reported as a failure of the check.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
source(file.path(root, "tests", "ci_report.R"))
SAB_PREFIX <- "N"

POP  <- "artifacts/medicaid_npi_population_by_state.csv"
BOOT <- "artifacts/agreement_cluster_bootstrap_ci.csv"
PERS <- "artifacts/persistence_denominators.csv"
POP_SRC <- "build_medicaid_npi_population_by_state.R"

art <- function(rel) read.csv(file.path(root, rel), stringsAsFactors = FALSE)

# --- N1 a share of records divides records by records -------------------------
sab(1, "the Medicaid NPI-population rate is segments over segments")

# THE LAW, as a function so the saboteur runs the same code the real artifact
# does. A row passes when the printed percentage is reproduced by its own
# named numerator and denominator.
#
# The guard on the first line is not ceremony. Without it `d$n_segments_with_npi`
# is NULL on the pre-fix artifact, the comparison is numeric(0), and all() of
# nothing is TRUE -- so this check PASSED against the broken file it exists to
# catch. See docs/APPENDIX_checks_that_cannot_fail_2026-11-20.md.
rate_consistent <- function(d) {
  need <- c("pct_segments_with_npi", "n_segments_with_npi", "n_segments")
  if (!all(need %in% names(d)) || !nrow(d)) return(FALSE)
  all(abs(d$pct_segments_with_npi -
          round(100 * d$n_segments_with_npi / d$n_segments, 2)) < 0.011)
}

pop <- art(POP)
chk(all(c("n_segments", "n_segments_with_npi", "n_distinct_npi",
          "pct_segments_with_npi") %in% names(pop)),
    "N1a the artifact names its numerator and denominator separately")
chk(rate_consistent(pop),
    "N1b every published rate is reproduced by n_segments_with_npi / n_segments")

# The defect itself: recompute the column the way the script used to.
sabotaged <- pop
sabotaged$pct_segments_with_npi <-
  round(100 * sabotaged$n_distinct_npi / sabotaged$n_segments, 2)
chk(!rate_consistent(sabotaged),
    "N1c KILLED: the distinct-provider numerator is caught by the same check the real artifact passes")

# NEAR MISS. The two states with no NPI-bearing segment at all have
# n_distinct_npi == n_segments_with_npi == 0, so the defect is invisible in
# exactly the rows the prose quotes. A check that only looked at the extrema
# would have passed on the broken file.
zero <- pop[pop$n_segments_with_npi == 0, ]
chk(nrow(zero) >= 2 && rate_consistent(zero) && rate_consistent(
      transform(zero, pct_segments_with_npi =
                  round(100 * n_distinct_npi / n_segments, 2))),
    "N1d the zero-NPI states agree under BOTH formulas, so the extrema cannot detect this")

# The producer must not reintroduce it. Comments are stripped because this
# file's own header, and the script's, name the forbidden expression.
sql <- paste(ci_code_lines(POP_SRC, root = root), collapse = " ")
chk(!grepl("COUNT\\s*\\(\\s*DISTINCT\\s+NPI\\s*\\)\\s*/\\s*COUNT\\s*\\(\\s*\\*\\s*\\)",
           sql, ignore.case = TRUE),
    "N1e the producer does not divide COUNT(DISTINCT NPI) by COUNT(*)")
chk(grepl("COUNT\\s*\\(\\s*NPI\\s*\\)\\s*/\\s*COUNT\\s*\\(\\s*\\*\\s*\\)",
          sql, ignore.case = TRUE),
    "N1f ... and does divide COUNT(NPI) by COUNT(*)")
chk(grepl("COUNT\\s*\\(\\s*DISTINCT\\s+NPI\\s*\\)\\s+AS\\s+n_distinct_npi",
          sql, ignore.case = TRUE),
    "N1g near miss: reporting COUNT(DISTINCT NPI) as its own column is not the defect")

# --- N2 a clustered interval needs a cluster ----------------------------------
sab(2, "the cluster bootstrap is reported only where a cluster has members")

# THE LAW. A row may carry bootstrap bounds only if its own counts show that
# an NPI contributes more than one NPI-year to it.
#
# `require_any` keeps the real artifact's check from passing because no row
# carries a bootstrap at all; the saboteur below passes FALSE because it is
# asking the narrower question of whether the planted row is caught.
clusters_real <- function(d, require_any = TRUE) {
  if (!all(c("boot_low", "boot_high", "n_npi_years", "n_npis") %in% names(d)))
    return(FALSE)
  b <- !is.na(d$boot_low) & !is.na(d$boot_high)
  if (require_any && !any(b)) return(FALSE)
  !any(b) || all(d$n_npi_years[b] > d$n_npis[b])
}

bt <- art(BOOT)
chk("scope" %in% names(bt) && all(c("year", "pooled") %in% bt$scope),
    "N2a the artifact separates the per-year scope from the pooled scope")
chk(clusters_real(bt),
    "N2b every row carrying bootstrap bounds has more NPI-years than NPIs")

yr <- bt[bt$scope == "year", ]
chk(nrow(yr) > 0 && all(yr$n_npi_years == yr$n_npis) &&
      all(is.na(yr$boot_low)),
    "N2c the per-year rows are singleton-clustered and withhold the bootstrap rather than print it")

# The defect: give the singleton per-year rows bootstrap bounds, which is
# exactly the shape that shipped.
chk(!clusters_real(transform(bt, boot_low = 74, boot_high = 76),
                   require_any = FALSE),
    "N2d KILLED: bootstrap bounds on a singleton-clustered row are caught")

# The consequence the header asserts and the old code contradicted: resampling
# correlated clusters cannot make the interval narrower than assuming
# independence. Deterministic -- the producer fixes the seed.
pl <- bt[bt$scope == "pooled", ]
cat(sprintf("  [CONTROL] N2 design effects: %s\n",
            paste(sprintf("%s=%.2f", pl$source, pl$design_effect),
                  collapse = ", ")))
chk(nrow(pl) >= 4 && all(pl$design_effect >= 1),
    "N2e clustering widens every pooled interval, which the singleton version did not")

# The estimator, at the root. A mean of per-NPI means weights every midwife
# equally; pct_agree weights every NPI-year equally. They differ whenever
# cluster size correlates with agreement, which is the realistic case, so the
# old bootstrap was centred on a quantity its own point estimate did not
# report.
set.seed(1)
npi <- rep(c("a", "b"), times = c(10, 2))     # a: 10 years, b: 2 years
agree <- c(rep(TRUE, 10), rep(FALSE, 2))      # the frequent flyer agrees
npi_year_mean <- mean(agree)                                   # 10/12 = .833
mean_of_means <- mean(tapply(agree, npi, mean))                # (1 + 0)/2 = .5
ratio_est     <- sum(tapply(agree, npi, sum)) / sum(tapply(agree, npi, length))
chk(abs(ratio_est - npi_year_mean) < 1e-9,
    "N2f the ratio estimator targets pct_agree, the number it is printed beside")
chk(abs(mean_of_means - npi_year_mean) > 0.3,
    "N2g KILLED: the mean-of-cluster-means estimator targets a different quantity entirely")
chk(!grepl("vapply\\s*\\(\\s*by_npi\\s*,\\s*mean",
           paste(ci_code_lines("build_f2_f3_uncertainty_denominators.R",
                               root = root), collapse = " ")),
    "N2h the producer no longer averages within-cluster means")

# --- N3 a leaver column is a sub-count of leavers -----------------------------
sab(3, "a column named for leavers counts only leavers")

# THE LAW, applied to every lost-named count rather than to the one column
# that was wrong -- the defect was a missing anti_join, and nothing stops the
# next such column from omitting it too.
leaver_cols <- function(d)
  grep("^n_lost_.*", setdiff(names(d), "n_lost_from_source"), value = TRUE)

leavers_bounded <- function(d) {
  cols <- leaver_cols(d)
  length(cols) == 0 ||
    all(vapply(cols, function(cn)
      all(d[[cn]] <= d$n_lost_from_source, na.rm = TRUE), logical(1)))
}

pr <- art(PERS)
chk(leavers_bounded(pr),
    "N3a every lost-named count is bounded by n_lost_from_source")
chk("n_lost_source_but_in_nppes" %in% leaver_cols(pr) &&
      any(pr$n_lost_source_but_in_nppes > 0),
    "N3b near miss: the real leaver sub-count is non-empty and is not flagged")

# The defect, with the numbers it actually shipped: the column counted
# everyone visible in NPPES at t+1, not everyone who had left.
chk(!leavers_bounded(transform(pr, n_lost_visible_in_nppes = n_observed)),
    "N3c KILLED: a lost-named column holding the observed count is caught")
chk(!("n_lost_visible_in_nppes" %in% names(pr)),
    "N3d the unbounded column is gone from the artifact, not merely unread")
chk(!grepl("n_lost_visible_in_nppes",
           paste(ci_code_lines("manuscript/R/build_stats_catalog.R",
                               root = root), collapse = " ")),
    "N3e ... and its one consumer no longer aggregates it")

saboteur_report(3)
