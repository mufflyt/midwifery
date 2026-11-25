# Statistical Methods Verification

## Accuracy and certified-name agreement

Licensure estimates use definitive state-board resolutions as the denominator. Wilson 95% confidence intervals are calculated from `n_accurate/n_definitive` in `artifacts/oig_remake/oig_table2_inaccuracy_subtypes_by_variable.csv`. Unresolved records are reported separately. Sensitivity bounds divide `n_accurate` by all evaluated records for the lower bound and `(n_accurate + n_unresolved)` by all evaluated records for the upper bound.

The AMCB roster verifies the name under which a clinician is certified, not a current legal name. The corresponding estimate is therefore exact certified-name agreement. Its Wilson interval uses resolved records and does not convert name variants into proven identity errors.

## Cross-source agreement

The principal 2026 clinician-directory comparisons are source-to-NPPES comparisons. Wilson intervals in Table 3 use the exact inconsistent-record count and comparable-provider count for each field. These intervals describe binomial record agreement; they do not establish geographic accuracy.

For longitudinal sources pooled across their full windows, `build_f2_f3_uncertainty_denominators.R` constructs one agreement observation per NPI-year, then resamples NPIs as clusters. The point estimator is the ratio of agreeing NPI-years to all comparable NPI-years, preserving provider-year weighting. Percentile 95% intervals use 400 bootstrap replicates with seed 20261114. Annual rows receive Wilson intervals only because each NPI occurs once within a source-year; the manuscript does not label those annual intervals clinician-clustered.

The regenerated `artifacts/agreement_cluster_bootstrap_ci.csv` provenance records `artifacts/canonical_source_records.csv` as input. Its producer and provenance hashes were refreshed on 2026-11-24 before manuscript rendering.

## Persistence of disagreement

The 2021-to-2026 persistence estimate is 563/892 = 63.12%, reported as 63.1%. Its displayed Wilson interval treats the 892 clinicians as independent Bernoulli observations. No repeated clinician contributes more than once to this fixed-cohort endpoint, so a longitudinal cluster correction is not applicable to this estimate. The interval does not account for linkage or classification uncertainty.

## Concurrent multistate enrollment

The 16.1% estimate is `(7,050 multistate concordant + 1,531 multistate discordant) / 53,414 observed provider-years = 16.065%` in `artifacts/state_source_audit_medicaid_classification_by_year.csv`. It measures concurrent enrollment states, not verified practice states.

The classification artifact contains 85,190 provider-years, including 31,776 not observed and 53,414 observed classifications. Within the observed universe, 27,175 are concordant under either the single-state or multistate-concordant class. The separate set-membership audit contains 107,386 comparable NPI-years under a different inclusion rule. These universes are not additive.

## Dependence-aware annual trend

`build_dac_agreement_cluster_trend.R` reads the declared NPPES panel and historical clinician-directory inputs after source-coverage validation. It creates one Bernoulli observation per NPI-year; agreement occurs when the source and NPPES state sets intersect. A linear probability model estimates change in source-to-NPPES agreement by calendar year. Inference uses a CR1 sandwich covariance clustered by NPI and a *t* reference distribution with clusters minus one degrees of freedom.

For 2013-2025, the model includes 44,806 NPI-years from 9,514 NPIs. The slope is -0.170 percentage points per year (95% CI, -0.258 to -0.081), corresponding to a modeled -2.04 percentage-point change across 12 year-to-year intervals. This replaces the aggregate weighted-least-squares slope and its P value. The estimand is a trend in administrative source-to-NPPES agreement, not geographic accuracy.

## Known limitations

- Wilson intervals do not incorporate linkage uncertainty.
- The cluster bootstrap uses 400 replicates, which is adequate for the existing artifact but gives percentile endpoints limited Monte Carlo precision.
- The linear probability trend assumes a linear calendar-time effect and clinician-level independent clusters; it does not model additional source-wide serial shocks.
- No independent source verifies actual practice location, so no geographic agreement interval is an accuracy interval.
