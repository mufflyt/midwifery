# Rebuilding the Open Payments series, and proving it was rebuilt

How the 2021-2025 Open Payments series was restored after the 2026-11-12 build
reported a one-year analysis as a success, and how to verify or repeat it.

Root cause: [`state-source-audit-coverage-defect.md`](state-source-audit-coverage-defect.md).
What is contracted: [`state-source-audit-source-inventory.md`](state-source-audit-source-inventory.md).
What moved: [`state-source-audit-scientific-changelog.md`](state-source-audit-scientific-changelog.md).

## Inputs this needs that a fresh clone does not have

The annual artifacts carry a certification number per row, so they are
person-level and **gitignored**. A clean checkout cannot redraw these figures
from tracked files and must regenerate the inputs first. Both regeneration
paths need the external volume:

| What | Where |
|---|---|
| Open Payments warehouse, 2013-2025 | `/Volumes/MufflySamsung/open_payments_data/open_payments_merged_2013_2024.duckdb` (holds `op_2020` … `op_2025` despite the name) |
| Raw CMS PY2025 general payments, 9.2 GB | `/Volumes/MufflySamsung/open_payments_data/2025/unzipped_files/OP_DTL_GNRL_PGYR2025_P06302026_06032026.csv` |
| Cohort crosswalk | `artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv`, resolved by `cohort_artifact_path("crosswalk_c5guard")` |

Both extractors resolve the cohort through `cohort_artifact_path()`. They used
to glob `amcb_npi_crosswalk_*panel*.csv` and take the first of a descending
sort — the `translit` arm, where every other published table names `c5guard`.
The three arms exist in order to differ, so a denominator under every Open
Payments percentage was being chosen by alphabetical order. They are identical
today on every column either extractor reads (11,920 ACTIVE
`primary_midwifery` NPIs in each, same `npi`, `certification_number`,
`first_name`, `last_name`, `nppes_state`), so naming the arm moved no number.
`tests/test_source_coverage_contracts.R` T16/T16b fail if either reverts.

## Regenerate

```sh
# 2015-2025 from the warehouse. The default window is the whole declared
# series; it used to stop at 2021, which is how a run that simply took the
# default produced a short series without saying so.
Rscript extract_open_payments_address_history.R

# 2025 again, independently, straight from the 9.2 GB raw CMS file. This is a
# cross-check, not a second source of truth -- it writes the same artifact.
Rscript extract_open_payments_2025.R

# Coverage, agreement and the per-year coverage audit.
Rscript build_state_source_audit.R

# Make the appendix's Section 3 table a rendering of the artifact.
Rscript refresh_state_source_appendix_section3.R

# What the restoration changed, year by year.
Rscript build_state_source_before_after.R

# The six figures.
Rscript make_state_source_audit_figures.R
```

Both extractors write
`artifacts/cohort_midwives_open_payments_general_2025.csv`, so they must agree
on its schema. Until 2026-11-17 only the warehouse one selected
`Program_Year`, so running the 2025 step documented above replaced a usable
artifact with one `read_open_payments_state_series()` rejects — loudly, but it
left the reproducer with a broken checkout. Both now select CMS's own
`Program_Year` and `Date_of_Payment`; `tests/test_source_coverage_contracts.R`
T17 fails if either stops.

## Verify, without trusting the rebuild

**2025 was settled three ways and they agree exactly.** Joined to the cohort:

| Path | Rows | Distinct NPIs |
|---|---:|---:|
| Warehouse `op_2025` | 21,890 | 4,324 |
| Full scan of the 9.2 GB raw CMS CSV | 21,890 | 4,324 |
| The committed artifact | 21,890 | 4,324 |

Every row in the artifact carries `program_year = 2025`; the raw file contains
no cohort-matched row under any other program year, so no filter is doing
hidden work.

The 2026-11-03 revision note in the technical appendix reports 22,069 rows and
4,382 NPIs for this same year from the same raw file. **That figure cannot be
reproduced from anything now on disk.** The crosswalk arms have not changed
since 2026-08-14, the extraction join is unchanged, and the read-flag change
from `ignore_errors` to `strict_mode` was measured to return the same
16,131,856 rows. The superseded run's output was untracked and overwritten and
carried no provenance sidecar, so the discrepancy cannot be closed — only
recorded. It is the clearest argument in this repository for staged,
provenanced writes, and it is why
`artifacts/state_source_audit_before_after.csv` marks the original per-year
record counts `NA` rather than guessing them.

## What a failed rebuild looks like

Removing a required annual file does not produce a four-year analysis. It
produces a build that stops and names the year. That path is held by
`tests/test_source_coverage_contracts.R`, which constructs a five-year fixture
on disk and then removes one year, removes two, renames one, corrupts one,
writes an empty-but-readable one, duplicates a year, and adds an unexpected
year — asserting a hard failure for each except the legitimately empty year,
which is valid evidence of absence and must pass.
