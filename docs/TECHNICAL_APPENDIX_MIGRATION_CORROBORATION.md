# Technical Appendix: Independent Corroboration of NPPES State Moves, Spike Transitions vs. Controls

**Repository**: `midwifery`
**Primary script**: [`audit_migration_corroboration_by_transition.R`](../audit_migration_corroboration_by_transition.R)
**Figure script**: [`make_migration_corroboration_figure.R`](../make_migration_corroboration_figure.R)
**Related**: [`docs/TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md`](TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md) (the full 2007-2026 move-rate series, the spike identification, and the five measurement-artifact hypotheses already rejected — this appendix extends it, not duplicates it), [`docs/TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md`](TECHNICAL_APPENDIX_MEDICAID_ENROLLMENT_CONCORDANCE.md) (T-MSIS enrollment-interval semantics this script's Medicaid section reuses)
**Investigation date**: 2026-11-05
**Status**: measurement complete; see §5 for what the result does and does not settle.

---

## 1. What this measures, and why it's not a repeat of the existing appendix

`TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md` already: (a) computes the
full 2007-2026 state-move-rate series, (b) identifies 2017→2018 and
2023→2024 as the two outlier transitions, (c) defines a stricter
"confirmed move" bar (state unchanged the year immediately before *and*
immediately after — an A,A,B,B pattern), and (d) rejects five distinct
measurement-artifact hypotheses (parser disagreement between the classic and
reshaped NPPES formats, byte-level encoding corruption, fallback-value
clustering, abnormal move distance, one-year round-trip blips). That
appendix's own §5 leaves one thing open: no *external* source had been
checked against the specific NPIs that moved.

This script does that — and nothing else from the existing appendix is
re-derived here. For every cohort NPI that changed NPPES practice state in
one of six transitions (the two spikes, plus the same four control
transitions `TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md` §4b already used
for its own hypothesis tests: 2016→2017, 2018→2019, 2022→2023, 2024→2025),
it checks DAC/Physician Compare, PECOS revalidation, and Open Payments for
exact-year corroboration, and Medicaid enrollment-interval arrival/departure
timing via `mysteryroster::enrollment_move_lead_lag()` (the same function,
same interval warehouse, `analyze_address_lead_lag_and_freshness.R` already
uses for a different comparison — reused here, not reimplemented).

## 2. Two corrections from this script's retired predecessor

This script supersedes an earlier 100-NPI sampled version
(`audit_nppes_discontinuity_corroboration.R`, retired the same day). An
external review of that script's first run caught two real bugs, both fixed
here and covered by `tests/test_corroboration_lookup.R`:

- **Never resolve a source's conflicting states by picking the first row.**
  A source can carry more than one row for the same (NPI, year) with
  *different* states — confirmed empirically in this cohort's DAC (413 of
  44,682 NPI-years) and Open Payments (874 of 17,734 NPI-years) extracts,
  e.g. two manufacturers reporting two different recipient addresses the
  same year. `R/lib/corroboration_lookup.R::lookup_state()` treats these as
  uncovered rather than arbitrarily resolved. NPPES itself was checked and
  found clean for this cohort (0 of 215,078 NPI-years ambiguous), so no
  special handling was needed there — verified, not assumed.
- **DAC and PECOS are not independent of each other.** CMS builds the DAC
  ("Doctors and Clinicians") address field from PECOS enrollment data — the
  same system this project's own PECOS revalidation extract reads. DAC and
  PECOS agreeing on a move is one system's record counted twice, not two
  independent witnesses. `is_independent_source_set()` requires at least one
  source outside that shared-lineage pair before counting a transition as
  *independently* corroborated; Open Payments is the only source here that
  qualifies on its own.

Facility/hospital affiliation (`artifacts/dac_facility_affiliations.csv`) is
excluded from this join: it is a single current (2026) snapshot with no year
dimension, so it cannot say which state an NPI was affiliated with in 2017
or 2023. Joining it against a historical transition would borrow precision
the data don't carry, the same reasoning `build_cross_source_comparison.R`
already applies to every single-snapshot source.

## 3. Results

### 3a. Confirmed-move rate — consistent with the existing appendix

Per-NPI reproduction of the A,A,B,B bar, now identified by NPI rather than
only reported as an aggregate percentage:

| transition | group | raw movers | confirmable | confirmed | confirmed % |
|---|---|---:|---:|---:|---:|
| 2016→2017 | control | 213 | 189 | 173 | 91.5% |
| 2017→2018 | **spike** | 324 | 285 | 259 | 90.9% |
| 2018→2019 | control | 260 | 218 | 195 | 89.4% |
| 2022→2023 | control | 314 | 287 | 263 | 91.6% |
| 2023→2024 | **spike** | 516 | 459 | 431 | 93.9% |
| 2024→2025 | control | 179 | 155 | 146 | 94.2% |

Pooled spike (92.7%) vs. pooled control (91.5%), two-proportion test:
**p = 0.42 — no difference.** Consistent with, and an independent
confirmation of, the existing appendix's "92% survival rate, identical in
spike and ordinary years" finding (§4) via a completely separate code path
(per-NPI dplyr here vs. aggregate DuckDB SQL there). Raw move rates computed
here (3.03%, 3.59%) are within 0.1pp of the published series (3.06%, 3.68%)
— the small difference is this script's NPPES dedup (`distinct(npi, year,
state)`, found to need no tie-break since there was never a conflict) vs.
the existing script's `arg_max(..., 1)` (an arbitrary tie-break that happens
not to matter here either, now confirmed rather than assumed).

### 3b. External corroboration — the genuinely new finding, and it's not what a spike/control framing suggests

| transition | group | movers | any-source corroboration | 95% CI | independent (non-DAC/PECOS-only) |
|---|---|---:|---:|---:|---:|
| 2016→2017 | control | 213 | 2.8% | [1.3, 6.0] | 0.0% |
| 2017→2018 | **spike** | 324 | 1.5% | [0.7, 3.6] | 0.0% |
| 2018→2019 | control | 260 | 0.4% | [0.1, 2.1] | 0.0% |
| 2022→2023 | control | 314 | 17.8% | [14.0, 22.4] | 0.3% |
| 2023→2024 | **spike** | 516 | 19.6% | [16.4, 23.2] | 0.8% |
| 2024→2025 | control | 179 | 19.6% | [14.4, 26.0] | 0.6% |

Pooled spike (12.6%) vs. pooled control (10.1%): p = 0.11 — not significant.
But **pooling across these two eras is misleading on its own**: corroboration
rate is not driven by spike status, it's driven by *which three-transition
block a year falls in*. 2016-2019 (pre-PECOS-revalidation-extract coverage)
sits at 0.4-2.8% across all three transitions, spike and control alike;
2022-2025 (PECOS revalidation + denser Open Payments coverage) sits at
17.8-19.6% across all three, again spike and control alike. **Within each
era, the spike transition is indistinguishable from its own neighbors**:
2017→2018 (1.5%) falls between its two control neighbors (2.8%, 0.4%);
2023→2024 (19.6%) is statistically tied with both of its (17.8%, 19.6%).
Neither spike is an outlier within its own coverage era. The pooled p-value
above understates this: it's comparing two different measurement regimes
blended together, not spike-vs-ordinary within a stable regime.

Independent (genuinely non-DAC/PECOS-only) corroboration never exceeds 0.8%
in any transition — DAC and PECOS, once their shared lineage is accounted
for, leave Open Payments as the only source that can supply a second,
independent witness, and Open Payments' own cohort coverage is too sparse
for that to happen often. **This is the headline limitation, not a finding
about the spikes specifically: the current source set cannot independently
verify where in the country a confirmed mover actually went, for any year.**

### 3c. Medicaid enrollment-interval lead/lag

`artifacts/migration_corroboration_medicaid_lead_lag.csv` carries the full
arrival/departure timing breakdown per transition. Pattern is broadly
consistent across all six transitions (destination-state Medicaid enrollment
most often starts in the same year as or within 1 year of the NPPES move;
origin-state enrollment termination is heavily "after the panel move year or
still open-ended" everywhere) — no spike-specific anomaly stands out, but
this measure was not formally tested for a spike/control difference the way
§3a-b were; see §5.

## 4. Figure

`docs/figures/migration_corroboration_by_transition.png` plots §3b directly:
six bars, spike transitions colored distinctly from controls, 95% Wilson CI
error bars. The visual read matches the table — the two eras, not spike
status, separate the bars.

## 5. What this settles, and what it doesn't

**Settled**: the two spikes are not disproportionately unstable (§3a, now
confirmed two independent ways) and are not disproportionately
under-corroborated relative to same-era controls (§3b). Nothing in this
corroboration pass adds evidence toward a measurement-artifact explanation
for either spike, on top of (not instead of) the five hypotheses
`TECHNICAL_APPENDIX_MIGRATION_YEAR_OVER_YEAR.md` §4/§4b already rejected.

**Not settled**: *why* 2022-2025 corroboration coverage is an order of
magnitude denser than 2016-2019 coverage was not investigated here — it is
presumably mostly PECOS revalidation's 2021+ start date plus Open Payments'
own growth, not re-derived from first principles. The Medicaid lead-lag
breakdown (§3c) was reported but not run through a formal spike-vs-control
test the way §3a-b were. And — unchanged from the existing appendix's own
§5 — no mechanism for *why* NPPES move rate itself is elevated in exactly
the two file-format-change years has been identified; this appendix adds
corroboration evidence, not a mechanism.

## 6. Reproducing

```sh
Rscript audit_migration_corroboration_by_transition.R
Rscript make_migration_corroboration_figure.R
Rscript tests/test_corroboration_lookup.R
```

Reads `midwife_panel.csv` and `artifacts/amcb_npi_linkage_FROZEN.csv`
(gitignored, person-level; both must be present locally), the DAC/PECOS/Open
Payments cohort extracts already tracked or produced earlier in
`rebuild_frozen_dependents.R`'s layer 5, and
`/Volumes/MufflySamsung/DuckDB/medicaid_provider_enrollment_segments.duckdb`
(external volume; the Medicaid section is skipped with a message, not a
hard failure, if that volume isn't mounted). The person-level adjudication
table (`artifacts/migration_corroboration_adjudication.csv`) is gitignored;
the per-transition summary, spike-vs-control comparison, and Medicaid
lead-lag CSVs are tracked aggregates.
