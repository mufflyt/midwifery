# Scientific Integrity — Executive Summary

Campaign date: 2026-11-30. Repository: `mufflyt/midwifery`.

## Bottom line

The frozen analytic cohort is **16,775** clinicians (freeze
`reconcile_ab_20261022T134500_remove_fuzzy_surname_matching`; class-4 fuzzy
surname matching retired). The manuscript-facing pinned snapshot drifted to
the older **16,892** vintage on this machine — a **117-member** staleness,
not the 6-member gap originally reported; the drift direction and magnitude
were only fully characterized once the vintage gate (V1–V5) was built.
**No manuscript numbers were regenerated.** The drift is now detected by a
failing gate rather than silent.

## Workstreams

| workstream | PR | status |
|---|---|---|
| Provenance recovery + push | #349 | merged `0d9775f` |
| mysterynpi `phrase_key` delegation (person names) | #348 | merged `19d27b1` |
| D10 cohort vintage gate | #350 | merged `8227996` |
| D15 org-side apostrophes → `phrase_key` | #351 | open, CI running |
| D5 Open Payments linkage demotion/documentation | #352 | open, CI running |
| Tech debt: isochrones path + reproducibility report | #353 | open, CI running |

## Key findings

1. **D10 — pinned snapshot is stale, frozen cohort is authoritative.**
   `artifacts/frozen_cohort/midwives_geography_guarded.csv` on this machine
   is the 16,892 vintage (sha `94551381`, untracked); the fingerprint pins
   16,775 (sha `f8063509`, frozen 2026-10-30). Re-pinning requires
   `repin_frozen_cohort.R` on a machine holding current person-level
   inputs — **blocked, escalated**. V5 now fails closed on any machine
   where the file is present.

2. **D5 — the "83.6% disagreement" is a comparison artifact, not a
   linkage crisis.** `crossref_open_payments_to_type2_npi.py` and the
   canonical AMCB resolver consume different input sources and tie-break
   rules; PR #352 demotes the Python crosswalk to comparison-only and
   documents the decomposition in `review/d5_*.csv|md`. No NPI
   reassignment was made.

3. **D15 — org-name keys now delegate to `mysterynpi::phrase_key`.**
   `.norm_school`, `street_key`, `norm_institution_name`, and
   `embedded_org_text`-adjacent keys previously turned `ST JOHN'S` into
   `ST JOHN S`. Inventory + measured impact in
   `review/organization_normalization_*.csv`.

4. **Mutation campaign** — 24 spec-required mutations mapped to detectors
   in `review/mutation_evidence.csv`: 23 DETECTED, 1 NOT ATTEMPTED
   (renv lockfile mutation — awaits the renv workstream).

## Remaining PI decisions / blockers

- **D10-E6 (blocker):** re-pin `midwives_geography_guarded.csv` to the
  16,775 vintage on a machine with current person-level inputs; until then
  README Figure 3 / STROBE counts cannot be regenerated and V5 fails
  locally by design.
- **D5 canonical-selection:** documented evidence favors the AMCB resolver
  path; formal sign-off recorded in `review/d5_tiebreak_comparison.md`.
- **renv (Task 5.2):** deferred — no lockfile committed without a tested
  restore.
- **Stashes:** `stash@{0..2}` retained; `stash@{0}` proven superseded but
  not dropped pending user approval.
