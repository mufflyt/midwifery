# Adjudication queue and status (machinery around the 327 decisions)

Derived views over the canonical truth set (`artifacts/truth/`); nothing
here is a second source of truth. `case_id` IS the frozen
`adjudication_id`; the reviews table is the only authority on what has
been adjudicated; workflow state is derived, never hand-edited.

- `Rscript analysis/build_adjudication_queue.R` -> writes
  `adjudication_queue.csv` (unresolved cases only, blinded, batch-tagged,
  byte-stable) and `adjudication_status.json` (git SHA, population
  checksum, counts, `complete` -- true only at 327/327 with zero
  unresolved / duplicate / conflicting / invalid).
- Reviewer fills `verdict` with exactly `MATCH` / `NONMATCH` /
  `INSUFFICIENT` plus reviewer_id, evidence_source, locator, reason,
  review_date. Blank rows = not yet reviewed. `INSUFFICIENT` counts as
  adjudicated and maps to the frozen `indeterminate` (never
  auto-accepted downstream).
- `Rscript analysis/import_adjudication_verdicts.R <file>` -> validates
  (unknown ids, vocabulary, blanks, board contamination, matcher-language
  leakage all fail BEFORE any write), appends append-only, is idempotent,
  and refuses to change a recorded verdict (revisions go through the
  resolution protocol).

Deliberate deviation from the closure spec, recorded here: the queue
carries NO "machine recommendation/reason" columns. The frozen protocol
(and its mutation-tested blinding guards) forbids matcher conclusions on
any reviewer surface, per the owner's earlier instruction that a reviewer
must not see whether the algorithm found a row easy, ambiguous, matched,
or rejected.

Generated CSV/JSON here are person-level or run-state and stay out of
git; this README and the code are the versioned surface.
