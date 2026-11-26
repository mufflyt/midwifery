# Git Recovery and Provenance — 2026-11-30

## Starting state (verified, not assumed)

- Local `main` HEAD was `90402fe` ("Resolve dual-lineage manuscript merge"), one
  commit ahead of `origin/main`, unpushed.
- That commit had correctly resolved `manuscript/federal_database_accuracy.qmd`
  and `manuscript/R/build_stats_catalog.R`, but swept in two provenance
  sidecars **with unresolved conflict markers still inside**:
  - `artifacts/agreement_cluster_bootstrap_ci.csv.provenance.json`
  - `artifacts/persistence_denominators.csv.provenance.json`
- `stash@{0}` held the WIP that produced the stash-side content of those
  sidecars (an 11-25 03:16 UTC local run on the old `fd2eca5` base,
  mysterynpi 0.10.0).

## Sidecar adjudication

For each sidecar the producing run, code hash, and artifact hash were
compared:

- The committed CSVs (`d72e3533`, `9799b1b4`) were produced by the
  2026-11-23 statistical-review run and committed together in `3c9a31d`.
- The stash-side JSON describes a *different* run whose CSV outputs were
  never committed (the stash carries the older `f8387cb3` CSV versions).
- Keeping the stash side would have recorded provenance for artifacts that
  run did not produce — a provenance integrity violation (spec 0.1.10).

Resolution: both sidecars restored byte-identical to their `19d27b1`
(PR #347) content. Post-restore verification: both JSONs parse; recorded
code sha `5ad548d5` still matches the current
`build_f2_f3_uncertainty_denominators.R`; repo-wide conflict-marker scan
found zero remaining markers.

Known pre-existing caveat (unchanged by this work): the restored sidecars
record input sha `a067f7bf` for `canonical_source_records.csv`, which is an
untracked local-only input now hashing `81cf8b26` locally — staleness from a
newer local run, present when the sidecars were first committed.

## Push path

1. `90402fe` pushed via **PR #349** (`fix/provenance-sidecar-restore`),
   plus follow-up commits:
   - `d2dfff1` — freeze-consumer registration fix
   - `fdeaa9e` — test repairs (`test_aggregate_gate.R`,
     `test_manuscript_figure_saboteurs.R`,
     `test_federal_database_accuracy_remediation_detect.R`)
   - `1ed81c8` — final fix before merge
   - `e2413ce` — merged as `0d9775f`
2. All CI green before merge; merge commit `0d9775f` on `main`.

## Stash inventory (preserved, none dropped)

| stash | content | disposition |
|---|---|---|
| `stash@{0}` | amcb-license-bridge WIP incl. `normalize_phrase_key` wrapper | Does **not** apply cleanly to current HEAD — its `normalize_text` still routes through the deleted `R/lib/normalize_phrase_key.R`; the parts that mattered were superseded by the `mysterynpi::phrase_key` migration (PR #348, merged `19d27b1`). Retained pending user approval to drop. |
| `stash@{1}` | provenance sidecars (gate churn) | Content adjudicated above; the conflict-marker versions were NOT kept. Retained. |
| `stash@{2}` | WIP on main `54d9383` (cycle 37) | Not yet fully adjudicated; retained per spec 0.1.11. |

## Worktrees

`/Users/tylermuffly/midwifery-fresh` and other linked worktrees inspected;
none held unmerged work conflicting with this campaign. No worktree was
modified or removed except temporary CI-reproduction worktrees created and
deleted by this session.

## Rule compliance

- No `git reset --hard`, no force-push, no stash deletion, no work on `main`
  without a branch (all changes went through feature branches + PRs).
- User-owned unstaged work in the worktree was never staged or committed by
  this session except where explicitly part of a reconciled PR.
