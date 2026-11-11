# Temporal Evidence Validation

**Repository**: `midwifery` · **Date**: 2026-11-10
**Implementation**: [`R/lib/source_year.R`](../R/lib/source_year.R) — `assert_source_year()`
**Tests**: [`tests/test_source_year_validation.R`](../tests/test_source_year_validation.R) — 17 checks
**Companions**: [`source-series-reconstruction.md`](source-series-reconstruction.md),
[`longitudinal-source-inventory.md`](longitudinal-source-inventory.md)

## The problem this exists for

Several series in this project take their observation year from a filename or
from a literal the caller passed in. Nothing checked that the bytes agreed. A
renamed, re-dated or wrongly-downloaded file is then misdated in silence, and a
misdated year is worse than a missing one: lead/lag against NPPES would report
the source as systematically early or late, which is a publishable sentence and
completely false.

Two real cases from this work:

- **`part_d_by_provider_2016.csv`** carries no year column. Its year came from
  its own filename, with nothing tying contents to the claim.
- **PPEF monthly archives** carry no date column either, and NBER's filenames
  do not zero-pad the month (`ppefenrol20168`), which already cost a round of
  404s before anything was parsed.

## The hierarchy

Five levels, strongest first. The level actually used is returned, so a reader
can see how much the answer is worth.

| Status | Evidence | Confidence |
|---|---|---|
| `in_file_date` | a date or program-year column **inside** the data | high |
| `release_id` | an authoritative release identifier in the path, via the existing `parse_vintage()` | medium |
| `fingerprint` | a previously validated sha256 for this file | medium |
| `unverified` | no evidence available — an explicit status, never a silent pass | none |
| `refuted` | evidence contradicts the expected year | — |

**A bare `YYYY` in a filename is not evidence.** `parse_vintage()` refuses it on
purpose: a four-digit year in a name is as often a cohort label or a program
year as a snapshot date. `part_d_by_provider_2016.csv` therefore returns
`unverified`, not `release_id`.

**A row count alone is never sufficient.** Two years of the same product have
similar row counts and a count cannot distinguish them. A count may corroborate
a hash; it may not replace one.

**The bytes outrank the name.** A file with both a date column and a dated path
is judged on the column. Where they conflict, the path-derived year is refuted.

## What it refuses

- a 2019 file claimed as 2020, naming both years in the message
- a file mixing 2019 and 2020 rows, unless `multiyear = TRUE` is passed
- a year before NPPES enumeration began, even when the caller expects it
- a sha256 that does not match the recorded one

`strict = TRUE` (the default) stops. `strict = FALSE` returns the verdict so a
caller can record it and continue, which is how a batch job reports a whole
manifest rather than dying on the first bad file.

It reads a head sample **and** a tail sample. Head alone would miss a file that
changes year part-way through, which is the concatenation case the mixed-year
rule exists to catch.

## Where date evidence is weaker than it looks

PPEF has no in-file date, so
[`extract_ppef_cohort_state_by_vintage.R`](../extract_ppef_cohort_state_by_vintage.R)
uses two weaker forms and records which per vintage in
`artifacts/ppef_vintage_validation.csv`:

- **`archive_mtime`** — the packaging date the zip stores. It can *refute* a
  claim (a file packaged before the period it describes is impossible) but
  cannot confirm one. All ten monthly archives are packaged on or after their
  claimed month and inside the claimed year, lags 0–3 months. Status is
  `verified_year`, not `verified`, because that is the strongest claim the
  evidence supports.
- **`member_filename`** — the quarterly members carry a CMS extract date in the
  name (`PPEF_Enrollment_Extract_2023.03.31`), an authoritative release
  identifier.

The same-year rule applies **only** to the monthly layout. The quarterly bundle
stores one packaging date for all six members (2024-09-22), so requiring the
same year refuted every 2023 quarter on the strength of when someone zipped it.
That bug was caught because the first run skipped three real vintages.

## Saboteurs

Six entries in [`tests/mutation_catalogue.R`](../tests/mutation_catalogue.R)
attack this layer, all killed: `ppef-refutation-disabled`,
`ppef-sameyear-check-removed`, `ppef-quarterly-exemption-widened`,
`ppef-vintage-month-not-padded`, `ppef-vintage-year-offset`,
`download-year-from-whole-match`.

## Not yet wired in

`assert_source_year()` is implemented and tested but **is not yet called by any
producer**. Part B/D and PPEF still take the year from the caller or the
archive. Wiring it into each producer is outstanding work, tracked in
[`spec-completion-matrix.md`](spec-completion-matrix.md).
