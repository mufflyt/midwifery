# Technical appendix: the DuckDB bootstrap as a repository invariant

## Why this exists

A CMS PECOS extract silently lost 10 real enrollment records — including two
accented/curly-quote names — because the file was Windows-1252, not UTF-8 or
Latin-1, and DuckDB's built-in CSV reader only knows utf-8/utf-16/latin-1
(`ignore_errors = TRUE` swallowed the bad rows instead of erroring). The fix
for that one script was two lines: `INSTALL encodings; LOAD encodings;`.

The fix for the *repository* is this document and the machinery it describes.
A per-script fix only proves that one script was patched; it says nothing
about whether the next new importer rediscovers the same defect six months
from now. The goal is not "all callers use a helper" — it is that DuckDB
initialization is a single enforceable subsystem with explicit semantics,
provenance, negative controls, and no hidden dependence on developer-machine
state.

## Architecture

```
production code -> duckdb_connect() -> canonical bootstrap -> duckdb::duckdb() -> DBI::dbConnect()
                         |
                         v
              open_medicare_duckdb() (domain-specific: warehouse path +
                                       required-table assertions)
```

Three responsibilities, deliberately separated in `R/lib/medicare_duckdb.R`:

- **A. `ensure_duckdb_encodings(con, quiet)`** — bootstrap/environment concern.
  Probes capability via `duckdb_encoding_capability()`; installs+loads only if
  needed; fails closed if installation is forbidden and the capability is
  absent.
- **B. `duckdb_connect(dbdir, read_only, ...)`** — connection creation with
  canonical defaults. The single choke point. Calls A internally.
- **C. `open_medicare_duckdb(required_tables, path, read_only)`** — domain
  opener for the shared warehouse. Calls B internally; never initializes
  DuckDB independently, and never sets up encodings itself. It only adds
  warehouse-specific concerns: path resolution (`resolve_midwifery_duckdb()`)
  and required-table/non-empty-table assertions.

Each layer only knows about the layer below it. `open_medicare_duckdb()`
cannot bypass the encodings bootstrap even by accident, because it has no
code path that reaches DuckDB except through `duckdb_connect()`.

## The `duckdb_connect()` contract

Machine-checked by `tests/ci_duckdb_connection_contract.R`. Summarized:

| Aspect | Behavior |
|---|---|
| backend | Always `duckdb::duckdb()`. Not configurable. |
| `dbdir` | Passed through unchanged (`":memory:"` default, or an explicit path). Never guessed or rewritten. |
| `read_only` | Preserved exactly as passed. Default `FALSE`, matching `DBI::dbConnect`'s own default — **not** `open_medicare_duckdb()`'s read-only-by-default policy, which lives one layer up. |
| `...` forwarding | Forwarded verbatim to `DBI::dbConnect` (proven with `bigint = "integer64"`; note `config = list(memory_limit = ...)` does not take effect at connect time on *either* a raw or bootstrapped connection — this is a DuckDB behavior, not a `duckdb_connect()` defect). |
| extensions | `encodings` guaranteed loaded, or the call errors (fail-closed). No other extension touched. |
| `temp_directory` / `threads` / `memory_limit` | **UNSPECIFIED by design.** No PRAGMA set for any of these; DuckDB's own defaults apply unchanged. `threads` is asserted to match a raw connection's own default, so "unspecified" is verified, not just claimed. |
| disconnect | Caller-owned. `duckdb_connect()` does not track, register, or auto-close connections. A second `dbDisconnect()` on an already-disconnected connection does not hard-error. |
| independence | Two calls return distinct objects with no shared temp tables, no leaked session `SET`s, and no cross-invalidation on disconnect. `duckdb_connect()` holds no internal cache/shared-state variable in its own closure. |

## Observable bootstrap capability

`duckdb_encoding_capability(con)` returns a structured probe, not a log
string:

```r
list(
  dependency_present               = <extension installed?>,
  dependency_loadable               = <LOAD encodings succeeded?>,
  required_encoding_support_available = <can this connection actually decode CP1252 right now?>,
  bootstrap_action_taken            = "none" | "loaded" | "installed_and_loaded"
)
```

Tests assert on this structure. `required_encoding_support_available` is
checked by actually round-tripping `decode(encode('test'), 'CP1252')`, not by
trusting that `LOAD` succeeding implies the identifier still means what it
used to mean in a future DuckDB release.

## Fail-closed mode

`DUCKDB_BOOTSTRAP_ALLOW_INSTALL` (values `"0"`/`"false"`/`"no"`, case
insensitive) forbids `ensure_duckdb_encodings()` from attempting
`INSTALL encodings` when the capability is absent. In that mode, a missing
dependency is a loud `stop()` naming the missing capability and the two
remediations (pre-install on the image, or set the variable to allow install)
— never a silent continuation, never a network attempt.

This lets CI distinguish three failure classes that `ignore_errors = TRUE`
used to conflate:

1. **Code defect** — wrong SQL, wrong table name, etc.
2. **Dependency/bootstrap defect** — the extension is genuinely missing but
   installable; fail-closed mode surfaces this without touching the network.
3. **Network/install defect** — installable in principle, but this
   environment refuses the attempt (offline CI, sandboxed runner).

Proven end-to-end, on a genuinely fresh machine simulation (empty
`extension_directory`, not just an unloaded extension already on disk), by
`tests/ci_duckdb_clean_environment.R`.

## Provenance

Every connection `duckdb_connect()` returns carries:

```r
attr(con, "duckdb_bootstrap_version")   # e.g. "1.0.0"
attr(con, "duckdb_bootstrap_action")    # "none" | "loaded" | "installed_and_loaded"
```

`duckdb_connection_provenance(con)` reads these back (never re-probes — a
connection's live state can drift after creation in ways that say nothing
about which bootstrap version created it). A connection with no provenance
attributes (e.g. a raw connection from an exception-registry site) returns
`NA` with a warning, rather than silently fabricating an answer.

`DUCKDB_BOOTSTRAP_VERSION` is bumped when `ensure_duckdb_encodings()` or
`duckdb_connect()` changes *semantics* — which extensions load, what
defaults apply, what provenance is recorded — not on every unrelated edit to
the file.

## Enforcement: the AST scanner

`duckdb_scan_for_raw_connections(files)` in `R/lib/medicare_duckdb.R` is a
structural (not textual) scanner. It parses each file's real AST via
`parse(path, keep.source = TRUE)` and walks call nodes recursively, flagging:

1. `dbConnect()` / `DBI::dbConnect()` calls whose driver argument (positional
   or named `drv =`) is a bare `duckdb::duckdb()` / `duckdb()` call.
2. Any standalone `duckdb::duckdb()` / `duckdb()` call anywhere — closing the
   indirection gap a purely argument-based rule would miss (e.g.
   `d <- duckdb::duckdb(); con <- dbConnect(d)`).

This survives what a regex ratchet does not: multi-line calls, named
arguments, and reformatting. It does **not** attempt full symbolic resolution
(aliasing `dbConnect` to another name, dynamic dispatch) — documented as
"where practical," not "provably exhaustive," consistent with this repo's
actual risk profile and its convention of never rebinding `dbConnect`.

Every recursive descent step is wrapped in `tryCatch` because R's "empty
argument" placeholder (the blank in `df[, "col"]`) is not safely
indexable/iterable and would otherwise crash the scanner on ordinary,
unrelated code.

Run against every tracked `.R` file by `tests/ci_duckdb_ingestion_bootstrap.R`
(§1). Currently: **353 files scanned, 4 files with any raw connection at all,
0 offenders outside the registry.**

This scanner found two real, previously-unmigrated call sites live during
this work — `analysis/audit_identity_flips.R` and
`analysis/measure_taxonomy_scope_ceiling.R` — added to the repo after the
original 40-site migration and before the scanner was built. Both are now
migrated. This is exactly the regression class the scanner exists to catch,
caught in the act rather than in a postmortem.

## Exception registry

`DUCKDB_RAW_CONNECTION_EXCEPTIONS` in `R/lib/medicare_duckdb.R` is a
structured list — not an anonymous inline allowlist — of
`list(file, reason, owner, expiry_condition)` records. Current entries:

| File | Reason | Expires |
|---|---|---|
| `R/lib/medicare_duckdb.R` | Is the chokepoint's own definition; necessarily contains the one real `DBI::dbConnect(duckdb::duckdb())` call in the repo. | Never — definitional. |
| `tests/test_cache_vintage_declared.R` | Writes a synthetic fixture via `dbWriteTable()` on an in-memory data frame; no CSV read, no encoding hazard. | If ever changed to read an external CSV. |
| `tests/ci_duckdb_ingestion_bootstrap.R` | Deliberately constructs a raw, unbootstrapped connection as the negative control reproducing the original PECOS defect. | If the legacy-reproduction control is removed. |
| `tests/ci_duckdb_connection_contract.R` | Deliberately constructs a raw connection as the baseline for the "threads/memory are UNSPECIFIED and match DuckDB's own default" assertion. | If that comparison assertion is removed. |

The registry is self-checking in both directions: an offender outside the
registry fails CI, and a registry entry whose file no longer exists, or no
longer actually contains a raw connection under the AST scanner, also fails
CI as **stale cover** — it may not be left in place once it stops protecting
anything. (`tests/test_cache_vintage_detect.R` was removed from an earlier,
regex-based version of this registry for exactly this reason: the AST
scanner correctly never flagged it, because it never executes a real
connection — the string it matched under the old regex was inside a test
fixture literal.)

Raw production DuckDB connection sites outside the registry: **0.**

## Encoding regression fixtures

`tests/ci_duckdb_ingestion_bootstrap.R` §2, all built from raw bytes (never a
text connection, so none depend on this machine's locale):

- `valid_utf8` — plain UTF-8, no CP1252 needed. Must succeed.
- `cp1252_smart_quote` (0x92) — the exact byte from the real PECOS defect. Must succeed.
- `cp1252_em_dash` (0x97). Must succeed.
- `cp1252_nbsp` (0xA0) — also valid Latin-1; proves CP1252 handles it too. Must succeed.
- Malformed byte sequence (0xC0, not a valid UTF-8 lead byte under a plain
  UTF-8 read) — must **fail loudly**. This project does not normalize
  malformed bytes silently just to make ingestion succeed.
- Legacy pattern (`ignore_errors = TRUE`, no `encoding=` argument, on a raw
  connection) — reproduces the *original* defect exactly: the bad row is
  silently dropped. This is the narrow, correct claim: the original defect
  was never "a raw connection can't decode CP1252 in isolation" (DuckDB
  autoloads an already-installed extension the instant a query references
  it, regardless of which connection function opened it) — it was that
  nobody requested an encoding at all. Proving the capability is genuinely
  *absent* on a machine that never had it belongs to the clean-environment
  test below, which controls `extension_directory` directly instead of
  relying on this machine's already-populated one.

## Integration harness

`tests/ci_duckdb_connection_contract.R` §3 exercises one representative
consumer per behavior class at the abstraction boundary, rather than
duplicating the same proof across 36 bespoke call sites:

- write / create table, write / insert rows
- read-only query
- CSV import via `read_csv_auto`
- transaction (`dbBegin`/`dbRollback`) — not used anywhere in this repo
  today per the file inventory, proven available anyway
- temporary table creation
- `duckdb::duckdb_register()` — the dominant temp-table idiom actually used
  across the migrated files
- multi-connection access to the same persisted file (second connection sees
  first connection's committed writes)
- ATTACH/DETACH explicitly skipped — a repo-wide scan found zero uses in any
  of the 36 migrated files or elsewhere; nothing to verify against a real
  consumer.

## Mutation testing

`tests/ci_duckdb_mutation_tests.R` applies each mutation to an isolated copy
of the real bootstrap (`sys.source()`d fresh per mutation, then selectively
overridden — never to the file on disk) and re-runs the specific gate that
should catch it:

| # | Mutation | Gate | Result |
|---|---|---|---|
| M1 | Raw `DBI::dbConnect(duckdb::duckdb())` in place of `duckdb_connect()` | AST scanner | KILLED |
| M2 | `duckdb::duckdb()` constructed via variable indirection, passed to `dbConnect()` | AST scanner (standalone rule) | KILLED |
| M3 | Bootstrap sourced after `duckdb_connect()`'s first use | Runtime `Rscript` failure ("could not find function") | KILLED |
| M4 | `ensure_duckdb_encodings()` replaced with a no-op | CP1252 fixture must fail | **In-process: SURVIVES** (confounded — this machine already has `encodings` installed from earlier work, and DuckDB autoloads it regardless of the bootstrap). **Unconfounded (empty `extension_directory`, separate subprocess): KILLED** — see `tests/ci_duckdb_clean_environment.R`. |
| M5 | Fail-closed error replaced with silent continuation | Absence of an error where one is required | KILLED-by-absence |
| M6 | `duckdb_connect()` returns a cached, shared connection | Independence assertion (temp-table leak between callers) | KILLED |
| M7 | `read_only` forwarding dropped | Read-only write-rejection assertion | KILLED |
| M8 | Provenance attributes omitted | `duckdb_connection_provenance()` returns non-`NA` despite the mutation | KILLED |

M4's in-process "survival" is not a hidden gap — it is the exact reason
`tests/ci_duckdb_clean_environment.R` exists: DuckDB's extension autoload
means an in-process test on a machine that has ever installed `encodings`
cannot distinguish "the bootstrap ran" from "the extension happened to
already be on disk." The clean-environment test removes that confound by
launching a separate `Rscript` subprocess and pointing `extension_directory`
at a genuinely empty temp directory, so no autoload is possible.

## Clean-environment proof

`tests/ci_duckdb_clean_environment.R` runs two isolated `Rscript` subprocesses
per scenario, each with a fresh empty `extension_directory`:

- **Install-allowed** (`DUCKDB_BOOTSTRAP_ALLOW_INSTALL` unset/`1`): the
  bootstrap self-heals via `INSTALL` and successfully decodes CP1252.
  Requires network access — a failure here in a network-restricted
  environment is a **network/install defect**, not a code defect.
- **Install-forbidden** (`DUCKDB_BOOTSTRAP_ALLOW_INSTALL=0`): fails closed
  with the specific, documented error — no network attempt, no silent
  continuation.
- **M4, unconfounded**: bootstrap skipped entirely, in a genuinely empty
  `extension_directory` — CP1252 decoding fails exactly as in the real
  incident, giving mutation M4 its definitive kill-proof.

All three PASS. (An earlier run of this file reported 3 failures that were
traced to two bugs in the test harness itself, not the bootstrap: `cat(x, "\n")`
inserts a stray space by default — fixed to `cat(x, "\n", sep = "")` — and the
install-forbidden check compared only the *last* printed line against
`"^error: "`, but the thrown error message is itself multi-line, so the last
line was a mid-message fragment. Fixed to search the full captured output.
The underlying bootstrap behavior was correct in both runs before the fix;
only the test's own string-matching was wrong.)

## Verified production migration

The mechanical migration (raw `dbConnect(duckdb::duckdb())` → `duckdb_connect()`)
was reviewed diff-by-diff for the highest-criticality flagged files. In every
case the change is a single-line, call-signature-preserving substitution —
`dbConnect(duckdb::duckdb())` → `duckdb_connect()`, or
`dbConnect(duckdb::duckdb(), DB, read_only = TRUE)` → `duckdb_connect(DB, read_only = TRUE)`
— with no other line touched. Both call-signature shapes used across every
migrated production file are exactly what `tests/ci_duckdb_connection_contract.R`
proves behaviorally equivalent (path semantics, `read_only` enforcement,
`...` forwarding, threads default, disconnect semantics).

For `resolve_org_ambiguity.R`, this was additionally verified live: the
pre-migration (`git show HEAD:`) and post-migration (working-tree) versions
of the script were run side-by-side against the real, read-only 87 GB
production warehouse and the real NPPES/AMCB inputs, with only their CSV
*output* paths redirected to a scratch directory (no production artifact was
read-write or overwritten). Result: stdout logs identical (zero diff —
cohort counts, all tier resolutions, distribution-shift table); 3 of the 4
output artifacts (`midwife_org_person_candidate.csv`,
`org_resolution_distribution_shift.csv`, `org_resolution_review_sample.csv`)
byte-identical (matching MD5); the fourth
(`midwife_org_affiliations_candidate.csv`) had the same row count (7,925)
and identical content once sorted — the only difference was row order, an
inherent DuckDB unordered-result property of a query with no `ORDER BY`,
unrelated to which connection function opened it. Verdict: **equivalent.**

Several of the other flagged files (`build_pecos_organization_affiliations.R`,
`extract_nppes_midwives.R`, `build_care_compare_organization_panel.R`,
`extract_dac_facility_affiliations.R`) depend on raw source extracts that are
not present on this machine at the time of this review — CMS discontinued
the standalone PECOS reassignment-file distribution used by the PECOS script
(a distribution-format change, not a defect in this repo), and the NPPES
March-2024 / Care-Compare / Facility-Affiliation raw downloads referenced by
the others are not currently downloaded locally. For these, equivalence
rests on the diff-level proof above plus the generic connection-contract and
integration-harness coverage, not an independent live rerun — stated
explicitly here rather than implied.

## Definition of done

| Item | Status |
|---|---|
| Raw production DuckDB connection sites (outside registry) | **0** |
| Canonical connection contract | **PASS** (`tests/ci_duckdb_connection_contract.R` §1) |
| Independent-connection semantics | **PASS** (§2) |
| Encoding regression fixtures | **PASS** (`tests/ci_duckdb_ingestion_bootstrap.R` §2) |
| Bootstrap fail-closed mode | **PASS** (`tests/ci_duckdb_clean_environment.R`, install-forbidden scenario) |
| Source-order mutation (M3) | **KILLED** |
| Raw-connection mutation (M1, M2) | **KILLED** |
| Connection-sharing mutation (M6) | **KILLED** |
| Representative integration harness | **PASS** (§3) |
| High-risk migrated workflows equivalent | **PASS**, diff-reviewed for all six flagged files; live-verified for one (see above) |
| CI from clean environment | **PASS** (`tests/ci_duckdb_clean_environment.R`, both install-allowed and install-forbidden) |
