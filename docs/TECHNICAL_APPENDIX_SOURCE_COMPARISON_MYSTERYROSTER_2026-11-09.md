# Technical Appendix: Fourteen-Source Practice-State Comparison, No Gold Standard

**Repository**: `midwifery`
**Date**: 2026-11-09
**Primary script**: [`compare_all_sources_mysteryroster.R`](../compare_all_sources_mysteryroster.R)
**Toolkit**: `mysteryroster` 0.3.0 (github.com/mufflyt/mysteryroster), `vignettes/source-comparison-midwifery.Rmd`
**Companion**: [`source-series-reconstruction.md`](source-series-reconstruction.md) — what each series *is*, before any of it is compared
**Predecessor**: [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md) — ten sources, pairwise against NPPES

## What this adds over the 2026-11-03 audit

That audit asked, for ten sources, how often each agrees with NPPES. This one
asks a different question: with **no source treated as truth**, what do
fourteen sources say about each other? The `mysteryroster` toolkit exists for
exactly that framing, and its own vignette is this analysis run on simulated
data calibrated to this project's published findings.

Four sources are new here:

| Source | Why it was not in the 2026-11-03 audit |
|---|---|
| `medicare_part_b` | present in the warehouse, never extracted into the state comparison |
| `medicare_part_d` | **state existed for 2022–2023 only**; 2013–2021 was presence-only until the CMS by-provider files were downloaded on 2026-11-09 |
| `medicaid_spending_prescriber` | the DOGE Medicaid *spending* NDC file, a different dataset from the enrollment segments |
| `medicaid_spending_biller` | same file, the billing-NPI role |

## 1. Sources and tiers

Tier is a statement about what the source *can answer*, not about its quality.
Giving a snapshot a year it does not have would manufacture a time series.

| Source | NPIs | % of 16,898 | Tier |
|---|---|---|---|
| `nppes` | 16,885 | 99.9 | longitudinal |
| `cms_ndh_fhir` | 15,127 | 89.5 | snapshot |
| `medicaid_enrollment` | 13,622 | 80.6 | snapshot ⚠ |
| `pecos_revalidation` | 11,633 | 68.8 | longitudinal |
| `medicare_part_d` | 8,147 | 48.2 | longitudinal |
| `healthgrades` | 7,471 | 44.2 | snapshot |
| `dac_physician_compare` | 4,953 | 29.3 | snapshot |
| `doximity` | 4,647 | 27.5 | snapshot |
| `open_payments` | 3,996 | 23.6 | longitudinal (1 year) |
| `medicare_part_b` | 3,812 | 22.6 | longitudinal |
| `facility_affiliation_ccn` | 1,663 | 9.8 | snapshot |
| `medicaid_spending_prescriber` | 839 | 5.0 | presence only |
| `state_boards_of_nursing` | 648 | 3.8 | snapshot |
| `medicaid_spending_biller` | 101 | 0.6 | presence only |

**16,887 of 16,898 cohort midwives appear in at least one source.** 649 distinct
overlap zones; 612 midwives are known to exactly one source; the most any one
midwife appears in is 12.

⚠ `medicaid_enrollment` is in the snapshot tier but its source file carries
`ENRL_START_DT` and `ENRL_END_DT`. See §4.

**`medicare_part_d_presence` was removed as a separate source on 2026-11-09.**
It carried the eleven Part D years that had no state. Now that they have one it
would be the same npi/year pairs under a second name, and the overlap,
consensus and fusion steps would count Part D twice.

## 2. What was computed

Eight dimensions, thirteen artifacts, all `artifacts/mrost_*.csv`:

| Dimension | Artifact | mysteryroster function |
|---|---|---|
| inventory | `mrost_source_inventory.csv` | — |
| unavailable sources | `mrost_sources_unavailable.csv` | — |
| presence overlap | `mrost_presence_overlap_zones.csv`, `mrost_presence_by_source.csv` | `registry_overlap()`, `overlap_zone_counts()` |
| coverage by year | `mrost_coverage_by_year.csv` | `attribute_coverage()` |
| pairwise agreement | `mrost_agreement_pairwise.csv`, `mrost_agreement_current_snapshot.csv` | `attribute_agreement()` |
| corroboration | `mrost_corroboration.csv` | `attribute_source_corroboration()` |
| odd-one-out | `mrost_odd_one_out_rate.csv` | `attribute_odd_one_out_rate()` |
| consensus tiers | `mrost_consensus_tier.csv` | `attribute_consensus_tier()` |
| churn | `mrost_churn_by_source.csv` | `attribute_churn_rate()` |
| lead/lag | `mrost_lead_lag.csv` | `attribute_lead_lag_matrix()` |
| truth fusion | `mrost_truth_fusion_agreement.csv` | `attribute_truth_fusion()` |

## 3. Results

### 3.1 Pairwise agreement, longitudinal sources

| Pair | NPI-years | Agreement |
|---|---|---|
| `medicare_part_b` ↔ `medicare_part_d` | 13,745 | **100.0%** |
| `nppes` ↔ `medicare_part_b` | 15,709 | 97.1% |
| `nppes` ↔ `medicare_part_d` | 37,832 | 96.6% |
| `medicare_part_b` ↔ `open_payments` | 578 | 94.6% |
| `medicare_part_d` ↔ `open_payments` | 1,695 | 94.2% |
| `nppes` ↔ `open_payments` | 3,898 | 94.0% |
| `pecos_revalidation` ↔ `open_payments` | 3,428 | 90.2% |
| `pecos_revalidation` ↔ `medicare_part_d` | 13,065 | 89.3% |
| `pecos_revalidation` ↔ `medicare_part_b` | 5,807 | 88.8% |
| `nppes` ↔ `pecos_revalidation` | 55,439 | 87.9% |

Part D vs NPPES moved only from 96.2% to **96.6%** while its base grew from
~7,000 NPI-years to 37,832. That stability under a five-fold increase in
evidence is the most informative result in the rebuild: the earlier figure was
not an artifact of two recently-refreshed years.

### 3.2 Truth fusion (majority) vs each source

16,658 entity-years; 367 abstained (2.2%) and are excluded; 16,291 fused.

| Source | n comparable | Agreement with fused |
|---|---|---|
| `medicare_part_b` | 1,491 | 98.4% |
| `medicare_part_d` | 3,787 | 98.0% |
| `state_boards_of_nursing` | 641 | 97.5% |
| `facility_affiliation_ccn` | 1,641 | 97.4% |
| `nppes` | 15,968 | 97.3% |
| `healthgrades` | 7,343 | 96.9% |
| `doximity` | 4,566 | 96.2% |
| `dac_physician_compare` | 4,851 | 95.2% |
| `open_payments` | 3,923 | 94.9% |
| `cms_ndh_fhir` | 14,827 | 93.3% |
| `pecos_revalidation` | 9,546 | 92.9% |
| `medicaid_enrollment` | 13,289 | **77.5%** |

### 3.3 Odd-one-out, consensus, churn

| Source | n eligible | odd-one-out rate |
|---|---|---|
| `medicaid_enrollment` | 13,164 | **0.166** |
| `cms_ndh_fhir` | 14,300 | 0.029 |
| `pecos_revalidation` | 9,738 | 0.022 |
| `dac_physician_compare` | 4,953 | 0.012 |
| `open_payments` | 3,990 | 0.011 |
| `state_boards_of_nursing` | 641 | 0.011 |
| `doximity` | 4,585 | 0.009 |
| `nppes` | 14,694 | 0.009 |
| `healthgrades` | 7,405 | 0.008 |
| `facility_affiliation_ccn` | 1,663 | 0.002 |
| `medicare_part_d` | 3,833 | 0.001 |
| `medicare_part_b` | 1,514 | **0.000** |

**Consensus**: unanimous 11,252 (70.3%), majority 4,177 (26.1%), split 575 (3.6%).

**Churn** (how often a source's own value flips between adjacent years):
`pecos_revalidation` 2.9% (45,044 transitions), `nppes` 2.1% (199,895),
`medicare_part_d` 1.9% (28,357), `medicare_part_b` 1.6% (11,682).

### 3.4 Lead/lag against NPPES

| Source | paired transitions | discordant at *t* | B adopts A at *t+1* | A reverts to B | persistent |
|---|---|---|---|---|---|
| `pecos_revalidation` | 43,746 | 5,264 | 5.0% | 10.5% | **79.4%** |
| `medicare_part_d` | 27,153 | 777 | 0.9% | 60.2% | 35.1% |
| `medicare_part_b` | 11,046 | 240 | 1.7% | 60.8% | 34.6% |

PECOS holding at 79.4% persistent discordance while Part D sits at 35.1% over
ten times the evidence is the clearest form of the PECOS-lags finding so far.

**Read §4 before quoting any of these transition counts.**

## 4. Limitations

### 4.1 Transition counts are not independent observations

`artifacts/source_series_independence.csv`, produced by
[`audit_source_series_independence.R`](../audit_source_series_independence.R):

| Source | Dated source artifacts | Distinct years | Intervals | Transitions |
|---|---|---|---|---|
| `nppes` | 20 dissemination files | 20 | 19 | 4,261,806 |
| `pecos_revalidation` | 41 monthly releases → 6 year-end values | 6 | **5** | 45,044 |
| `medicare_part_d` | 12 annual publications | 12 | 11 | 28,357 |
| `medicare_part_b` | 12 annual publications | 12 | 11 | 11,682 |
| `open_payments` | 1 file | 1 | **0** | 0 |

No series here is pseudo-longitudinal — every year's value comes from a file
published in or for that year, and the interior-gap rates in
`artifacts/source_series_interior_gaps.csv` confirm nothing is carried forward.
But Part D's 28,357 transitions are **11 intervals × ≈2,578 recurring
midwives**; the independent time points number **12**. The Wilson intervals in
`mrost_churn_by_source.csv` treat transitions as independent and are therefore
anticonservative.

**The 79.4% PECOS persistence rests on 5 transition intervals** (2021→22 …
2025→26). It is sound within that window and says nothing about 2013–2020,
where PECOS has no data at all.

### 4.2 Part B and Part D are one source counted as two

100.0% agreement on 13,745 NPI-years — up from 2,423 before the Part D
rebuild, so this inflation **grew by 5.7×** on 2026-11-09. Both are Medicare
FFS claims products describing the same enrollment of record.
`attribute_claims_collapse_lineage()` exists in `mysteryroster` for this case
and **is not applied**. Consensus tiers, odd-one-out rates and truth fusion all
count Medicare twice.

### 4.3 `medicaid_enrollment` is reduced as a snapshot though it is longitudinal

Its source carries `ENRL_START_DT` and `ENRL_END_DT`. Expanding by date-range
overlap yields **119,527 cohort NPI-years, 2013–2024**. The whole-file modal
state used here differs from the year-specific state **14.4%** of the time —
**30.5% in 2013**, 5.7% in 2024 — and **34.9%** of NPI-years genuinely carry
more than one state. **Its 0.166 odd-one-out rate and 77.5% fusion agreement
are therefore substantially artifacts of this reduction** and must not be read
as evidence that Medicaid enrollment data is unreliable.

### 4.4 Coverage gaps that are real

- **DAC history is unavailable in this clone.** `extract_physician_compare_historical_midwives.R` needs five NBER-mirror CSVs that are absent, and both documented download routes now return 403. Recorded in `mrost_sources_unavailable.csv`. Nothing here measures DAC's lag.
- **Open Payments has only 2024 locally**, so all four of its lead/lag pairings are skipped with explicit messages.
- **NPPES snapshots are 6.0–19.1 months apart** (median 12.0). Every rate above treats an adjacent-year pair as one period.

## 5. Reproduction

```sh
Rscript download_cms_by_provider_files.R          # idempotent; writes a sha256 manifest
Rscript extract_medicare_part_b_d_cohort_states.R
Rscript audit_source_series_independence.R
cp compare_all_sources_mysteryroster.R "$SCRATCH/cmp.R" && Rscript "$SCRATCH/cmp.R"
```

The copy is not superstition. `Rscript` evaluates a file expression-by-expression
from an open handle, so editing a script during its own run shifts the read
position; doing that on 2026-11-09 aborted this comparison at step 8 with a
spurious `unexpected symbol` error.

Person-level outputs are gitignored; the thirteen aggregate `mrost_*` tables
are tracked, each with a `.provenance.json` recording input and code sha256s.
