# Technical Appendix: CSV-Ingestion Encoding Bootstrap (DuckDB `encodings` Extension)

**Repository**: `midwifery`
**Canonical chokepoint**: [`R/lib/medicare_duckdb.R`](../R/lib/medicare_duckdb.R) — `duckdb_connect()`, `ensure_duckdb_encodings()`
**Enforcement**: [`tests/ci_duckdb_ingestion_bootstrap.R`](../tests/ci_duckdb_ingestion_bootstrap.R)
**Investigation date**: 2026-09-06
**Status**: implemented and enforced. All 36 production call sites migrated and verified (syntax-checked; a representative sample re-run against live data and confirmed to reproduce prior results exactly). The regression test is proven to fail on a real bypass, not just pass trivially — see §5.

---

## 1. The incident this exists to prevent

Earlier the same session, the current CMS PECOS enrollment extract
(`PPEF_Enrollment_Extract_2026.07.17.csv`, 2,978,925 rows, 320 MB) was loaded
into the shared warehouse with `read_csv_auto(..., ignore_errors = TRUE)`.
10 rows failed to decode and were silently dropped — among them two real
people's enrollment records: `COURTNEY ÉLAN MCCALL` and
`CARNELL D'ANDRE JOHNSON`. `ignore_errors = TRUE` reported success; the loss
was only found by going back and checking row counts against the source file
line-by-line.

**Diagnosis.** The file is Windows-1252, not UTF-8 or plain Latin-1. Decisive
evidence: byte `0x92` in `D'ANDRE`'s enrollment row decodes to a proper right
single quotation mark under CP1252, but to an undefined C1 control character
under Latin-1. A general-purpose encoding detector (`charset-normalizer`)
was tried first and got this wrong — it confidently guessed "cp1250,
Romanian" (chaos score 0.0) for a US government file that is 99.99% English,
because the file is overwhelmingly ASCII and a statistical model has almost
nothing to fit on. **The fix came from decoding the actual bad bytes under
each candidate encoding and checking the output against domain plausibility,
not from trusting an automated guess.**

DuckDB's built-in CSV reader supports exactly three encodings: `utf-8`,
`utf-16`, `latin-1`. CP1252 is not among them. DuckDB's community
`encodings` extension adds it (`INSTALL encodings; LOAD encodings;`, then
`encoding = 'CP1252'`) and recovers **all 2,978,925 rows, zero dropped**,
with the two names above decoding correctly.

## 2. Why a fix wasn't enough

Fixing this one load closes one incident. The actual risk is structural:
this repository ingests external CSVs from CMS, NPPES, PECOS, Open Payments,
DAC, and geocoding caches, in **40 separate `dbConnect(duckdb::duckdb(), ...)`
call sites across 36 files**, none of which loaded the `encodings` extension.
Any one of them could hit a non-UTF-8 file and silently drop rows the same
way, and the next person to hit it would have no reason to know this
investigation already happened. The fix had to be a chokepoint every
CSV-ingestion path is forced through, not a parameter added to one script.

## 3. The bootstrap

Two new functions in `R/lib/medicare_duckdb.R`, the repo's existing DuckDB
helper library (already the canonical home for warehouse-path resolution):

- **`ensure_duckdb_encodings(con)`** — tries `LOAD encodings`; on failure,
  runs `INSTALL encodings` (logging that it's doing so, since this is a
  one-time, slower, network-touching step) then `LOAD encodings` again.
  INSTALL is deliberately separated from LOAD: install is a
  machine/environment concern that should ideally happen once (per machine
  or CI image), while load is a per-session concern that must happen on
  every connection. Splitting them means a fresh machine self-heals via the
  install-then-load fallback, while an already-provisioned machine pays only
  the (silent, fast) load cost on every run.
- **`duckdb_connect(dbdir = ":memory:", read_only = FALSE, ...)`** — a
  drop-in, signature-compatible replacement for
  `DBI::dbConnect(duckdb::duckdb(), dbdir, read_only, ...)` that calls
  `ensure_duckdb_encodings()` before returning. This is the single choke
  point: every DuckDB connection in the repo, whether to the shared
  warehouse, a geocoding cache, or a bare in-memory database for
  `read_csv_auto()` + `duckdb_register()` work, should be this function.
- **`open_medicare_duckdb()`** (pre-existing) now calls `duckdb_connect()`
  internally rather than a raw `DBI::dbConnect`, so every one of its
  existing callers is upgraded automatically.

## 4. Migration: inventory, mechanical replacement, and the two bugs it introduced

**Inventory**: 40 `dbConnect(duckdb::duckdb(), ...)` call sites across 36
production `.R` files (`grep -rn "dbConnect(duckdb::duckdb()"`), plus two
test-file matches that are legitimate exceptions (§4.1).

**Migration**: mechanical regex replacement of
`(?:DBI::)?dbConnect(duckdb::duckdb()[, ]?` → `duckdb_connect(` across all 36
files, with a `source(file.path("R", "lib", "medicare_duckdb.R"))` line
inserted into the 12 files that didn't already have it.

**Two real bugs found and fixed by re-checking, not by assuming the
mechanical pass was correct.** The insertion heuristic ("add the source line
after the last existing `source()`/`library()` line in the file") is wrong
for any file where a `source()` call appears *after* the first
`duckdb_connect()` use — which happens in this codebase, where small helper
libraries are often sourced immediately before the section that needs them
rather than all at the top. Checking source-line-number against
first-use-line-number for all 12 modified files found exactly two violations:

| File | Bug |
|---|---|
| `geocode_midwives.R` | source line landed at line 87; first use at line 66 |
| `geocode_panel_addresses.R` | source line landed at line 110; first use at line 83 |

Both moved to immediately after the file's main `suppressPackageStartupMessages()`
block, ahead of every use. All 36 files then re-verified: source line
precedes first use in every one.

**Verification, not assumption.** All 36 migrated files parse as valid R
(`parse()`, zero failures). Beyond syntax, `link_practice_locations_to_org_npi.R`
was re-run against live data post-migration and reproduced the pre-migration
result exactly: 4,734 midwives with a named organization (39.0% of cohort),
identical top-12 organization list and counts. A syntax check proves the
code parses; re-running against real data and diffing the output proves it
still does the same job.

### 4.1 The allowlist

Two files legitimately keep a raw `dbConnect(duckdb::duckdb(), ...)`:

- `tests/test_cache_vintage_declared.R` — writes a synthetic fixture directly
  via `dbWriteTable()` on an in-memory R data frame. No CSV is ever read;
  there is no encoding hazard to bootstrap against.
- `tests/test_cache_vintage_detect.R` — the matched text is a string literal
  building example/generated code for the test's own output, not executing
  code.

`R/lib/medicare_duckdb.R` itself is excluded as the chokepoint's own
definition, not a bypass of it.

## 5. Enforcement: `tests/ci_duckdb_ingestion_bootstrap.R`

Following this repo's established `tests/ci_*.R` convention (shared
reporting via `tests/ci_report.R`), the new check enforces two things:

1. **Static bypass detection.** Every tracked `.R` file is scanned for the
   raw `dbConnect(duckdb::duckdb()` pattern; any match outside the
   3-entry allowlist above fails the build. The allowlist is itself checked
   both ways: an entry that no longer exists, or no longer actually contains
   the raw pattern, fails too — stale cover is not allowed to persist after
   the file it was protecting changes.
2. **The bootstrap actually works.** A CP1252 fixture is built from raw
   bytes (not written through a text connection, so the test doesn't depend
   on this machine's locale) containing the same byte class that broke the
   real PECOS load (`0x92`, a curly apostrophe under CP1252, a C1 control
   code under Latin-1). Loading it through `duckdb_connect()` +
   `read_csv_auto(..., encoding = 'CP1252')` must recover exactly one row
   with the byte correctly decoded. A negative control confirms the fixture
   genuinely fails plain UTF-8 decoding first — proving the test exercises a
   real hazard rather than passing regardless of whether the bootstrap does
   anything.

**Proven to actually catch a bypass, not just pass by construction.** A
throwaway file containing a raw, unmigrated `dbConnect(duckdb::duckdb(), ...)`
call was added to the tracked file set and the check correctly failed,
naming the offending file; removing it restored a clean pass. This mirrors
the project's own standard for a check that's supposed to detect a defect:
demonstrate it can report a violation, not only the absence of one.

## 6. The convention, going forward

Any new script or importer that needs to read a CSV through DuckDB must call
`duckdb_connect()` (or a function that itself calls it, such as
`open_medicare_duckdb()`) rather than `DBI::dbConnect(duckdb::duckdb(), ...)`
directly. `tests/ci_duckdb_ingestion_bootstrap.R` fails the build if it
doesn't. A genuine exception (no CSV ever touches the connection) is added to
the `ALLOWLIST` vector in that test file with the same justification
standard as the two entries in §4.1 — a reason, not just an entry.
