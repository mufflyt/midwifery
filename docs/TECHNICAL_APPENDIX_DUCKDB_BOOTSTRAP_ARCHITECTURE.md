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
arguments, and reformatting.

**Limited alias resolution.** A single, static, unconditional assignment of
a bare driver reference to a name — `con_fun <- duckdb::duckdb` (no parens:
a reference, not a call) anywhere in the file — is tracked, and any later
call through that name (`con_fun()`, alone or as `dbConnect()`'s driver
argument) is flagged exactly as if the literal `duckdb::duckdb()` text were
there. This closes the specific evasion where the driver constructor is
referenced, not invoked, at the point of aliasing (mutation M9). A raw
connection hidden inside a wrapper function's body (`local_connect <-
function(...) { DBI::dbConnect(duckdb::duckdb(), ...) }`, mutation M10) was
already caught before this change — the recursive walk descends into
function bodies the same as any other call argument. What is **not**
resolved: conditional or reassigned bindings, `assign()`/`get()`
indirection, aliasing `dbConnect` itself combined with a driver built by
some other non-literal mechanism, cross-file aliasing, or dynamic dispatch.
Full symbolic/points-to analysis across a whole codebase is a much larger
undertaking than this repo's actual risk profile justifies, and the
project's own convention (call `dbConnect`/`DBI::dbConnect` directly, never
rebind it) makes that residual gap low-cost. This is "closes the obvious
evasions," not "provably exhaustive."

Every recursive descent step is wrapped in `tryCatch` because R's "empty
argument" placeholder (the blank in `df[, "col"]`) is not safely
indexable/iterable and would otherwise crash the scanner on ordinary,
unrelated code.

Run against every tracked `.R` file by `tests/ci_duckdb_ingestion_bootstrap.R`
(§1). Currently: **355 files scanned, 7 distinct raw-connection sites across
5 files, 0 offenders outside the registry.**

This scanner found two real, previously-unmigrated call sites live during
this work — `analysis/audit_identity_flips.R` and
`analysis/measure_taxonomy_scope_ceiling.R` — added to the repo after the
original 40-site migration and before the scanner was built. Both are now
migrated. This is exactly the regression class the scanner exists to catch,
caught in the act rather than in a postmortem.

## Exception registry

`DUCKDB_RAW_CONNECTION_EXCEPTIONS` in `R/lib/medicare_duckdb.R` is a
structured list — not an anonymous inline allowlist — and **site-level, not
file-level.** An earlier version matched by file alone: any raw connection
anywhere in a registered file was silently exempt. That had a real, live
gap, found while implementing this follow-up spec — `tests/ci_duckdb_mutation_tests.R`
was never listed at all, and its three raw connections (M6/M7/M8's mutated
re-implementations of `duckdb_connect()`, which must construct a raw
connection to simulate a broken one) went undetected until the registry was
rebuilt to check every tracked file's actual scan output against it
directly. A file-level entry would also have silently exempted any *new*,
unrelated raw connection added later to an already-registered file
(mutation M12). Both gaps close the same way: an entry now names one exact
site via a `# duckdb-exception: <tag>` comment at that call site, and only a
site actually carrying the matching tag is exempt — not its whole file.

Each entry is `list(file, tag, locator, reason, exception_class, owner,
added_date, removal_condition)` — no free-text-only whitelist. Current
entries (7, at the declared upper bound `DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX`):

| File | Tag | Class | Reason |
|---|---|---|---|
| `R/lib/medicare_duckdb.R` | `bootstrap-definition` | definitional | Is the chokepoint's own definition; necessarily contains the one real `DBI::dbConnect(duckdb::duckdb())` call in the repo. |
| `tests/test_cache_vintage_declared.R` | `synthetic-fixture` | synthetic-fixture | Writes a synthetic fixture via `dbWriteTable()` on an in-memory data frame; no CSV read, no encoding hazard. |
| `tests/ci_duckdb_ingestion_bootstrap.R` | `legacy-defect-control` | negative-control | Deliberately constructs a raw, unbootstrapped connection as the negative control reproducing the original PECOS defect. |
| `tests/ci_duckdb_connection_contract.R` | `raw-baseline-defaults` | test-baseline | Deliberately constructs a raw connection as the baseline for the "threads/memory are UNSPECIFIED and match DuckDB's own default" assertion. |
| `tests/ci_duckdb_mutation_tests.R` | `mutation-m6` | mutation-harness | M6's mutated `duckdb_connect()` re-implementation (cached/shared connection) — the mutation IS a raw-connection stand-in by construction. |
| `tests/ci_duckdb_mutation_tests.R` | `mutation-m7` | mutation-harness | M7's mutated `duckdb_connect()` re-implementation (dropped `read_only` forwarding). |
| `tests/ci_duckdb_mutation_tests.R` | `mutation-m8` | mutation-harness | M8's mutated `duckdb_connect()` re-implementation (dropped provenance attrs). |

The registry is self-checking in both directions: a hit whose `(file, tag)`
pair is not in the registry fails CI (an untagged hit can never match, by
construction), and a registry entry whose `(file, tag)` the scanner no
longer finds is **stale cover** and fails too. An explicit upper bound
(`DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX`, currently 7) fails CI if the
registry grows past it without a deliberate edit to that constant.
(`tests/test_cache_vintage_detect.R` was removed from an earlier,
regex-based version of this registry for the same "stale cover" reason: the
AST scanner correctly never flagged it, because it never executes a real
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
| M4a | `ensure_duckdb_encodings()` call structurally removed from `duckdb_connect()`'s body | Structural check: `grepl("ensure_duckdb_encodings", deparse(body(duckdb_connect)))` | KILLED |
| M4b | Bootstrap disabled, in a genuinely empty `extension_directory`, fresh subprocess | CP1252 fixture must fail closed | KILLED — see `tests/ci_duckdb_clean_environment.R` |
| M5 | Fail-closed error replaced with silent continuation | Absence of an error where one is required | KILLED-by-absence |
| M6 | `duckdb_connect()` returns a cached, shared connection | Independence assertion (temp-table leak between callers) | KILLED |
| M7 | `read_only` forwarding dropped | Read-only write-rejection assertion | KILLED |
| M8 | Provenance attributes omitted | `duckdb_connection_provenance()` returns non-`NA` despite the mutation | KILLED |
| M9 | Driver constructor aliased through a bare symbol (`con_fun <- duckdb::duckdb; con_fun()`) | AST scanner (alias tracking) | KILLED |
| M10 | Raw connection hidden inside a wrapper function's body | AST scanner (recursive descent into function bodies) | KILLED |
| M11 | Stale exception-registry entry (tag no longer matches any scanned site) | Registry stale-cover check | KILLED |
| M12 | New, untagged raw connection added to an already-registered file | Site-level `(file, tag)` matching | KILLED |
| M13 | One row silently missing from an unordered relational output | `tables_equivalent()` → `missing_rows` | KILLED |
| M14 | Same distinct rows, different duplicate counts | `tables_equivalent()` → `duplicate_multiplicity_mismatch` (not missed as a `setdiff()` blind spot) | KILLED |
| M15 | Column type changes but every rendered value looks the same (`42L` vs `"42"`) | `tables_equivalent()` → `type_mismatch` | KILLED |
| M16 | Checkpoint saved directly to its final path, no atomic staging | `save_checkpoint_atomic()`'s promotion invariant — a mutated non-atomic save loses the last-known-good checkpoint to a simulated mid-write interruption | KILLED |
| M17 | Latitude/longitude columns swapped in the cache-column resolver | `resolve_lat_lon_columns()`'s exact-value regression (wrong coordinate values on real distinguishable data) | KILLED |

**M4's two-layer semantics.** An in-process dynamic test (construct a
connection with the bootstrap disabled, see if CP1252 decoding still works)
is confounded on any machine that has ever installed the `encodings`
extension — DuckDB autoloads an already-installed extension regardless of
whether the bootstrap ran, so that test can report "survived" on a warm
developer machine while the actual invariant is perfectly intact. An
earlier version of this suite reported exactly that confounded result as
plain "M4 SURVIVED," with no structural counterpart — a real gap, not a
documented limitation. M4 is split into two independent, always-reported
results: **M4a** (`tests/ci_duckdb_mutation_tests.R`, structural, immune to
autoload by construction since no connection is ever opened) and **M4b**
(`tests/ci_duckdb_clean_environment.R`, dynamic, immune to autoload by using
a genuinely empty `extension_directory` in a fresh subprocess). CI considers
M4 killed only when M4b kills it — M4a is a real, independent contract in
its own right (catching a refactor that silently drops the call while
leaving everything else intact) but proves only that the call *site*
exists, not that the function it calls still does anything. An
already-installed extension on a developer machine can satisfy neither M4a
nor M4b, by construction.

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
- **M4b**: bootstrap skipped entirely, in a genuinely empty
  `extension_directory` — CP1252 decoding fails exactly as in the real
  incident, giving mutation M4 its definitive (authoritative) kill-proof.

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

## Unordered-output equivalence

DuckDB (and SQL generally) makes no row-order guarantee absent an explicit
`ORDER BY`. `resolve_org_ambiguity.R`'s live verification found exactly this:
one of its four outputs was content-identical but not byte-identical, purely
because of row sequencing. Rather than adding an `ORDER BY` solely to make a
byte comparison pass — which would impose a false ordering contract on a
consumer that never needed one — `R/lib/table_equivalence.R`'s
`tables_equivalent(a, b)` compares two data.frames as unordered relational
tables: identical schema (column name set and, per shared column, type),
identical row count, identical multiset of rows respecting duplicate
multiplicity. Row order is insignificant; everything else is significant.
Two traps a naive implementation falls into, and how this one avoids them:

- **Duplicate multiplicity vs. `setdiff()`-blindness**: two tables sharing
  the same *distinct* rows but differing in how many times one repeats look
  identical to a `setdiff()`-based comparison. Rows are hashed into a
  canonical per-row token (fixed alphabetical column order) and compared via
  `table()` counts on both sides, not `setdiff()` on distinct values.
- **Real `NA` vs. the literal string `"NA"`**: `paste0(NA)` renders as the
  string `"NA"`, which could collide with an actual `"NA"` value in a text
  column. Each cell is tokenized with an `is.na()`-status prefix that no
  real string value can produce, so the two cases can never collide.

Verified by `tests/test_table_equivalence.R`: pure permutation passes;
column-order differences don't cause a false mismatch; added/missing rows,
changed values, changed duplicate counts, type mismatches masked by
identical rendered text, and schema mismatches are all detected; both-empty
tables are equivalent. Mutations M13–M15 exercise the same helper from
`tests/ci_duckdb_mutation_tests.R`.

## Order-semantics declarations

`tests/fixtures/duckdb_artifact_order_semantics.csv` declares, for every
output artifact touched by the six migrated high-risk workflows, whether it
is `ordered` (a downstream consumer relies on row sequence, so the producer
must impose it explicitly) or `unordered` (compare relational content, not
serialized bytes). Declared up front, not inferred after a test fails —
`tests/ci_duckdb_verification_ledger.R` asserts every row has one of exactly
these two values and that all four of `resolve_org_ambiguity.R`'s outputs
are covered. Every artifact in the current declaration is `unordered`: none
of the six workflows' outputs have an identified downstream consumer that
reads them positionally.

## Exception-registry provenance (4 → 7 is a measurement correction)

The registry grew from 4 file-level entries to 7 site-level entries during
closure. Read without context, that looks exactly like new raw connections
being introduced — it is not. `tests/fixtures/duckdb_exception_registry_provenance.csv`
classifies all 7 entries as `PREEXISTING_AND_PREVIOUSLY_UNDERCOUNTED` (the
only other allowed value, `INTENTIONALLY_ADDED_BY_THIS_CHANGE`, applies to
none of them), and `tests/ci_duckdb_exception_provenance.R` **re-derives**
that claim from git history on every run rather than trusting a comment: for
each registered file, it checks out the base commit's own content
(`15051d939905048e5d4c380448eb6e9b4e5b5325`) and confirms the (unmodified)
scanner already finds the corresponding raw-connection site(s) there. The
three sites that account for the 4→7 delta —
`tests/ci_duckdb_mutation_tests.R`'s M6/M7/M8 mutation-harness
re-implementations — are proven present in the base commit's own tree this
way, not merely asserted: `git show 15051d9:tests/ci_duckdb_mutation_tests.R`
scanned by the unmodified scanner finds 3 sites, and that file was never
listed in the base commit's own (file-level) registry at all. That is the
actual defect being corrected: an omission at commit time, not a new raw
connection introduced afterward. Result: **new unjustified exceptions
introduced: 0.**

The report never conflates two different measures under the word "entries"
again: `exception_files` (5 — the number of distinct files containing a
registered exception) and `exception_sites` (7 — the number of distinct
registered call sites) are printed as two separately labeled numbers by
both `tests/ci_duckdb_ingestion_bootstrap.R` and the aggregate gate.

## Live-verification ledger

`tests/fixtures/duckdb_migration_verification_ledger.csv` is a
machine-readable record, one row per high-risk migrated workflow, with
`live_status` restricted to exactly `PASS`, `FAIL`, or
`NOT_RUN_INPUT_UNAVAILABLE` — no `DEFERRED`, no `LIVE_VERIFIED`, no status
that could be misread as passing. Its purpose is narrow: make it impossible
for "5 of 6 workflows were never re-run against real production data" to
quietly become "all 6 are verified" just because the generic
contract/AST/integration-harness coverage is green for all six (which it
genuinely is — see `generic_contract_status` on every row). Only
`resolve_org_ambiguity.R` has `live_status = PASS`. The other five are
`NOT_RUN_INPUT_UNAVAILABLE` with a specific `reason` each — and those
reasons are not uniform. Two are genuinely blocked
(`build_pecos_organization_affiliations.R`'s PECOS raw reassignment-file
distribution was discontinued by CMS after 2019; `extract_nppes_midwives.R`
is hardcoded to one specific NPPES snapshot not present on this machine).
Three (`build_midwife_panel.R`, `build_care_compare_organization_panel.R`,
`extract_dac_facility_affiliations.R`) have `inputs_available = YES` and
were simply not run this session — a scope/time boundary, not a data
blocker, recorded as such rather than lumped in with the genuinely-blocked
two. `tests/ci_duckdb_verification_ledger.R` fails CI if any
`NOT_RUN_INPUT_UNAVAILABLE` row is ever shown as `PASS` without an actual
live run producing evidence for it ("deferred workflows represented as
PASS" is asserted `== 0` on every run), or if a row's reason is dropped.

**Post-merge tracking**: [GitHub issue #164](https://github.com/mufflyt/midwifery/issues/164)
carries the five deferred workflows forward — required inputs, expected
invocation, output artifacts, order semantics, equivalence comparator, and
success criterion for each — so they are discoverable and runnable without
redesigning this test suite when their source inputs next become available.
Closing an item there does not reopen this architecture PR; it updates the
ledger row and closes that one item.

## Aggregate CI gate

`tests/ci_duckdb_architecture_gate.R` stamps the exact commit SHA it ran
against on every invocation (`ci_evidence_commit()`), and runs every
sub-check above as its own subprocess (never assuming a result — a
sub-check that errors, times out, or produces no recognizable
`PASS (0 failures)` line is reported FAILED, not skipped into a green
aggregate). Named sub-results: raw connections outside the registry (exact
count, plus `exception_files`/`exception_sites` printed separately),
registry self-consistency, encoding regression suite,
exception-registry provenance (4→7 explained, 0 new unjustified), canonical
connection contract, independent connection semantics, clean-environment
bootstrap, the full AST/structural/dynamic mutation suite (M1–M17), the
unordered-output equivalence helper, the geocode migration-only diff (a
fact about a pinned commit, re-verified from git history rather than the
mutable working tree, so it stays checkable indefinitely), the geocode
bug-fix tests, and the live-verification ledger's honesty check. A skipped
clean-environment run is never collapsed into green — it is scored as a
failed sub-result exactly like an actual defect would be. Results from an
earlier SHA are never used as acceptance evidence for a later one; the
gate must be re-run on the exact SHA being merged.

## Definition of done

| Item | Status |
|---|---|
| Base architecture commit | `15051d939905048e5d4c380448eb6e9b4e5b5325` |
| Architecture frozen at | `144f8b5b74d07043792c0f08ea9b2a04336b47b6` |
| Closure/provenance commit | `95d5218c1b45feeba3e1d9a165ee7bfdfc40af4a` |
| Raw production DuckDB connection sites (outside registry) | **0** |
| Exception files | **5** |
| Exception sites | **7** |
| New unjustified exceptions introduced | **0** (all 7 sites' raw connections proven present at the base commit — see provenance section above) |
| Stale exceptions | **0** |
| Canonical connection contract | **PASS**, **9/9** (`tests/ci_duckdb_connection_contract.R` §1) |
| Independent-connection semantics | **PASS**, **5/5** (§2) |
| Encoding regression fixtures | **PASS**, **6/6** (`tests/ci_duckdb_ingestion_bootstrap.R` §2) |
| Bootstrap fail-closed mode | **PASS** (`tests/ci_duckdb_clean_environment.R`, install-forbidden scenario) |
| M4b clean-environment kill | **PASS** |
| M4a structural invocation | **PASS** |
| AST/static mutations killed (M1, M2, M9, M10, M11, M12) | **6/6** |
| Total mutations killed (M1–M17) | **17/17**, zero `NOT_RUN` |
| Unordered-equivalence regression tests | **12/12** (`tests/test_table_equivalence.R`) |
| Representative integration harness | **PASS** (§3) |
| Geocode connection migrations isolated | **YES** (commit `c13bce1`, pure substitution, re-verified from git history by the aggregate gate; 4 unrelated fixes split into their own commits) |
| Lat/lon regression tests | **PASS** (`tests/test_geocode_latlon_rename.R`) |
| Checkpoint interruption tests | **13/13** (`tests/test_geocode_checkpoint_safety.R`) |
| Live-verification ledger: workflows tracked | **6** |
| Live-verification ledger: PASS | **1** (`resolve_org_ambiguity.R`) |
| Live-verification ledger: FAIL | **0** |
| Live-verification ledger: NOT_RUN_INPUT_UNAVAILABLE | **5** |
| Deferred workflows represented as PASS | **0** |
| Post-merge live-verification issue | [#164](https://github.com/mufflyt/midwifery/issues/164) |
| Production data modified | **NO** |
| Arbitrary ORDER BY introduced for equivalence | **NO** |
| Aggregate architecture CI gate | **PASS** (re-run on exact final SHA) |
| Architecture merge recommendation | **YES** |
