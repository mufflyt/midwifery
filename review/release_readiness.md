# Release Readiness — 2026-11-30

## Merge state

| PR | content | CI | mergeable? |
|---|---|---|---|
| #349 | provenance sidecar restore + freeze-consumer fixes | all green | merged `0d9775f` |
| #348 | mysterynpi phrase_key delegation | all green | merged `19d27b1` |
| #350 | D10 cohort vintage gate (V1–V5) | all green | merged `8227996` |
| #351 | org apostrophe normalization | pending at time of writing | pending |
| #352 | D5 Open Payments demotion + docs | pending at time of writing | pending |
| #353 | isochrones cache path + reproducibility report | pending at time of writing | pending |
| (this) | review package completion | n/a | pending |

## Scientific release blockers

1. **D10-E6 — cohort snapshot re-pin (BLOCKER).** The pinned
   `midwives_geography_guarded.csv` is the stale 16,892 vintage; the freeze
   is 16,775. `repin_frozen_cohort.R` must run where current person-level
   inputs exist. Until re-pinned, V5 fails on machines holding the stale
   file — this is the gate working as intended, not a regression.
   Manuscript numbers remain frozen per campaign rules.

2. **D5 — PI sign-off on canonical linkage.** Evidence and demotion are in
   `review/d5_*`; the formal "AMCB resolver is canonical" decision is
   documented but should be countersigned before the next manuscript build.

## Non-blocking debt (documented, not fixed)

- renv dependency manifest (Task 5.2) — deferred; no untested lockfile
  committed.
- `stash@{0..2}` — preserved; `stash@{0}` eligible for deletion only after
  user approval.
- Local stale inputs (`midwives.csv` Aug-14 vintage, frozen_stage2
  `midwives_with_nppes.csv` sha `93dc2e8b` vs manifest `5336b5f5`) —
  machine-local, not part of the repo contract.

## Verification evidence

- `tests/test_cohort_vintage.R`: V1–V4 pass at 16,775; V5 fails locally on
  the stale pinned CSV (expected until re-pin).
- `tests/test_org_apostrophe_normalization.R`: PASS on PR #351 branch.
- `tests/test_geocode_ob_hospitals_cache_path.R`: PASS (4 assertions).
- `review/mutation_evidence.csv`: 23/24 spec mutations DETECTED.
- CI: see per-PR check status above; nothing merged red.

## What this release does NOT do

- Does not regenerate manuscript numbers.
- Does not change the analytic cohort, NPI assignments, or linkage
  tie-break rules.
- Does not delete stashes, worktrees, or person-level artifacts.
