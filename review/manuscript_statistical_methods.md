# Statistical Methods Verification

## State-board verification and certified-name agreement

State-board verification estimates use definitive board-search resolutions as the denominator. Wilson 95% confidence intervals are calculated from `n_accurate/n_definitive` in `artifacts/oig_remake/oig_table2_inaccuracy_subtypes_by_variable.csv`. Unresolved records are reported separately. Sensitivity bounds divide `n_accurate` by all evaluated records for the lower bound and `(n_accurate + n_unresolved)` by all evaluated records for the upper bound. The producer does not compare a federal license-status field with a board-status field; these are verification yields in selected listings, not federal-field accuracy estimates.

The AMCB roster verifies the name under which a clinician is certified, not a current legal name. The corresponding estimate is therefore exact certified-name agreement. Its Wilson interval uses resolved records and does not convert name variants into proven identity errors.

## Cross-source agreement

The principal 2026 clinician-directory comparisons are source-to-NPPES comparisons. Wilson intervals in Table 3 use the exact inconsistent-record count and comparable-provider count for each field. These intervals describe binomial record agreement; they do not establish geographic accuracy.

For longitudinal sources pooled across their full windows, `build_f2_f3_uncertainty_denominators.R` constructs one agreement observation per NPI-year, then resamples NPIs as clusters. The point estimator is the ratio of agreeing NPI-years to all comparable NPI-years, preserving provider-year weighting. Percentile 95% intervals use 400 bootstrap replicates with seed 20261114. Annual rows receive Wilson intervals only because each NPI occurs once within a source-year; the manuscript does not label those annual intervals clinician-clustered.

The regenerated `artifacts/agreement_cluster_bootstrap_ci.csv` provenance records `artifacts/canonical_source_records.csv` as input. Its producer and provenance hashes were refreshed on 2026-11-24 before manuscript rendering.

## Persistence of disagreement

The historical 563/892 value is not a valid 2026 endpoint. It subtracts two nonexclusive ever-adoption counts from 892 baseline disagreements and does not require observation in 2026. It is retained only as historical arithmetic. The committed censoring audit classifies 366/728 observable records as continuously divergent and 164/892 as right-censored, but its provenance pins an older panel. A new interval is not reported until a cohort-bound, versioned endpoint producer reconciles baseline, reobserved, concordant, discordant, and missing counts.

## Medicaid multistate enrollment

The historical 16.1% estimate is `(7,050 multistate concordant + 1,531 multistate discordant) / 53,414 non-Not-observed classifications = 16.065%` in `artifacts/state_source_audit_medicaid_classification_by_year.csv`. State sets accumulate enrollment at any time during the calendar year, and the denominator includes indeterminate classifications. It is not a simultaneous-enrollment or verified-practice estimate. The same-date artifact reports 7,596 multistate classifications among 32,952 comparable pairs.

The classification artifact contains 85,190 provider-years, including 31,776 not observed and 53,414 classifications outside that category. Within this universe, 27,175 are concordant under either the single-state or multistate-concordant class. The current separate set-membership audit contains 107,193 comparable NPI-years spanning 2013-2024 under a different inclusion rule. These universes are not additive.

## Dependence-aware annual trend

`build_dac_agreement_cluster_trend.R` reads the declared NPPES panel and historical clinician-directory inputs after source-coverage validation. It creates one Bernoulli observation per NPI-year; agreement occurs when the source and NPPES state sets intersect. A linear probability model estimates change in source-to-NPPES agreement by calendar year. Inference uses a CR1 sandwich covariance clustered by NPI and a *t* reference distribution with clusters minus one degrees of freedom.

For 2013-2025, the experimental model includes 44,806 NPI-years from 9,514 NPIs. The slope reproduces as -0.170 percentage points per year (95% CI, -0.258 to -0.081), but 991 contributing NPIs are outside the frozen 16,775-person cohort and the NPI-year series differs from the plotted record-weighted series. It therefore does not replace the manuscript series. The manuscript retains a descriptive aggregate slope without a P value while a cohort-bound dependence-aware analysis remains unresolved.

## Known limitations

- Wilson intervals do not incorporate linkage uncertainty.
- The cluster bootstrap uses 400 replicates, which is adequate for the existing artifact but gives percentile endpoints limited Monte Carlo precision.
- The linear probability trend assumes a linear calendar-time effect and clinician-level independent clusters; it does not model additional source-wide serial shocks.
- No independent source verifies actual practice location, so no geographic agreement interval is an accuracy interval.
