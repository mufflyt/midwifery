# What the state-source audit is contracted to read

The machine-readable inventory is
[`config/state_source_audit_sources.csv`](../config/state_source_audit_sources.csv).
It is the only declaration of the intended observation window. A second copy
of an inventory is a second thing to forget to update, which is how the defect
this work exists for happened in the first place, so the one summary table
below is **pinned to the manifest by test** — T22c-T22h in
`tests/test_source_coverage_contracts.R` fail if the two disagree — rather
than maintained by hand.

This page says what the manifest is *for*, what it covers, and where the
protection it gives is still uneven.

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

## The two shapes of source, and why the difference matters

Open Payments keeps **one file per year**, so a missing year is a missing file
and `file.exists()` is a real test of it. The other eight sources keep **every
year in one file** with a year column: `midwife_panel.csv` holds 2007-2026 in
4.7 million rows.

For a panel, presence proves nothing about any particular year. A panel that
lost 2015 from inside is still a file that exists, still readable, still
carrying both declared columns. Declaring such a source row-per-year against a
presence check would have produced a contract that **cannot fail** — which is
worse than no contract, because it reads like protection.

So a panel row declares `validation_method = in_file_year_set` and is checked
against the years the file actually holds, **in both directions**:

| What happened | Verdict | Fails a publication build |
|---|---|:-:|
| a declared year is absent from the data | `year_refuted` | yes |
| a year is in the data that nobody declared | `undeclared_year_observed` | yes |

The second direction is what the annual model gets for free — `resolve_source_
inputs()` can only hand back a path that was declared — and what a panel does
not, because its producer reads the whole file. Without it, a re-scrape that
widened a source's window would publish an undeclared year: the same inversion
as the glob, with the sign flipped, the data deciding the sample.

One limit of the panel shape, stated rather than hidden: **a panel cannot
report a present-but-empty year.** An annual file can sit on disk with zero
rows, and that is valid evidence of absence — Delaware's Board of Nursing file
is exactly that, and a finding. A year with no rows inside a panel leaves no
trace at all, so it cannot be told apart from a year that was never loaded, and
it is refuted rather than called empty. That is the safe verdict, and no
declared year of the eight is affected: every one of them has rows.

## What is under contract today

All ten audited sources, 85 declared source-year rows. The windows below were
measured from the data and agree with the prose in §2 of the technical
appendix; `tests/test_source_coverage_contracts.R` T22c-T22h pins them to the
manifest so the two cannot drift.

| Source | Rows | Required | Window | Year established by |
|---|---:|---:|---|---|
| `nppes` | 20 | 20 | 2007-2026 | `in_file_year_set` — `snapshot_year` |
| `dac_physician_compare` | 14 | 14 | 2013-2025 panel + 2026 pull | `in_file_year_set` (`vintage`), `producer_declared` for 2026 |
| `open_payments` | 13 | 5 | 2013-2025 declared; **2021-2025 required** | `in_file_date` — CMS's `Program_Year` |
| `pecos_revalidation` | 6 | 6 | 2021-2026 | `in_file_year_set` — `year` |
| `facility_affiliation_ccn` | 14 | 11 | 2013-2022 + 2026; **2023-2025 unavailable** | `in_file_year_set` (`year`), `producer_declared` for 2026 |
| `healthgrades` | 1 | 1 | 2026 | `producer_declared` |
| `doximity` | 1 | 1 | 2026 | `in_file_year_set` — `date_modified` |
| `state_boards_of_nursing` | 8 | 8 | 2026 (single harvest) | `producer_declared` |
| `cms_ndh_fhir` | 1 | 1 | 2026 | `producer_declared` |
| `medicaid_enrollment` | 7 | 7 | 2018-2024 | `in_file_year_set` — `year` |

Three producers resolve every one of these inputs through the manifest —
`build_state_source_audit.R`, `build_state_source_pairwise_audit.R` and
`build_cross_source_comparison.R`. Each reads its paths from
`declared_path()`, which returns only inputs the coverage audit accepted. None
of the three names an audited source by a path literal any more, because a
literal is a second inventory: one a script trusts and nothing validates.

### Three availability states, and the distinction is the point

- **`unavailable`** — no file for this year can ever be analysable. Open
  Payments 2013-2014: CMS's own file has no NPI column. Facility Affiliation
  2023-2025: CMS dropped the CCN columns from the DAC file in 2023 and keeps
  no archived affiliation history, so the three-year hole in Figure 2 is a gap
  in the source, not an input nobody noticed was missing.
- **`ineligible`** — the files exist and are read, but a declared scientific
  decision excludes them. Open Payments 2015-2020: certified nurse-midwives
  only became reportable covered recipients under the SUPPORT Act from program
  year 2021, so these years hold 0-29 incidental rows.
- **`available`** — required. A publication build fails if any is absent,
  unreadable, carries the wrong internal year, or duplicates another.

### Three sources do not spell their person key `npi`

The manifest's `npi_field` names each source's own person column, so the
contract holds a source to the column it actually publishes rather than to a
spelling the first twenty-one rows happened to share:

- **Healthgrades** publishes `hg_npi`, because the scrape reaches AMCB
  certificants who have no NPI at all.
- **Doximity** publishes **no NPI** — the uuid is Doximity-internal — and the
  cohort link runs through `certification_number` in the frozen AMCB linkage.
- the **Medicaid** concordance is a year-by-classification **aggregate** with
  no person column, and declares none. An empty declaration excuses the
  column; a non-empty one demands it.

`artifacts/open_payments_annual_coverage_audit.csv` is the per-year evidence
for Open Payments, regenerated on every build. For panel sources the same
evidence — record count, distinct persons, states observed — is computed per
year from one pass over the file, never by repeating the file's totals on each
declared year.

## What is still asymmetric

The contract is now the same for all ten sources, but two of the ten are
weaker than the rest for reasons in the sources themselves, not in the
manifest:

- **Healthgrades and CMS NDH are `producer_declared`.** Healthgrades has no
  per-record date at all. NDH's Practitioner resources carry
  `meta.lastUpdated`, but it is not extracted into this audit's
  state-comparison path, so the year rests on the producer's own run rather
  than on the bytes. Extracting it would promote NDH to `in_file_year_set`.
- **Doximity's `date_modified` is a profile-edit date, not an observation
  date.** Declaring the window as 2026 alone is what makes it falsifiable: a
  later scrape that started carrying 2025 rows is refused rather than quietly
  widening the published series.

Both are recorded here because a reader should know which years rest on
evidence inside the data and which rest on a producer's word.
