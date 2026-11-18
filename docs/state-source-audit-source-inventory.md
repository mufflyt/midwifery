# What the state-source audit is contracted to read

The machine-readable inventory is
[`config/state_source_audit_sources.csv`](../config/state_source_audit_sources.csv).
It is the only declaration of the intended observation window, and nothing in
this file restates its contents — a second copy of an inventory is a second
thing to forget to update, which is how the defect this work exists for
happened in the first place.

This page says what the manifest is *for*, what it currently covers, and what
it does not yet cover.

## The rule the manifest enforces

**The years a source is expected to have are declared, not discovered.** Before
2026-11-15 the Open Payments window came from
`Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")`, so the set
of files on one machine decided the analytical sample. When four of the five
annual files were absent, the build produced a one-year analysis and exited 0.

`read_open_payments_state_series()` now resolves the window from the manifest
and takes each row's year from CMS's own `Program_Year` column.
`validate_source_coverage()` compares the declared window with what is on disk
and refuses a publication build that is missing a required year.
[`state-source-audit-coverage-defect.md`](state-source-audit-coverage-defect.md)
records the original failure in full.

## What is under contract today

| Source | Manifest rows | Required | Window | Year established by |
|---|---:|---:|---|---|
| `open_payments` | 13 | 5 | 2013-2025 declared; **2021-2025 required** | `in_file_date` — CMS's `Program_Year` |
| `state_boards_of_nursing` | 8 | 8 | 2026 (single harvest) | `producer_declared` |

Open Payments' thirteen rows carry three availability states, and the
distinction is the point:

- **`unavailable`** (2013, 2014) — CMS's own file has no NPI column, so the
  cohort cannot be linked at all. Not a missing file; a source that cannot
  answer the question.
- **`ineligible`** (2015-2020) — the files exist and are read, but certified
  nurse-midwives only became reportable covered recipients under the SUPPORT
  Act from program year 2021, so these years hold 0-29 incidental rows. A year
  left out by a declared scientific decision must not look like a year nobody
  noticed was missing.
- **`available`** (2021-2025) — required. A publication build fails if any is
  absent, unreadable, carries the wrong internal year, or duplicates another.

`artifacts/open_payments_annual_coverage_audit.csv` is the per-year evidence,
regenerated on every build: presence, verified year, schema, record and NPI
counts, provenance validity, and a status for each of the thirteen.

## What is not under contract

Eight of the audit's ten sources have no manifest rows: NPPES, DAC / Physician
Compare, PECOS revalidation, Facility Affiliation, Healthgrades, Doximity, CMS
NDH, and Medicaid. They are read through their own producers and validated by
`assert_source_year()` where they carry a usable date field, but their expected
windows are not declared anywhere a build can check.

That is a **bounded, known gap, not an oversight**. Open Payments was brought
under contract because it is where the defect occurred and because its window
is a hard scientific boundary (PY2021 eligibility). Extending the same contract
to the other eight is worthwhile and is deliberately not done here, because
declaring an expected window for a source means deciding what "complete" means
for it — a scientific judgement per source, not a mechanical sweep.

Until then the protection is asymmetric, and a reader should know it: a missing
Open Payments year fails the build; a missing DAC year does not.
