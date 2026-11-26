# Technical appendix: federal database accuracy review disposition

**Date:** 2026-11-25

**Status:** submission blocked pending P0 reanalysis

**Primary review:** [`review/independent_reviewer_audit.md`](../review/independent_reviewer_audit.md)

This appendix is the durable, reader-facing disposition of the independent
review of `manuscript/federal_database_accuracy.qmd`. It distinguishes values
that reproduce arithmetically from interpretations that remain unsupported.
Passing the manuscript mutation tests is not equivalent to scientific
validation.

## Reproducible facts

| Construct | Reproduced result | Interpretation |
|---|---:|---|
| AMCB frame | 22,357 certification records | Record frame, not active practitioners |
| Primary linkage tier | 14,956 | Midwifery-taxonomy links |
| Sensitivity linkage tier | 1,819 | Nursing-taxonomy-only additions |
| Analytic linkage cohort | 16,775 unique NPIs | 14,956 + 1,819 |
| Excluded dispositions | 5,582 | 2,613 no candidate + 2,689 tied + 109 contested + 8 unresolved component + 163 held out |
| 2026 NPPES–DAC any-variable disagreement | 4,267 / 5,877 (72.6%) | Any shared-value rule in the active-primary comparison population |
| ZIP-code disagreement | 2,725 / 5,877 (46.4%) | Agreement, not geographic accuracy |
| State disagreement | 546 / 5,876 (9.3%) | Agreement, not geographic accuracy |
| Open Payments 2025 | 21,021 / 21,759 comparable records, 4,311 NPIs | Source-record-weighted, not a unique-clinician fraction |
| Medicaid any-time set analysis | 107,193 comparable NPI-years, 2013–2024 | Annual state-set membership; not simultaneous enrollment |
| Medicaid snapshot analysis | 32,952 comparable pairs; 7,596 multistate | Same-date enrollment comparison |

## Constructs that changed after review

### State-board verification

The fractions 1,153/1,226 and 1,796/1,940 reproduce. They measure the share
of resolved, selected federal listings for which the board search returned a
qualifying license outcome. The producer does not compare a federal
license-status field against a board-status field. The NPPES group is the
active primary linkage tier; the PECOS group is a semi-join of the same board
outcomes to PECOS enrollment. These estimates must be described as
state-board verification yield among selected listings, not database-field
accuracy. Across seven states, 1,253/3,193 records are unresolved; extreme
assumptions yield 56.2%–95.5%.

### Longitudinal persistence

The historical 563/892 value is not a verified 2026 endpoint. It subtracts
two non-exclusive “ever adopted the other source's baseline value” events
from the baseline cohort. A separate committed censoring audit classifies
366/728 observable records as continuously divergent and 164/892 as
right-censored, but its input sidecar pins an older panel. The independent
reviewer's current-panel calculations are diagnostics, not publication
artifacts. No endpoint percentage should be promoted to the abstract until a
versioned, cohort-bound producer reports the baseline, reobserved,
concordant, discordant, and missing counts together.

### Medicaid geography

The historical 8,581/53,414 (16.1%) calculation combines two multistate
classes in a seven-year active-primary frame. The state sets are accumulated
at any time during a calendar year, so the result does not establish
simultaneous enrollment or practice in multiple states. The 53,414
denominator also includes 18,898 indeterminate classifications. Prefer the
same-date artifact for simultaneity questions and label any-time membership
analyses explicitly. Neither enrollment construct observes clinical
practice.

### Longitudinal trend

The CR1 clustered calculation reproduces at −0.16975 percentage points per
year (95% CI −0.25823 to −0.08127; 44,806 NPI-years, 9,514 NPIs), but 991
contributing NPIs are outside the frozen 16,775-person cohort and its
NPI-year series differs from the plotted record-weighted series. It is not a
valid replacement for the manuscript trend until its population, series, and
figure agree. The manuscript therefore retains only a descriptive
record-weighted slope and makes no inferential claim.

## Release blockers

1. Produce a cohort-bound, versioned 2021–2026 endpoint with attrition.
2. Rebuild the trend on the declared cohort or mark it unresolved throughout.
3. Reframe every state-board result as verification yield, with the selection
   population and unresolved denominator visible.
4. Replace practice/concurrency language in Medicaid results with the timing
   definition actually measured.
5. Expand manuscript gates so exact protected numerators, time windows,
   interval types, and every cohort-flow branch are checked against source
   artifacts and rendered output.
6. Rerender and visually inspect a new timestamped Word file after these
   analytical changes.

Until those conditions are met, the manuscript is **not submission-ready**.
