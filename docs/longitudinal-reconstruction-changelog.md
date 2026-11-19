# Longitudinal reconstruction changelog

Decisions and corrections that changed what the year-by-year series mean,
in the order they landed. Dates are the commit date, not the observation
window. The audit table is `artifacts/longitudinal_reconstruction_audit.csv`.

## 2026-11-10 — Medicaid moved from SNAPSHOT to LONGITUDINAL

T-MSIS enrollment was previously read as a single current state. Reading the
enrollment segments longitudinally and comparing against ANY enrolled state
(not an arbitrary modal pick) changed NPPES agreement from 74.7% to 88.5% —
14,815 NPI-years reclassified. Multi-state enrollment remains set-valued;
reducing it to one state is documented as a comparison choice, not a fact.

## 2026-11-12 — Open Payments window declared 2021–2025, not 2013–2025

CNMs were not reportable covered recipients before program year 2021
(SUPPORT Act expansion). The full 2013–2025 series is written with
`usable_for_trend`; producers and consumers honour the flag — pre-2021 rows
exist but carry no trend claims. 2013–2014 rows are additionally labelled
`retrospective_profile_link` (no NPI in the source; linked through a
2021–2025 profile lookup).

DAC is a 14-year arm (2013–2026) via
`artifacts/physician_compare_historical_midwives.csv`; the residual
"2017–2025 unused" item in the spec matrix concerns finer-grained mid-year
vintages inside that file, not missing coverage.

## 2026-11-14 — Medicare Part B + Part D collapsed to one claims vote

The two products share one claims lineage and never conflicted on 41,953
NPI-years. Pairwise comparison keeps both arms; consensus/truth-fusion
counts the family once (`attribute_claims_collapse_lineage`, zero
conflicts). `medicare_claims` enters the audit manifest 2013–2024.

## 2026-11-14 — F4 lead/lag decomposed

`lead_lag_decomposition.csv` separates source-side delay, registry-side
delay, persistent ascertainment/definitional disagreement, and unresolved
transitions; `docs/temporal-evidence-validation.md` explains the categories.
A source "adopting" NPPES's value later is not evidence of a real move.

## 2026-11-18 — Canonical 13-field schema + F2/F3 uncertainty

`canonical_source_records.csv` (447k rows, 16,763 cohort NPIs) unifies the
five longitudinal sources under `amcb_id`, `source_record_id`,
`snapshot_date`, `effective_date`, `vintage`, `evidence_type`,
`usable_for_trend`, `source_hash`, `reconstruction_version` — NA never
invented. `agreement_cluster_bootstrap_ci.csv` (cluster bootstrap by NPI vs
independence-assumption Wilson) and `persistence_denominators.csv`
(followed-in-source vs lost-but-visible-in-NPPES) replace the missing
denominator story.

## 2026-11-18 — Year validation wired into producers

Open Payments: `assert_year_set` on in-file `Program_Year` — all 13 years
`in_file_date`/retrospective. PPEF: `validate_vintage` on archive-internal
dates. Medicare: `assert_source_year` → 13 warehouse tables `release_id`,
11 renamed by-provider CSVs `unverified` (no in-file year column exists by
design; fingerprint pinning pending).

## 2026-11-19 — OP linkage adjudication + CMS fingerprints + §11 audit

`adjudicate_op_linkage_450.py` rules each disagreement: 254/376
input-universe, 95 tenant error (A), 27 genuinely ambiguous — B's join
governs the practice-location estimand; neither implementation is deleted.
`config/cms_by_provider_fingerprints.csv` pins sha256 for the eleven
renamed by-provider CSVs, upgrading their year validation from `unverified`
to `fingerprint` (verified end-to-end: correct hash → `fingerprint`, wrong
hash → `refuted`). `longitudinal_reconstruction_audit.csv` closes §11.

## 2026-11-19 — T-MSIS spending warehouse + Workstream C outputs

`download_medicaid_provider_spending.py` completed: sha256-verified zip
(3.76 GB → 11.55 GB CSV), 238,015,729 rows loaded locally then copied to
`/Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb`
with a row-count-verified copy. `extract_tmsis_medicaid_spending_history.R`
produced the person-level cohort file (26,641 NPI-years, 7,467 NPIs,
2018–2024): only 10 rows excluded on HCPCS code shape (all `'18'`), zero
rows tripped the paid/lines/patients plausibility bounds — the documented
national corruption does not reach this cohort, same reply the script was
written to defend. `analyze_medicaid_billing_by_state.R` and
`analyze_medicaid_billing_year_trend.R` produced the two aggregate
artifacts; `R/lib/ob_midwife_cohort.R` gained an archive fallback so its
pinned 20261012 ABOG input resolves to the newest local archive when the
pin is absent (path+sha256 recorded in the sidecars).

## Known blocked items (unchanged)

- NPPES deactivation chronology: source file now current
  (NPPES_Deactivated_NPI_Report_110926_V2, Nov 2026); Workstream E pending.
- DAC 2017–2025: no historical Physician Compare files on this volume.
