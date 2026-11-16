# The state-source audit published a one-year series where five were intended

**Repository**: `midwifery`
**Defect class**: silent scientific data loss — missing input treated as missing observation
**First known affected build**: 2026-11-12
**Found**: 2026-11-15, while refreshing the State Source Audit artifact
**Status**: root cause confirmed; contracts implemented on this branch

---

## 1. What happened

The state-source audit compares ten records of where a certified
nurse-midwife practices. Open Payments is one of them, and it is supposed to
contribute a five-year series, program years 2021 through 2025.

The build dated 2026-11-12 produced **one year — 2024**. Nothing failed. The
agreement table, the coverage table, and every downstream figure were written
successfully from a series missing four of its five years.

The published artifact dated 2026-11-04 still carries the complete series, so
the loss is visible only by comparing the two:

| Program year | Appendix §3 (2026-11-03, complete) | 2026-11-12 rebuild |
|---|---|---|
| 2021 | 96.2% (n = 14,441) | *absent* |
| 2022 | 96.5% (n = 19,349) | *absent* |
| 2023 | 96.1% (n = 19,261) | *absent* |
| 2024 | 97.5% (n = 18,720) | 96.8% (n = 18,471) |
| 2025 | 96.1% (n = 21,731) | *absent* |

## 2. The responsible expression

```r
op_files <- Sys.glob("artifacts/cohort_midwives_open_payments_general_*.csv")
```

It appears three times, once in each producer the audit depends on:

- `build_state_source_audit.R:88`
- `build_state_source_pairwise_audit.R:55`
- `build_cross_source_comparison.R:157`

The annual files it discovers are **gitignored person-level artifacts**
(`.gitignore:660`, from the commit that untracked 54 person-level artifacts).
They are not in a clean checkout, and they are regenerable only from a 23 GB
DuckDB warehouse on an external volume
(`/Volumes/MufflySamsung/open_payments_data/`).

On the machine that ran the 2026-11-12 build, only
`cohort_midwives_open_payments_general_2024.csv` was still on disk. The glob
returned exactly one path. Every step downstream then behaved correctly on the
input it was given.

## 3. Why the build reported success

Because nothing ever stated how many years there were supposed to be.

The analysed window was defined by the set of files present, so a smaller set
of files was indistinguishable from a smaller set of observations. The
pipeline could not tell "Open Payments has one year of data" from "four of
this machine's input files are missing," and the second is what had happened.

This is the whole defect in one sentence: **the files present decided the
years analysed.**

## 4. What the missing years affected

Not only pictures. The truncation reached derived analytical results:

- **Figure 2** (agreement with NPPES, multi-year sources) — the Open Payments
  line collapses from five points to one.
- **Figure 4** (comparable volume and agreement) — the Open Payments panel
  loses four of five bars, and with them the point the panel exists to make.
- **Figure 5** (pairwise agreement among multi-year sources) — both pairs
  involving Open Payments (DAC × Open Payments, Open Payments × PECOS) lose
  four of their five years.
- **`artifacts/state_source_audit_agreement.csv`** and
  **`state_source_audit_coverage.csv`** — the analytical tables themselves.
- **Section 3's** stated Open Payments range, "14,441–21,731 NPI-years/yr ·
  agreement 96.1–97.5%", is computable only from the complete series.

No manuscript percentage in `manuscript/midwife_persistence.qmd` is drawn
from these tables, so the manuscript is not affected. The State Source Audit
artifact and the technical appendix are.

## 5. Two further defects found while confirming this one

### 5.1 RED — four Boards of Nursing files have no state column

`build_state_source_audit.R:143` reads `live_bon_state`, but that column is
absent from four of the eight harvested files:

| Has `live_bon_state` | States | Verified rows with an NPI |
|---|---|---|
| yes | Connecticut, Delaware, Florida, Illinois | 858 |
| **no** | **Colorado, Pennsylvania, Texas, Washington** | **1,411** |

`dplyr::bind_rows()` fills an absent column with `NA`, so those 1,411 records
— **62% of the verified Board-of-Nursing evidence** — enter the comparison
with no state and silently fail to be comparable. The surviving sample is
CT/DE/FL/IL, which is dominated by Florida.

The audit nonetheless labels this source **"2026-10 (7 states:
CO/CT/FL/IL/PA/TX/WA)"** and reports n = 664, and Figure 6 ranks "State
Boards × CMS NDH" among its highest-agreement pairs. The label describes a
sample the figure never had. Re-harvesting is a live scrape of eight state
portals and is deliberately **not** done here; the contract now fails loudly
instead.

### 5.2 YELLOW — the annual files cannot prove their own year

`cohort_midwives_open_payments_general_<year>.csv` carries no program-year
column. Its year exists only in its filename, which
`R/lib/source_year.R::assert_source_year()` explicitly refuses as proof
(`parse_vintage()` rejects a bare four-digit number by design). A file
renamed, or written by a producer given the wrong year, would be believed.

Schemas also drift between producers: the 2022 file (R extractor) carries
`recipient_address`; the 2024 file (Python producer) does not. The audit uses
only `recipient_state`, so this has not changed a result — but it means
"the schema" is not one thing.

### 5.3 GREEN (now fixed) — DuckDB spill directory

Unrelated to coverage, but it blocked the repair: the duckdb R package points
`temp_directory` at `<tempdir()>/duckdb/temp` and never creates it. A query
small enough to stay in memory never notices; a query large enough to spill
aborts with `IO Error: Failed to create directory`. That is why the 2025
extraction (a 9.2 GB scan) failed while the warehouse extracts in the same
session succeeded. Fixed in `R/lib/medicare_duckdb.R::duckdb_connect()`, the
one bootstrap every script already routes through.

## 6. Audit of the same failure mechanism elsewhere

Every other input to `build_state_source_audit.R` is a fixed single path read
with `readr::read_csv()`, which errors when the file is absent. Those fail
loudly and are **GREEN**.

| Input | Discovery | Class |
|---|---|---|
| `midwife_panel.csv` (NPPES anchor) | fixed path | GREEN |
| `artifacts/physician_compare_historical_midwives.csv` | fixed path | GREEN |
| `dac_midwives.csv` | fixed path | GREEN |
| `artifacts/cohort_midwives_open_payments_general_*.csv` | **glob** | **RED** |
| `artifacts/pecos_revalidation_cohort_state_by_year.csv` | fixed path | GREEN |
| `artifacts/historical_facility_affiliation_cohort_state_by_year.csv` | fixed path | GREEN |
| `artifacts/dac_facility_affiliations.csv` | fixed path | GREEN |
| `healthgrades_midwives.csv` | fixed path | GREEN |
| `artifacts/doximity_public_matched.csv` | fixed path | GREEN |
| `artifacts/amcb_npi_linkage_FROZEN.csv` | fixed path | GREEN |
| `artifacts/live_*_bon_ingested_midwives_from_tracked_roster.csv` | **glob** | **RED** |
| `artifacts/cms_ndh_midwives.csv` | fixed path | GREEN |
| `artifacts/medicaid_enrollment_concordance_any_time_by_year.csv` | fixed path | GREEN |

Roughly forty other top-level producers in this repository use `Sys.glob()`
or `list.files()`. They are **recorded, not refactored** — this branch fixes
the sources the state-source audit consumes, as scoped. The pattern is worth
a separate sweep.

## 7. The fix

Coverage is now declared, not discovered:

- **`config/state_source_audit_sources.csv`** — the canonical manifest. One
  row per declared source-year, with its required flag, producer, year field,
  state field, vintage, eligibility and notes.
- **`R/lib/source_coverage.R`** — `validate_source_coverage()` resolves the
  declared window, verifies existence, schema and in-file year (delegating to
  `assert_source_year()`), and **stops a publication build** that cannot use
  every required source-year, naming each one. `resolve_source_inputs()`
  replaces `Sys.glob()` in the producers.

The distinction the contract is built around, and the reason it is not simply
"require rows in every year":

> A declared source year that is present, readable and contains **zero**
> qualifying cohort records is valid evidence of absence. Delaware's Board of
> Nursing file is present and empty, and that is a finding. A source file
> that is **missing**, or whose year cannot be established, is evidence of
> nothing and must fail the build.
