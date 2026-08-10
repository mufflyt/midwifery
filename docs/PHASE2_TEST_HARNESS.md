# Phase 2 test harness — requirements and the evidence for each

The 21-cycle adversarial run is a **bug-discovery exercise, not a validated
test campaign**. It found real, consequential defects; it also produced vacuous
tests, defeatable tests, detectors wrong in both directions, and artifacts of
contaminated provenance. This records what must change before anything
restarts, with the measured evidence for each requirement rather than an
assertion that it matters.

Phase 2 starts with a **new ledger and a new artifact directory**. It does not
resume at cycle 22.

---

## R1. Fail if an expected column is absent

**Evidence.** Three tests passed against data that did not contain the column
they claimed to check, because `!is.na(NULL)` is `logical(0)` and
`all(NULL == FALSE)` is `TRUE`:

- cycle 8's `T77` read `general_fertility_rate` from an artifact that has no
  such column, reported "0 of 11,762, 0.00%" and passed regardless of the data.
  **The claim it certified was reported to the owner as verified.**
- cycle 20's delegate-classification test passed on a pre-fix artifact for the
  same reason.
- cycle 16's fix of `T77` then *crashed* rather than failing when given a
  wrong-but-non-NA column name — in a loop that greps for `FAIL`, a crash is
  indistinguishable from silence.

**Requirement.** Assert column presence before computing anything from it, and
make a missing column a clean `FAIL`, never an exception and never a pass.

---

## R2. Every test must prove it executed at least one assertion on non-empty data

**Evidence.** Beyond R1, cycle 14's `T70` was written when zero `hg_` blocks
existed, so it could not fail; cycle 4 caught the identical pattern
(`cond || known_issue > 0`, which passes automatically whenever the known issue
exists). A test that cannot fail reads as coverage.

**Requirement.** A test reports the number of rows it actually evaluated.
Zero rows where non-empty data is required is a failure, not a pass. The
harness prints an assertion count per file and fails a file that ran none.

---

## R3. Isolate artifacts per cycle

**Evidence, measured 2026-08-10.** Running **two** test files dirtied **nine**
tracked artifacts. `test_cycle22_idempotence.R` executes pipeline scripts twice
by design, rewriting artifacts and their provenance sidecars.

**The suite has never been read-only.** This is why cycle 21's stale-artifact
count read 2 and 7 in consecutive runs of the same check: the suite was
mutating the artifacts the freshness tests measure.

**Requirement.** Tests read from an immutable snapshot. Any test that must
execute a pipeline stage does so in a scratch directory, never in `artifacts/`.
A clean tree before the suite must be a clean tree after it — enforced by a
`git status` check at the end of the run.

---

## R4. One writer only; no concurrent rebuilds

**Evidence.** Two agents ran cycle 20 simultaneously and produced two full
suites for the same cycle — 28 assertions, ~6 overlapping. Cycles 22 and 23
committed **after** the cron was cancelled, from a second session. During
cycle 21, `county_base.csv` was rewritten two seconds after a dependent
artifact, mid-measurement.

**Requirement.** A lock file claimed at cycle start and released at commit.
A cycle that cannot claim the lock exits without writing. The ledger records
one authoritative row per cycle, written by the lock holder.

---

## R5. No timestamp or stamp-file shortcuts

**Evidence.** Cycle 16's `T164` asserted only that
`data/.county_base_rebuilt_after_cycle16` exists — satisfied by `touch`,
**and its own failure message instructed exactly that**. It was replaced with a
content check against a published external figure (national `women_15_44` must
fall in 60–70M), which the pre-fix artifact fails and the rebuilt one passes.

**Requirement.** Freshness is established by content — a digest, or a value
checked against an external source of truth. Never by mtime ordering or the
existence of a marker file.

---

## R6. Parsed-code checks, not regex, for source inspection

**Evidence.** Every text-based detector in the run was wrong, and in both
directions:

| detector | error |
|---|---|
| cycle 1 duplicate-rule grep | missed 3 files, matched on one label spelling |
| cycle 9 duplicate-function grep | missed `%||%` — the only **divergent** duplicate — because it is written in backticks |
| cycle 10 join-cardinality scan | **5 false positives** (declaration on a continuation line) **and 12 misses** |
| cycle 14 clip-gate sweep | flagged its own explanatory comment |

The pattern is consistent: a text-shaped detector is wrong about exactly the
code that does not look ordinary, and that code is disproportionately where the
damage lives.

**Requirement.** Inspect `parse()`d code and read argument names off calls.
Where a text scan is unavoidable, strip comments first and state in the test
why parsing was not possible.

---

## R7. One authoritative ledger row per cycle

**Evidence.** The current ledger holds **35 `## Cycle` headings for 21 cycles**
— cron and manual runs both appended, and the rebase rule "keep both sides"
preserved duplicates. Cycle 2, 5, 7, 8 and 20 each appear twice. An audit trail
with two entries per cycle cannot establish what a cycle did.

**Requirement.** Machine-written, one row per cycle, keyed on cycle number, with
the pushed SHA. Prose belongs in the commit message; the ledger is data.

---

## R8. Tests must discriminate, and the check must target the right test

**Evidence.** The rule was followed and still nearly failed: in cycle 10, the
discrimination check *did* go red when the bug was reintroduced — but via the
repo-wide ratchet, **not** the targeted test, which was blind because the file
was outside its scope. Confirming "the suite went red" is not confirming that
the test you wrote works.

**Requirement.** Discrimination is verified per assertion, and the failure
message must name the reintroduced defect. A suite-level red is not sufficient
evidence.

---

## Carried into Phase 2 from the old run

Only these survive as inputs; everything else restarts.

- `docs/DECISIONS_CONTRACT.md` — nine rulings, unresolved.
- `docs/COHORT_REFREEZE_2026-08-10.md` — the pin is now consistent at 16,892.
- The confirmed defect list and its fixes, already committed and independently
  verified against external figures where possible.
- `.quarantine/killed_session_20260810/` — 15 regenerable artifacts and two
  unfinished patches, including a name-variant fix worth reviewing on its
  merits (an NPI appearing under different surnames across snapshots makes a
  valid match look false).
