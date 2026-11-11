# Spec Completion Matrix — Longitudinal Source Reconstruction

**Date**: 2026-11-10 · **Branch**: `feat/longitudinal-source-reconstruction`
**Verdict**: **NOT COMPLETE.** 5 of 14 sections done; 4 partial; 5 not started.

Counts below were read from the artifacts and test runs on this date, not
recalled. **An artifact existing is not evidence that a requirement is met**,
so every DONE row names the test that covers it.

---

## §2 Reconnaissance

| Requirement | Status | Implementation | Artifact | Test | Remaining |
|---|---|---|---|---|---|
| `docs/longitudinal-source-inventory.md` | **DONE** | — | 175-line doc | none (prose) | — |
| Per-source location, vintages, unit, date fields, function, coverage, limits | **DONE** | — | same | — | — |
| Do not assume filenames describe contents | **DONE** | ranges read from data/archives | — | `test_source_year_validation.R` | — |

## §3 Workstream A

| Requirement | Status | Implementation | Artifact (verified) | Test | Remaining |
|---|---|---|---|---|---|
| A1.1–A1.6 recover PPEF | **DONE** | `extract_ppef_cohort_state_by_vintage.R` → `ppef_vintages()`, `validate_vintage()`, `pull_vintage()` | `ppef_cohort_state_by_vintage.csv` 127,372 rows / 11,931 NPIs / 2016-08–2024-07; `ppef_vintage_validation.csv` 16 rows | `[11] [12] [16]` | — |
| A1 acceptance: Aug-2016 = 6,388 | **DONE** | — | reproduced exactly | `[12]` | — |
| A1 acceptance: every observation on a defensible vintage | **DONE** | `validate_vintage()` → `verified_year` / `verified_date` / `refuted` | 16/16 verified | `[11]` | — |
| A1 acceptance: no artificial continuity | **DONE** | writes its own series; does not splice into PECOS | — | `[11]` | — |
| **A1.7 coverage before/after vs the snapshot series** | **PARTIAL** | `ppef_cohort_coverage_by_vintage.csv` (after only) | 16 rows | — | no before/after table vs `pecos_revalidation_cohort_state_by_year.csv` |
| A2 correct the distortion | **DONE** | `extract_medicaid_enrollment_state_by_year.R` → `expand_segments_to_years()`, `whole_file_modal_state()` | `medicaid_enrollment_cohort_state_by_year.csv` 119,527 / 13,622 / 2013–2024 | `[18]` 9 checks | — |
| A2 document root cause, years, magnitude, direction | **DONE** | `medicaid_enrollment_modal_vs_yearly.csv` 12 rows | 14.4% overall; 30.5% (2013) → 5.7% (2024) | `[18]` | — |
| A2 before/after on **all** headline estimates | **PARTIAL** | `audit_a2_medicaid_before_after.R` | `a2_medicaid_before_after.csv` 24 rows | — | covers odd-one-out + fusion only; not churn, lead/lag, consensus, pairwise |
| A2 regression test | **DONE** | — | — | `[18]` + saboteurs `medicaid-*` ×3 | — |
| A2 regenerate dependent artifacts | **DONE** | 13 `mrost_*` rebuilt from a frozen copy | — | — | — |
| **A3 item #2 (claims lineage) + sign-off** | **NOT DONE** | — | — | — | all of it; P4, needs approval |

> **A2 falsified its own prediction.** The expansion was expected to move
> medicaid_enrollment's outlier status. It did not: odd-one-out 0.166 → **0.163**,
> fusion 77.5% → **77.6%**. The reduction error is real but sits in 2013–2017,
> while both metrics use the current-snapshot slice. The actual cause is the
> estimand: agreement with NPPES falls 87.1% → 57.8% → 45.7% → 39.9% → 36.4%
> as concurrent state enrolments rise 1 → 5+ (107,386 comparable NPI-years).
> A2 is "done" as a correction; it did **not** resolve the finding it targeted.

## §4 Workstream B — Open Payments

| Requirement | Status | Remaining |
|---|---|---|
| Inventory raw releases | **DONE** | raw CSVs confirmed for 2013–2023, 2025; 2024 only in `open_payments_merged_2013_2024.duckdb` |
| Verify program year from contents | **NOT DONE** | `assert_source_year()` exists but is not wired in |
| All other B requirements | **NOT DONE** | `open_payments_midwife_presence_by_year.csv`, `open_payments_source_coverage_by_year.csv` both MISSING |

## §5 Workstream C — Medicaid spending activity

| Requirement | Status | Remaining |
|---|---|---|
| Inspect schema, validate `CLAIM_FROM_MONTH` | **DONE** | VARCHAR "YYYY-MM", **2018-01 → 2024-12**, 84 months, 21,515,000 rows |
| Reconstruct "2013–2024" | **BLOCKED (spec error)** | no data before 2018-01; will deliver 2018–2024 |
| All outputs | **NOT DONE** | all three artifacts MISSING |

## §6 Workstream D — year validation

| Requirement | Status | Implementation | Test |
|---|---|---|---|
| Reusable `assert_source_year()` | **DONE** | `R/lib/source_year.R`; composes existing `parse_vintage()` | `test_source_year_validation.R`, 17 checks |
| 5-level hierarchy, confidence recorded | **DONE** | in_file_date / release_id / fingerprint / unverified / refuted | same |
| Fail on incompatible years, mixed years, implausible ranges | **DONE** | — | same |
| Never assign year from a filename | **DONE** | bare `YYYY` returns `unverified` | same |
| Tests with renamed files, wrong date fields | **DONE** | — | same |
| **Wired into producers** | **NOT DONE** | — | Part B/D, PPEF, B and C still take the year from caller/filename |

## §7 Workstream E — registry exit vs billing inactivity

| Requirement | Status | Remaining |
|---|---|---|
| Locate NPPES deactivation source | **BLOCKED** | **no data file on this volume**; only isochrones scripts reference one. Must download first |
| Everything else in E | **NOT DONE** | all of it |

## §8 Workstream F — statistical interpretation

| Requirement | Status | Implementation | Remaining |
|---|---|---|---|
| F1 independent evidence vs reconstructed transitions | **PARTIAL** | `audit_source_series_independence.R` → `source_series_independence.csv` (4 rows), `_interior_gaps.csv` (4 rows) | reports 7 of the 9 required fields; missing distinct-midwives vs distinct-NPIs split, discordant and persistent counts; covers 4 sources, not all |
| F2 clustered / bootstrap uncertainty | **NOT DONE** | — | Wilson intervals still treat transitions as independent |
| F3 persistence denominators | **NOT DONE** | — | no eligibility/follow-up accounting; missing follow-up not separated |
| F4 lead/lag interpretation | **NOT DONE** | — | reporting delay, ascertainment gaps, retrospective dates not separated |

## §9 Canonical data model

| Requirement | Status | Remaining |
|---|---|---|
| 13-field long-format schema | **NOT DONE** | partial fields exist per-source (`evidence_type` on Medicaid, `vintage`+`state_column` on PPEF); no unified schema, no `amcb_id`, `source_record_id`, `snapshot_date`, `effective_date`, `source_hash`, `reconstruction_version` |

## §10 Required tests — **9 of 15**

| # | Requirement | Status | Covering test |
|---|---|---|---|
| 1 | Correct source-year assignment | **DONE** | `test_source_year_validation.R` |
| 2 | Deterministic reconstruction | **DONE** | `[1] [7]` |
| 3 | Duplicate record resolution | **DONE** | `[3] [17]` |
| 4 | Missing dates | **DONE** | `[5] [11] [18]` |
| 5 | No future-information leakage | **DONE** | `[6]` |
| 6 | Missing vs negative evidence | **DONE** | `[5] [18]` |
| 7 | Stable cohort membership | **PARTIAL** | T5 in `test_frozen_dependency.R`; not asserted in this suite |
| 8 | Stable linkage identifiers | **NOT DONE** | — |
| 9 | Open Payments eligibility | **NOT DONE** | Workstream B absent |
| 10 | Monthly Medicaid aggregation | **NOT DONE** | Workstream C absent |
| 11 | NPPES deactivation chronology | **BLOCKED** | no source data |
| 12 | Reproducible output hashes | **PARTIAL** | determinism tested; hashes not pinned |
| 13 | Accurate provenance sidecars | **PARTIAL** | A3 checks existence only; **79 pre-existing artifacts carry `code_sha256: null`** |
| 14 | Stable source-by-year schemas | **DONE** | `[8]` |
| 15 | Persistence denominators | **NOT DONE** | F3 absent |

Suites: `test_source_series_reconstruction.R` **63 checks PASS**,
`test_source_year_validation.R` **17 checks PASS**. Mutation catalogue **92
entries, 24 added here, all KILLED**.

## §11 Before/after audit

| Requirement | Status | Remaining |
|---|---|---|
| `artifacts/longitudinal_reconstruction_audit.csv` | **NOT DONE** | MISSING. Needs 11 columns per source-year |
| Headline summary with explanations | **PARTIAL** | `a2_medicaid_before_after.csv` covers 2 metrics for 1 source |

## §12 Documentation — **3 of 4**

| Doc | Status |
|---|---|
| `longitudinal-source-inventory.md` | **DONE** |
| `source-series-reconstruction.md` | **DONE** |
| `temporal-evidence-validation.md` | **NOT DONE** |
| `longitudinal-reconstruction-changelog.md` | **NOT DONE** |
| Roxygen on all new functions | **DONE** — 13 + 5 (PPEF) + 2 (Medicaid) + 2 (source_year) |
| ≤80-char lines, `base::message()`, qualified calls | **PARTIAL** — new files comply; `audit_source_series_independence.R` uses unqualified `read_csv`/`filter` |

## §13 Execution order

Phase 1 **PARTIAL** (A1 done, A2 done, inventory done, A1.7 outstanding) ·
Phase 2 **PARTIAL** (D done, B and C not started) · Phase 3 **NOT STARTED** ·
Phase 4 **NOT STARTED** · Phase 5 **NOT STARTED**

## §14 Definition of done — 2 of 11 met

| Criterion | Met |
|---|---|
| All vintages inventoried and incorporated | **no** — DAC 2017–2025 still unused |
| Source years validated against content | **no** — function exists, not wired in |
| Open Payments and Medicaid activity timelines | **no** |
| Registry events separated from billing inactivity | **no** — blocked |
| No reconstructed observation presented as independent | **yes** |
| Denominators and uncertainty documented | **no** — F2/F3 outstanding |
| Cohort and linkage stable | **yes** — unchanged; T5 86/86 |
| Every statistic traceable to inputs and code | **no** — 79 null-code sidecars |
| All tests pass | **partial** — new suites pass; `ci_artifact_contracts` A4/A5 fail locally (pre-existing, CI skips) |
| Complete reconstruction documentation | **no** — 2 docs outstanding |
| Manuscript tables regenerable | **not verified** |

---

## Every incomplete acceptance criterion

1. A1.7 — before/after coverage vs the existing PECOS series
2. A2 — before/after for churn, lead/lag, consensus, pairwise agreement
3. A3 — claims-lineage correction and sign-off report (needs approval)
4. B — all of Open Payments 2013–2025, both artifacts
5. C — all of Medicaid activity 2018–2024, all three artifacts
6. D — wire `assert_source_year()` into every producer
7. E — download NPPES deactivation, then all of E
8. F1 — the two missing field groups; extend beyond 4 sources
9. F2 — provider-clustered or bootstrap uncertainty
10. F3 — persistence denominators and follow-up accounting
11. F4 — separate ordering from reporting delay and ascertainment
12. §9 — the 13-field canonical schema
13. §10 — tests 8, 9, 10, 11, 15; finish 7, 12, 13
14. §11 — `longitudinal_reconstruction_audit.csv`
15. §12 — `temporal-evidence-validation.md`, `longitudinal-reconstruction-changelog.md`
16. DAC 2017–2025 (proposal #5, distinct from A1)
17. 79 artifacts with `code_sha256: null` (pre-existing; needs its own issue)
