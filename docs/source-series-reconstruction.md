# Source-Series Reconstruction: How Each Historical Series Is Built

**Repository**: `midwifery`
**Written**: 2026-11-09
**Scope**: every source consumed by [`compare_all_sources_mysteryroster.R`](../compare_all_sources_mysteryroster.R)
**Related**: [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md)

## Why this document exists

The temporal analyses in this project — churn, lead/lag, persistence of
discordance — are only as valid as the claim that a source's 2016 value was
actually observed in 2016. A series assembled by carrying one contemporary
address backward across twelve years would produce thousands of apparent
transitions from a single measurement, and every statistic computed on it
would be an artifact of the reconstruction rather than a fact about midwives.

This document records, for each source, **what was observed when**, so that a
reader can tell a measurement from a reconstruction without reading the code.

**No reconstructed observation in this project may be described as an
independent historical measurement.** Where a value is carried, inferred, or
derived from a later snapshot, it is labelled as such below and in the
artifact's own provenance sidecar.

---

## 1. Evidence classes

Every source-year in this project falls into exactly one class. The class, not
the row count, determines what the series may be used for.

| Class | Meaning | Valid for |
|---|---|---|
| **A — Directly observed** | A file published at time *t* records the value at time *t*. The year comes from the publication's own date. | Longitudinal change analysis |
| **B — Retrospectively reported** | A file published at time *t* carries an effective-date range covering earlier periods. The earlier value is real but was reported later and is subject to left-censoring and survivorship. | Sensitivity analysis; longitudinal only with the censoring stated |
| **C — Imputed / carried** | A value assigned to a year in which nothing was observed, by interpolation or carry-forward. | Nothing longitudinal. Must be flagged in output. |
| **D — Contemporary snapshot only** | One observation, at one time, with no history. | Cross-sectional agreement only |

**This project contains no class C series.** No reconstruction function in the
pipeline interpolates, carries forward, or back-fills a missing year. A midwife
absent from a source in a given year is absent from that source's rows for that
year. This is a deliberate property, enforced by test (§7) and visible in the
data: a carried-forward series cannot contain **interior gaps**, years in the
middle of a midwife's own observed span where she has no row. Measured
2026-11-09:

| Series | Midwives | With interior gaps |
|---|---|---|
| `nppes` | 472,327 | 1,408 (0.3%) |
| `pecos_revalidation` | 11,633 | 121 (1.0%) |
| `medicare_part_b` | 3,812 | **818 (21.5%)** |
| `medicare_part_d` | 8,147 | **2,209 (27.1%)** |

Over a quarter of Part D midwives stop billing for a year or more and resume.
Under carry-forward every one of those gaps would be silently filled, and the
churn and lead/lag denominators would be larger and wrong.

---

## 2. Source inventory

### 2.1 Class A — directly observed

#### `nppes`

| | |
|---|---|
| **Source files** | `/Volumes/MufflySamsung/nppes_historical_downloads/` — 46 NPPES dissemination archives, 2007–2026 |
| **Producer** | [`build_midwife_panel.R`](../build_midwife_panel.R) → `midwife_panel.csv` |
| **Dated observations** | **20**, one per year, 2007–2026 |
| **Observation dates** | 2007-11-12, 2008-05-12, 2009-06-07, 2010-02-08, 2011-04-11, 2012-04-09, 2013-04-07, 2014-04-13, 2015-04-12, 2016-04-10, 2017-04-09, 2018-07-08, 2019-04-07, 2020-07-12, 2021-04-11, 2022-04-10, 2023-04-09, 2024-04-07, 2025-11-09, 2026-08-09 |
| **Year assignment** | `snap_year <- as.integer(substr(snap_date, 1, 4))` — from the file's own release date encoded in its filename. Never from a data column, never assigned by position. |
| **Multiple files in one year** | The **earliest** file in each year wins (`keep <- !duplicated(snap_year)` after sorting), so a year with no release stays empty rather than being filled by a neighbouring year's file. |
| **Keys** | `npi`; name variants retained as separate rows for surname-history matching |
| **Output** | `midwife_panel.csv` — `npi`, `snapshot_year`, `snapshot_date`, `practice_state`, + name fields |
| **Cohort rows** | 216,823 rows / 16,885 NPIs (full panel: 4,735,519 rows / 472,327 NPIs across the midwifery + nursing taxonomy pool) |
| **Missing data** | A midwife not enumerated in a snapshot has no row for that year. Not imputed. |

**Verified 2026-11-09**: every `snapshot_year` maps to exactly one distinct
`snapshot_date`; zero years carry two. The panel is twenty real files.

> **Limitation — unequal intervals.** NPPES release months are not uniform. The
> gap between consecutive snapshots ranges from **6.0 to 19.1 months**
> (median 12.0). The 2024→2025 interval is **19.1 months**; 2007→2008 is 6.0;
> 2018→2019, 2020→2021 and 2025→2026 are each 9.0. A "one-year transition" in
> churn and lead/lag is therefore **not a constant duration**, and a source
> compared against NPPES inherits that irregularity. See §8, assumption A1.

#### `medicare_part_b`

| | |
|---|---|
| **Source files** | Warehouse `medicare_part_b_{2013..2023}` (12 tables); `/Volumes/MufflySamsung/medicare_part_b_by_provider/part_b_by_provider_2024.csv` |
| **Producer** | [`extract_medicare_part_b_d_cohort_states.R`](../extract_medicare_part_b_d_cohort_states.R) → `pull_states()` |
| **Dated observations** | **12**, one annual CMS publication per data year, 2013–2024 |
| **Year assignment** | Supplied by the caller from which table/file was opened. The by-provider file carries no year column — the year is a property of the file. |
| **Keys** | `Rndrng_NPI` ↔ cohort `npi`, both trimmed and cast to VARCHAR |
| **State column** | `Rndrng_Prvdr_State_Abrvtn` |
| **Output** | `artifacts/cohort_midwives_part_b_state_by_year.csv` — `npi`, `year`, `state`, `n_states_this_year` |
| **Rows** | 16,463 NPI-years / 3,812 NPIs |

#### `medicare_part_d`

| | |
|---|---|
| **Source files** | `/Volumes/MufflySamsung/medicare_part_d_by_provider/part_d_by_provider_{2013..2021,2024}.csv` (10 files, downloaded 2026-11-09); warehouse `medicare_part_d_{2022,2023}` |
| **Producer** | same as Part B |
| **Dated observations** | **12**, 2013–2024 |
| **State column** | `Prscrbr_State_Abrvtn` |
| **Output** | `artifacts/cohort_midwives_part_d_state_by_year.csv` |
| **Rows** | 39,235 NPI-years / 8,147 NPIs |

> **Why the split source.** The warehouse holds 2013–2021 only as the
> `*_standardized` cut, which drops the state column entirely. Those eleven
> years entered this project as presence-only until the CMS by-provider files
> were downloaded on 2026-11-09. The standardized cut is the **same universe**,
> not a subset — 2021 standardized holds 3,443 cohort NPIs and the 2021
> by-provider file holds the same 3,443 — so this added columns to rows the
> pipeline already had, and added no NPI-years that were not already known.
> 2022–2023 are read from the warehouse because `medicare_part_d_<year>` *is*
> the by-provider file, same product and same column names.

#### `pecos_revalidation`

| | |
|---|---|
| **Source** | `cms_revalidation.duckdb`, table `revalidation_reassignment`, ingested by `archive_revalidation_reassignment.R` |
| **Producer** | [`extract_pecos_revalidation_state_history.R`](../extract_pecos_revalidation_state_history.R) |
| **Dated observations** | **41 monthly CMS releases**, 2021-12 through 2026-11 |
| **Year assignment** | The **last vintage within each calendar year** — a year-end snapshot. 41 monthly observations collapse to **6 year-level values**. |
| **Output** | `artifacts/pecos_revalidation_cohort_state_by_year.csv`; the uncollapsed monthly panel is also written to `artifacts/pecos_revalidation_cohort_state_monthly.csv` |
| **Rows** | 56,798 NPI-years / 11,633 NPIs, 2021–2026 |

> **Limitation.** The 2026 "year-end" value is **2026-11**, not December, because
> that is the last release available. It is not month-comparable with the
> December values of 2021–2025. See §8, assumption A3.

#### `open_payments`

| | |
|---|---|
| **Source files** | `artifacts/cohort_midwives_open_payments_general_<year>.csv` — in this clone, **2024 only** |
| **Year assignment** | `str_extract(basename(f), "\\d{4}")` — **from the filename**, not from a data column |
| **Rows** | 3,996 NPI-years / 3,996 NPIs, 2024–2024 |

> **Limitation.** Open Payments occupies the longitudinal tier with exactly one
> year, so it yields **zero** consecutive-year transitions. All four of its
> lead/lag pairings are skipped by `attribute_lead_lag_matrix()` with an explicit
> message rather than silently. A single-year source in the longitudinal tier is
> a snapshot wearing a year label. See §8, assumption A4.

### 2.2 Class B — retrospectively reported

#### `medicaid_enrollment` (DOGE T-MSIS enrollment segments)

| | |
|---|---|
| **Source file** | `/Volumes/MufflySamsung/doge_opendata/medicaid_provider_enrollment_segments_2026_07_24/medicaid-provider-enrollment-segments.parquet` |
| **Schema** | `NPI`, `STATE_CD`, `ENRL_START_DT` (DATE), `ENRL_END_DT` (DATE), `ENRL_STATUS_CD/DESC`, `ENRL_PLAN_CD/DESC`, `PRVDR_TYPE/DESC` |
| **Size** | 65,970,112 rows; 162,984 for this cohort |
| **Class** | **B** — one file, published 2026-07-24, carrying date ranges that reach back years |

> **⚠ The pipeline currently treats this class-B source as class D.**
> `compare_all_sources_mysteryroster.R` places it in the SNAPSHOT tier and
> reduces it with `one_per_npi()` to a single whole-file modal state. The file
> carries start and end dates and *can* be expanded by date-range overlap into
> one state per NPI-year. Measured 2026-11-09:
>
> - expansion yields **119,527 cohort NPI-years, 2013–2024**, same 13,622 NPIs
> - the whole-file modal state differs from the year-specific state **14.4%**
>   of the time overall — **30.5% in 2013**, 20.0% in 2017, 7.6% in 2022,
>   **5.7% in 2024**
> - **34.9%** of NPI-years genuinely carry more than one state
>
> **CORRECTED 2026-11-10.** An earlier version of this section predicted that
> the 0.166 odd-one-out rate was "substantially an artifact" of the modal
> reduction. The expansion was implemented and the prediction was wrong:
> odd-one-out moved 0.166 → **0.163** and fusion agreement 77.5% → **77.6%**.
> The reduction error is real (14.4% of NPI-years) but concentrated in
> 2013–2017, and those two metrics are computed on the current-snapshot slice
> where the old and new states already agreed to within 5.7%.
>
> **The real cause is the estimand, not the source.** Agreement with NPPES
> falls monotonically with the number of concurrent state enrolments a midwife
> holds that year (107,386 comparable NPI-years):
>
> | concurrent enrolments | NPI-years | agreement with NPPES |
> |---|---|---|
> | 1 | 67,618 | **87.1%** |
> | 2 | 27,929 | 57.8% |
> | 3 | 8,444 | 45.7% |
> | 4 | 2,287 | 39.9% |
> | 5+ | 1,108 | **36.4%** |
>
> A midwife enrolled in five state Medicaid programs does not have one
> practice state. Forcing a modal pick and comparing it against NPPES's single
> self-report produces ~36% agreement by construction. Restricted to
> single-state midwives, Medicaid agrees with NPPES at 87.1% — comparable to
> DAC and better than PECOS. **`medicaid_enrollment` should not be read as an
> unreliable source; it is answering a legitimately multi-valued question with
> a single-valued comparator.** Multi-state enrolment rises 19.4% (2013) to
> 41.0% (2024), so this grows over the panel.
>
> **RESOLVED 2026-11-10 — it was the comparator, not the estimand.** The
> paragraph above attributed the disagreement to multi-state practice being a
> multi-valued question. That was half right and stopped one step short. The
> reduction did not merely pick one of several true states — it **discarded the
> others entirely**, 59,380 of 178,907 memberships (33.2%), emitting them
> nowhere. The test being run was "does the other source equal my one pick?"
> when the answerable question was "does the other source name a state she was
> enrolled in?"
>
> On the same 107,386 comparable NPI-years: equality **74.7%**, set membership
> **88.5%**, rising to **91.4%** in 2024. 14,815 NPI-years were newly scored as
> agreeing. Medicaid is not an outlier and never was. The full enrolled set is
> now emitted as `medicaid_enrollment_cohort_state_footprint.csv`; the
> single-valued series is unchanged, so no assignment moved. See
> [`audit_medicaid_set_membership.R`](../audit_medicaid_set_membership.R).
>
> This does not show that either source names the true practice location. It
> shows the two are consistent once compared correctly.
>
> What the expansion DID change: Medicaid now enters the all-years metrics for
> the first time — 94,103 paired transitions, 25.3% discordant at t, **85.2%
> persistent** (the highest of any source, above PECOS's 79.4%) and **4.6%
> churn** (also the highest). Both follow from the same multi-valued estimand:
> a modal pick among several concurrent states flips whenever the segment mix
> shifts, without the midwife moving.
>
> **Left-censoring, if expanded.** `min(ENRL_END_DT)` is **2018-01-01**: no
> segment that closed before 2018 appears in the file. Years 2013–2017 see only
> providers still enrolled in 2018, which is survivorship. Start dates are also
> dirty — 1,955,673 rows at 1900-01-01, plus values at 0001-01-01 and 1753.
> An expanded series is **class B**, suitable for sensitivity analysis, and is
> not interchangeable with the class-A series.

### 2.3 Class D — contemporary snapshot only

| Source | File | NPIs | Reduction |
|---|---|---|---|
| `cms_ndh_fhir` | `artifacts/cms_ndh_midwives.csv` | 15,127 | `one_per_npi()` |
| `dac_physician_compare` | `dac_midwives.csv` (2026 pull) | 4,953 | `one_per_npi()` |
| `healthgrades` | `healthgrades_midwives.csv` | 7,471 | `one_per_npi()` |
| `doximity` | `artifacts/doximity_public_matched.csv` | 4,647 | `one_per_npi()` |
| `facility_affiliation_ccn` | `artifacts/dac_facility_affiliations.csv` | 1,663 | `one_per_npi()` |
| `state_boards_of_nursing` | `artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv` | 648 | `one_per_npi()` |

These carry **no year** and are excluded from every temporal statistic. They
enter only presence overlap, current-snapshot agreement, consensus tiers and
truth fusion.

**DAC history is unavailable in this clone** and is recorded as such in
`artifacts/mrost_sources_unavailable.csv`:
`extract_physician_compare_historical_midwives.R` requires five NBER-mirror
CSVs under `data/raw/cms_physician_compare/` that are absent. Both documented
download routes now return HTTP 403 (NBER `/data/compare/physician/`, and
`data.cms.gov/provider-data/*` behind an Akamai block). Nothing in these
results measures DAC's lag.

### 2.4 Source-by-year coverage

Cohort NPIs carrying a state in each source-year. Generated from
`artifacts/mrost_coverage_by_year.csv`; an em dash means the source has no
observation for that year at all, never an imputed zero.

| source | 2013 | 2014 | 2015 | 2016 | 2017 | 2018 | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `medicare_part_b` | 1,080 | 1,161 | 1,251 | 1,336 | 1,406 | 1,477 | 1,555 | 1,343 | 1,465 | 1,422 | 1,452 | 1,515 | — | — |
| `medicare_part_d` | 2,747 | 2,875 | 2,951 | 3,098 | 3,129 | 3,260 | 3,370 | 3,393 | 3,443 | 3,482 | 3,644 | 3,843 | — | — |
| `nppes` | 8,550 | 9,114 | 9,702 | 10,280 | 10,865 | 11,622 | 12,061 | 12,858 | 13,284 | 13,957 | 14,648 | 15,352 | 16,375 | 16,326 |
| `open_payments` | — | — | — | — | — | — | — | — | — | — | — | 3,996 | — | — |
| `pecos_revalidation` | — | — | — | — | — | — | — | — | 8,317 | 8,954 | 9,474 | 9,877 | 10,421 | 9,755 |

Denominator (midwives alive and enumerated) grows from 8,684 in 2013 to 16,409
in 2026, so a flat count is a falling percentage. The six class-D snapshot
sources are absent from this table by construction: they carry no year.

---

## 3. Reconstruction algorithms

### 3.1 `pull_states()` — modal state per NPI-year

Defined in `extract_medicare_part_b_d_cohort_states.R`.

**Signature**: `pull_states(src, npi_col, state_col, year)` → `data.frame(npi, year, state, n_states_this_year)`, or `NULL`.

**Rule**: among that NPI's rows in that year's file, take the state appearing on
the most rows; break ties **alphabetically**.

**Determinism**: total. The ordering key `(COUNT(*) DESC, state ASC)` admits no
ties, so a rerun is byte-identical. This is required, not cosmetic — the output
feeds a provenance ratchet that treats a changed hash as a changed finding.

**Future information**: structurally impossible. Each call reads exactly one
year's file and is passed that year as a literal. No call can see another year.

**Missing years**: left missing. A year whose file is absent logs `absent,
skipped` and returns `NULL`, which `bind_rows()` drops.

**Worked example** — NPI 1234567890 in a 2013 by-service file:

| row | state |
|---|---|
| 1 | CO |
| 2 | CO |
| 3 | WY |

→ `npi=1234567890, year=2013, state="CO", n_states_this_year=2`.

For a **by-provider** file there is one row per NPI, so the reduction is a
no-op and `n_states_this_year` is 1. It is applied anyway so that no year in the
series is reduced by a different rule than its neighbours — a second code path
for the downloaded years is how a series acquires a seam at 2021/2022 that
reads as a finding.

**State validation**: `clean_state()` drops non-US states. In the 2026-11-09
rebuild this removed exactly one NPI — 1013060656, a prescriber in Dar Es
Salaam carrying the foreign code `ZZ`, in 2015 and 2016.

### 3.2 PECOS year-end collapse

Defined in `extract_pecos_revalidation_state_history.R`.

**Rule**: for each `(npi, year)`, take the row from the **last monthly vintage
within that calendar year**.

**Determinism**: total, in two steps. Vintage strings are `YYYY-MM` and sort
lexically, so `max(vintage)` is unambiguous. Where one `(npi, vintage)` carries
several simultaneous group-practice states — about **10%** of pairs, e.g.
ME/VT/NH in the same month, which are concurrent enrollments rather than moves
— `arrange(pecos_state) %>% slice(1)` takes the alphabetically first. That
tie-break is deterministic **by content**: before it was added (2026-11-06),
the winner depended on incidental SQL row order, which differed between
warehouse re-ingests of identical data and moved published move rates by more
than a point between runs.

**Future information**: none. A year's value comes from a vintage inside that
year.

**Worked example** — NPI 9876543210 with vintages `2023-01 → CO`, `2023-06 → CO`, `2023-12 → NM` yields `year=2023, state="NM"`. The two earlier observations are
discarded at year resolution and preserved in the monthly panel.

### 3.3 `one_per_npi()` — snapshot collapse

Defined in `compare_all_sources_mysteryroster.R`. Same modal rule, no year
grouping, for sources that have no year.

**A longitudinal source must never be passed through this function.** Doing so
collapses its years into one value — see the `medicaid_enrollment` warning in
§2.2, which is exactly this error.

### 3.4 Medicaid date-range expansion (specified, **not currently applied**)

For a segment with `ENRL_START_DT` *s* and `ENRL_END_DT` *e*, the segment
covers year *Y* when `s ≤ Dec 31 of Y` and `coalesce(e, '9999-12-31') ≥ Jan 1
of Y`. Modal state per `(npi, year)` as in §3.1.

**Worked example** — NPI 5555555555, segment CO 2015-03-01 → 2019-06-30, and
segment NM 2019-01-01 → open: 2015–2018 → CO; 2019 → tie CO/NM broken
alphabetically → CO, `n_states_this_year = 2`; 2020–2024 → NM.

This is the specification for the pending class-B series. It is documented here
so the algorithm is on record before it is run. **The present comparison does
not use it.**

---

## 4. Reconstructed transitions vs independently dated observations

A *transition* is one midwife's adjacent-year pair. It is **not** an
independent observation. The table below gives both numbers so no statistic in
this project can be read as having more evidence behind it than it does.

It is produced by [`audit_source_series_independence.R`](../audit_source_series_independence.R)
into `artifacts/source_series_independence.csv` and
`artifacts/source_series_interior_gaps.csv`, so it is rebuilt rather than
retyped. The NPPES row counts every observation in the panel, including rows
whose state is blank — this audit counts how many times a midwife was
*observed*, and a missing value is still an observation.

| Source | Dated source artifacts | Distinct years | Year intervals | NPI-years | Adjacent transitions | Transitions per interval |
|---|---|---|---|---|---|---|
| `nppes` | 20 files | 20 (2007–2026) | 19 | 4,735,546 | 4,261,806 | 224,306 |
| `pecos_revalidation` | 41 monthly releases → 6 year-end values | 6 (2021–2026) | **5** | 56,798 | 45,044 | 9,009 |
| `medicare_part_d` | 12 annual publications | 12 (2013–2024) | 11 | 39,235 | 28,357 | 2,578 |
| `medicare_part_b` | 12 annual publications | 12 (2013–2024) | 11 | 16,463 | 11,682 | 1,062 |
| `open_payments` | 1 file | 1 (2024) | **0** | 3,996 | 0 | — |

**Finding: no class-A series in this project is pseudo-longitudinal.** Every
year's value in all four longitudinal sources comes from a file published in or
for that year. No contemporary observation is replicated across historical
years. The concern that a single snapshot could manufacture thousands of
transitions was checked directly and does not apply here.

**But the transition counts are not independent evidence.** Part D's 28,357
transitions are **11 intervals × ≈2,578 midwives**, and the midwives recur
across intervals. The effective number of independent time points is **12**,
not 28,357. Confidence intervals computed as though transitions were
independent — including those in `mrost_churn_by_source.csv` — are
anticonservative, because repeated measurements on the same midwife are
correlated and are not clustered in the current calculation. See §8,
assumption A2.

> **On the 79.4% PECOS persistence specifically.** That figure rests on
> **5 transition intervals**, 2021→2022 through 2025→2026, across ~9,009
> midwives per interval. It is a statement about a 5-year window measured at 6
> year-end points, not about long-run address stability, and it must not be
> generalised to the 2013–2020 period in which PECOS has no data at all.
> The underlying observations are genuine — 41 dated monthly CMS releases — so
> the finding is real within its window; the window is the limit, not the
> provenance.

---

## 5. Scientific interpretation — what each series may be used for

| Series | Longitudinal change | Cross-sectional agreement | Restriction |
|---|---|---|---|
| `nppes` 2007–2026 | **Yes** | Yes | Unequal intervals (6–19 months); report interval length alongside any rate |
| `medicare_part_d` 2013–2024 | **Yes** | Yes | Not independent of `medicare_part_b` |
| `medicare_part_b` 2013–2024 | **Yes** | Yes | Not independent of `medicare_part_d` |
| `pecos_revalidation` 2021–2026 | **Yes, within 2021–2026 only** | Yes | 5 intervals; 2026 is a November value |
| `open_payments` 2024 | **No** — zero intervals | Yes | Effectively a snapshot |
| `medicaid_enrollment` | **No, as currently built** | Yes, with the §2.2 caveat | Class B; expansion required first, then sensitivity analysis only |
| six class-D snapshots | **No** | Yes | No year exists |

### Shared lineage: Part B and Part D are one source, not two

They agree **100.0% on 13,745 comparable NPI-years** (rebuilt 2026-11-09; the
previous figure was 100.0% on 2,423, so the overlap grew 5.7×). Both are
Medicare FFS claims products describing the same provider's enrollment of
record. They are **not independent votes**.

`attribute_claims_collapse_lineage()` exists in `mysteryroster` for exactly this
case and **is not currently applied**. Consensus tiers, odd-one-out rates and
truth fusion in `mrost_*` therefore count Medicare twice. The inflation grew
with the Part D rebuild, so this matters more after 2026-11-09 than before it.

---

## 6. Reproducibility

### Execution order

```
1. match_amcb_to_npi.R / match_nppes.R   → artifacts/amcb_npi_linkage_FROZEN.csv  (FROZEN)
2. build_midwife_panel.R                 → midwife_panel.csv
3. extract_pecos_revalidation_state_history.R
4. extract_medicare_part_b_d_cohort_states.R
5. (snapshot extracts: DAC, Healthgrades, Doximity, BON, CMS NDH, affiliations)
6. compare_all_sources_mysteryroster.R   → artifacts/mrost_*.csv
```

Steps 3–5 are independent of each other and may run in any order. Every one of
them reads the frozen linkage, which makes them **frozen consumers**: each must
be declared in `rebuild_frozen_dependents.R`, and `tests/test_frozen_dependency.R`
(gate T5) fails if the declared set and the discovered set differ.

### Provenance sidecars

Every artifact written through `write_with_provenance()` gets a
`<artifact>.provenance.json` recording the artifact name, UTC write time, each
input path with its **sha256**, a combined `code_sha256`, and the sha256 of
every sourced code file. Rebuilding is traced by hash, **never by file
modification time**.

To verify an artifact was built from the inputs it claims, recompute the sha256
of each `inputs[].path` and each `code[].path` and compare. A mismatch on an
input means the source data changed under the artifact; a mismatch on code
means the algorithm did.

### Rebuilding from original sources

```sh
# verify every script parses BEFORE running any of it
Rscript -e 'for (f in list.files(".", "[.]R$")) invisible(parse(f))'

Rscript build_midwife_panel.R                        # needs NPPES_HISTORY or the mounted volume
Rscript extract_pecos_revalidation_state_history.R   # needs REVAL_DB or cms_revalidation.duckdb
Rscript extract_medicare_part_b_d_cohort_states.R    # needs the warehouse + by-provider CSVs
Rscript compare_all_sources_mysteryroster.R
```

### Execution safety

**Do not modify an R script while that script is executing.** `Rscript`
evaluates a file expression-by-expression from an open handle rather than
parsing it upfront, so editing it mid-run shifts the read position and raises a
spurious syntax error partway through. This happened on 2026-11-09: adding
documentation to `compare_all_sources_mysteryroster.R` during its own run
aborted it at step 8 with `unexpected symbol in: write_with_provenance`.

Run long jobs from an immutable copy or a committed revision:

```sh
cp compare_all_sources_mysteryroster.R "$SCRATCH/cmp_frozen.R" && Rscript "$SCRATCH/cmp_frozen.R"
```

---

## 7. Tests

`tests/test_source_series_reconstruction.R` covers the properties this document
asserts. See §5 of that file for the mapping from claim to test.

---

## 8. Undocumented assumptions discovered while writing this

Flagged for review; **no algorithm was changed to write this document.**

**A1 — NPPES inter-snapshot intervals are not uniform.** 6.0 to 19.1 months,
median 12.0; the 2024→2025 gap is 19.1 months. Churn and lead/lag treat every
adjacent-year pair as one period. A longer gap gives more opportunity to move,
so NPPES churn is not comparable across years, and any source compared against
NPPES inherits the irregularity. *Not corrected.*

**A2 — Transition counts are treated as independent in confidence intervals.**
`mrost_churn_by_source.csv` reports Wilson intervals over transition counts
(e.g. NPPES 199,895), but transitions repeat the same midwives across intervals.
The intervals are anticonservative. Clustering by NPI is not applied. *Not corrected.*

**A3 — PECOS's 2026 value is a November vintage**, not a year-end one, and is
compared against December values for 2021–2025. *Not corrected.*

**A4 — Open Payments sits in the longitudinal tier with one year**, producing
zero transitions and four skipped lead/lag pairs. It is a snapshot by behaviour.
*Not corrected.*

**A5 — Year is taken from the filename** for Open Payments
(`str_extract(basename(f), "\\d{4}")`) and for the Part B/D by-provider files
(passed as a literal by the caller). A renamed or misplaced file silently
misdates a whole year. No checksum ties a file's contents to its claimed year.
*Not corrected.*

**A6 — `medicaid_enrollment` is reduced as a snapshot though it carries date
ranges.** Quantified in §2.2. This is the single largest known distortion in
the current results. *Not corrected.*

**A7 — Part B and Part D are counted as independent sources.** Quantified in
§5. *Not corrected.*
