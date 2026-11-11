# Longitudinal Source Inventory

**Repository**: `midwifery`
**Date**: 2026-11-10
**Purpose**: spec §2 reconnaissance — where every source actually lives, what
vintages exist, what dates it carries, and what reads it.
**Companions**: [`source-series-reconstruction.md`](source-series-reconstruction.md)
(how each series is built), [`temporal-evidence-validation.md`](temporal-evidence-validation.md)
(how observation years are proved)

> **Filenames are not evidence.** Every vintage range below was read off the
> data or the archive, not inferred from a file's name. Where a name was the
> only available evidence, the entry says so.

---

## 0. Two corrections to the specification

**§5 says to reconstruct Medicaid activity for "2013–2024". The data does not
go back that far.** `CLAIM_FROM_MONTH` in the spending file runs **2018-01 to
2024-12** — 84 distinct months, 21,515,000 rows, no gaps at the month level.
There is no 2013–2017 Medicaid spending to reconstruct. Workstream C will
deliver 2018–2024 and say so rather than emitting empty years.

**§3-A1 labels the 6,388/August-2016 source "#5".** That figure is the **NBER
PPEF** series (proposal item #6). Item #5 was the DAC producer, a separate and
still-open item: `extract_physician_compare_historical_midwives.R` already
reads the warehouse for 2017–2025 but aborts on `stopifnot(file.exists())` for
five absent NBER CSVs before reaching that code, so DAC enters the fourteen-
source comparison as a 2026 snapshot despite nine usable vintages sitting in
DuckDB. A1 was implemented as described (PPEF); DAC remains to do.

---

## 1. Cohort spine and identity

| Component | Location | Role |
|---|---|---|
| FROZEN linkage | `artifacts/amcb_npi_linkage_FROZEN.csv` (+ `.manifest.json`, + archive) | The cohort. **77 readers in this repo.** 16,898 NPIs with `cohort_member == "TRUE"` |
| Producer | [`freeze_cohort.R`](../freeze_cohort.R) → `FROZEN_OUT` | The only writer. `rebuild_frozen_dependents.R` discovers consumers by looking for a `write_csv()` at the path or at a `*OUT` variable |
| Consumer registry | [`rebuild_frozen_dependents.R`](../rebuild_frozen_dependents.R) | 86 declared scripts; `tests/test_frozen_dependency.R` T5 fails if the declared set ≠ the discovered set. **It has caught an undeclared consumer eight times, most recently this work.** |
| c5guard crosswalk | `artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv` | Class-5 (shared surname component) candidates held out of the cohort |
| Canonical resolver | [`R/lib/cohort_artifacts.R`](../R/lib/cohort_artifacts.R) — `cohort_artifact_path()`, `cohort_artifact_basename()`, `cohort_artifact_available()` | Resolves panel/crosswalk artifacts by family and window instead of by hardcoded filename |

**Non-negotiable per spec:** nothing in this work alters the cohort definition
or linkage rules. Every reconstruction below joins on `npi` from the freeze and
writes its own artifact.

---

## 2. Sources with genuine dated history

### 2.1 NPPES — the backbone

| | |
|---|---|
| Location | `/Volumes/MufflySamsung/nppes_historical_downloads/` (46 dissemination archives) |
| Vintages | **20 used, one per year, 2007–2026** |
| Date evidence | `snapshot_date` carried into the panel from the filename's release date; verified one distinct date per year, zero years with two |
| Observational unit | one row per NPI per snapshot per name variant |
| Reconstruction | [`build_midwife_panel.R`](../build_midwife_panel.R) → `midwife_panel.csv` |
| Cohort coverage | 216,823 rows / 16,885 NPIs (full panel 4,735,546 rows / 472,327 NPIs) |
| **Limitation** | **Inter-snapshot gaps are 6.0–19.1 months** (median 12.0; 2024→2025 is 19.1). A "year-over-year" rate is not a constant period. |

### 2.2 PECOS Revalidation Reassignment

| | |
|---|---|
| Location | `cms_revalidation.duckdb` (volume root), table `revalidation_reassignment` |
| Vintages | **41 monthly releases, 2021-12 → 2026-11**, collapsed to 6 year-end values |
| Date fields | `vintage` ("YYYY-MM"), from CMS's own release label |
| Reconstruction | [`extract_pecos_revalidation_state_history.R`](../extract_pecos_revalidation_state_history.R) |
| Cohort coverage | 56,798 NPI-years / 11,633 NPIs |
| **Limitation** | 6 year-level points, **5 transition intervals**. The 2026 value is a November vintage compared against Decembers. ~10% of NPI-months carry simultaneous multi-state enrolments. |

### 2.3 PPEF — CMS Public Provider Enrollment File (**new, 2026-11-10**)

| | |
|---|---|
| Location | `/Volumes/MufflySamsung/ppef_nber/` — 10 monthly NBER archives + `2023_2024Q2.zip` |
| Vintages | **16: 2016-08, 2017-01/05/07/10, 2018-01/07/11, 2019-01/04, then 2023-Q1…2024-Q2** |
| Date evidence | No date column in either layout. Monthly: `archive_mtime` (refutes, cannot confirm) → `verified_year`. Quarterly: CMS extract date in the member filename → `verified_date`. Recorded per vintage in `artifacts/ppef_vintage_validation.csv` |
| Observational unit | one row per enrolment (`enrlmt_id`), reduced to one state per NPI-vintage |
| Reconstruction | [`extract_ppef_cohort_state_by_vintage.R`](../extract_ppef_cohort_state_by_vintage.R) |
| Cohort coverage | 127,372 rows / **11,931 NPIs**; 2016-08 alone = **6,388** |
| **Limitation** | **2020–2022 does not exist anywhere** — NBER jumps 2019 → 2023, CMS keeps only 2026 snapshots. Two layouts: monthly has `state_cd` (**numeric FIPS**) *and* `state_cdstr` (two-letter); quarterly has only `STATE_CD` (two-letter). Reading the wrong one yields integer "states". |

### 2.4 Medicare Part B / Part D (by Provider)

| | |
|---|---|
| Location | Warehouse `medicare_part_b_{2013..2023}`, `medicare_part_d_{2022,2023}`; CMS by-provider CSVs on the volume for Part D 2013–2021 + 2024, Part B 2024 |
| Vintages | **12 annual publications each, 2013–2024** |
| Date evidence | **Filename / caller literal only** — the by-provider files carry no year column. This is spec assumption A5 and Workstream D's target |
| Reconstruction | [`extract_medicare_part_b_d_cohort_states.R`](../extract_medicare_part_b_d_cohort_states.R); downloads via [`download_cms_by_provider_files.R`](../download_cms_by_provider_files.R) |
| Cohort coverage | Part B 16,463 NPI-years / 3,812 NPIs; Part D 39,235 / 8,147 |
| **Limitation** | Warehouse holds Part D 2013–2021 **only as the `_standardized` cut, which drops the state column**. Part B and Part D share a claims lineage (100.0% agreement on 13,745 NPI-years) and are not independent. |

### 2.5 DAC / Physician Compare

| | |
|---|---|
| Location | NBER mirror CSVs under `data/raw/cms_physician_compare/` (**absent in this clone**) + warehouse `doc_archive_*` / `physician_compare_<year>_Q2` |
| Vintages | 2013-06, 2013-09, 2014-09, 2015-10, 2016-04 (NBER) + **9 warehouse vintages 2017-04 → 2025-Q2** |
| Reconstruction | [`extract_physician_compare_historical_midwives.R`](../extract_physician_compare_historical_midwives.R) |
| Cohort coverage | warehouse vintages hold 3,035–4,011 cohort midwives each |
| **Limitation** | **The producer aborts on the five missing NBER files before reaching the warehouse code it already contains**, so the comparison sees a 2026 snapshot only. Both download routes return 403. CCN columns exist 2013–2022 and were dropped by CMS from 2023. |

### 2.6 Open Payments

| | |
|---|---|
| Location | `/Volumes/MufflySamsung/open_payments_data/<year>/unzipped_files/` |
| Vintages | **raw CSVs present for 2013–2023 and 2025 (12 years)**; 2024 only inside `open_payments_merged_2013_2024.duckdb` |
| Date evidence | program year from the release directory and filename (`PGYR2025_P06302026_06032026`) |
| Reconstruction | `artifacts/cohort_midwives_open_payments_general_<year>.csv` — **only 2024 exists** |
| Cohort coverage | 3,996 NPIs (2024) |
| **Limitation** | Sits in the longitudinal tier with one year, so it yields **zero** transitions and four skipped lead/lag pairs. **CNMs were not Open-Payments-reportable until program year 2021**; 2015–2020 is 1–29 NPIs/year and 2013–2014 has no NPI column at all. Absence is not inactivity. |

### 2.7 Medicaid enrolment segments (DOGE T-MSIS)

| | |
|---|---|
| Location | `/Volumes/MufflySamsung/doge_opendata/medicaid_provider_enrollment_segments_2026_07_24/` |
| Date fields | **`ENRL_START_DT`, `ENRL_END_DT`** (true DATEs) |
| Size | 65,970,112 rows; 162,984 for this cohort |
| Reconstruction | inline in [`compare_all_sources_mysteryroster.R`](../compare_all_sources_mysteryroster.R) |
| Cohort coverage | 13,622 NPIs |
| **Limitation** | **Currently reduced to one whole-file modal state despite carrying date ranges.** Expansion yields 119,527 NPI-years 2013–2024; the modal state differs from the year-specific state 14.4% of the time (30.5% in 2013). Left-censored: `min(ENRL_END_DT)` is 2018-01-01. This is spec item A2. |

### 2.8 Medicaid spending by NDC (DOGE)

| | |
|---|---|
| Location | `/Volumes/MufflySamsung/doge_opendata/medicaid_provider_spending_ndc_2026_07_24/` |
| Date field | **`CLAIM_FROM_MONTH`**, VARCHAR "YYYY-MM" |
| Range | **2018-01 → 2024-12, 84 distinct months, 21,515,000 rows** |
| Roles | `PRESCRIBING_PROVIDER_NPI_NUM` and `BILLING_PROVIDER_NPI_NUM`, separately |
| Cohort coverage | 839 prescribers / 101 billers, presence only |
| **Limitation** | No state column — it can never be a location source. **No data before 2018**, contrary to spec §5. |

---

## 3. Contemporary snapshots (no history)

| Source | Artifact | NPIs |
|---|---|---|
| CMS NDH (FHIR) | `artifacts/cms_ndh_midwives.csv` | 15,127 |
| Healthgrades | `healthgrades_midwives.csv` | 7,471 |
| Doximity | `artifacts/doximity_public_matched.csv` | 4,647 |
| Facility affiliation (CCN) | `artifacts/dac_facility_affiliations.csv` | 1,663 |
| State Boards of Nursing | `artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv` | 648 |

---

## 4. Required but NOT present

| Need | Spec | Status |
|---|---|---|
| NPPES deactivation / reactivation file | Workstream E | **No data file on this volume.** Only isochrones *scripts* reference it (`R/NPPES_deactivated_download.R`, and helpers `is_npi_deactivated`, `format_npi_deactivations`). E must download first. |
| DAC historical NBER CSVs | A1 / item #5 | Absent; both routes 403. Warehouse substitute exists and is unused. |
| PPEF 2020–2022 | — | Does not exist at any source. |
| Medicaid spending 2013–2017 | §5 | Does not exist; the file starts 2018-01. |

---

## 5. Reading infrastructure

| Component | Path |
|---|---|
| Comparison | [`compare_all_sources_mysteryroster.R`](../compare_all_sources_mysteryroster.R) → 13 `artifacts/mrost_*.csv` |
| Independence audit | [`audit_source_series_independence.R`](../audit_source_series_independence.R) |
| Provenance | `write_with_provenance()` in `R/lib/artifact_provenance.R`; every artifact gets a `.provenance.json` with input and code sha256s. A3 in `tests/ci_artifact_contracts.R` fails any tracked artifact without one |
| Tests | `tests/test_source_series_reconstruction.R` (53 checks); 21 saboteurs in `tests/mutation_catalogue.R`, all killed |
| CI | `.github/workflows/ci.yml` — `r-checks` (8 scripts), `r-unit-tests`, `science-law-coverage`, aggregate `Scientific gate` |
