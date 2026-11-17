# Technical Appendix: mysteryroster Pin Audit

**Repository**: `midwifery`
**Scope**: `R/lib/artifact_provenance.R` (`SEMANTIC_PACKAGES`), `tests/test_semantic_package_fingerprint.R`, and the 4 committed-output scripts that depend on `mysteryroster`: [`remake_oig_07_09_00440_midwifery.R`](../remake_oig_07_09_00440_midwifery.R), [`build_leave_one_source_out_sensitivity.R`](../build_leave_one_source_out_sensitivity.R), [`audit_migration_corroboration_by_transition.R`](../audit_migration_corroboration_by_transition.R), [`analysis/oig_style_source_consistency.R`](../analysis/oig_style_source_consistency.R)
**Related**: [`docs/TECHNICAL_APPENDIX_MYSTERYNPI_MIGRATION.md`](TECHNICAL_APPENDIX_MYSTERYNPI_MIGRATION.md) (the precedent this audit mirrors)
**Investigation date**: 2026-11-16/17
**Status**: provenance gap closed; 2 of 4 consuming scripts' committed output re-verified; 1 confirmed clean, 1 found stale for a reason unrelated to mysteryroster; 1 blocked on missing local intermediates. No new CI job added (explicit scope decision).

## 1. Why this audit exists

`mysterynpi` went through a 5-PR audit (#312, #314, #315, #316) because its version
silently changes scientific results (name-matching decisions), and nothing recorded
which build produced which committed number. `mysteryroster` sits in the identical
risk class and had never received any of this scrutiny:

- **No pin existed anywhere** — not in `ci.yml`, not in `nightly.yml`, not in any
  script header, not in `SEMANTIC_PACKAGES`.
- **CI never installs or runs anything that touches it.** Every consuming script is
  a manual, developer-run research script. There is no automated, continuously
  rebuilt artifact at stake the way the FROZEN AMCB-NPI cohort was for `mysterynpi` —
  this changes the shape of "promotion" (no cohort-freeze gate to clear) but not the
  stakes of the audit itself.
- **It already has a live, undocumented history of real defects.** A concurrent
  session found and fixed two on 2026-11-12: `attribute_source_vintage_audit()`
  silently corrupting every composite-family row (`dplyr::bind_rows()` on a named
  list treats the names as a nested-column key, not a row-bind instruction — every
  other column came back `NA` for those rows), and an overclaiming "confirmed"
  wording in `attribute_location_specificity()`'s generated prose that directly
  contradicted its own next sentence. Neither touches a function this repo's
  *committed* scripts call (confirmed by grep against every consuming script before
  concluding this), but it proves the package moves under us with nothing watching.

## 2. The actual blast radius

Checked by inspecting every `write_with_provenance()`/`write_csv()` call site's
gitignore status in every script that loads `mysteryroster` — 10+ scripts load the
package, but only 4 have tracked, committed output:

| Script | Tracked output |
|---|---|
| `remake_oig_07_09_00440_midwifery.R` | 20 files in `artifacts/oig_remake/*.csv` |
| `build_leave_one_source_out_sensitivity.R` | `artifacts/truth_fusion_leave_one_out_sensitivity.csv` |
| `audit_migration_corroboration_by_transition.R` | `artifacts/migration_corroboration_summary_by_transition.csv`, `artifacts/migration_corroboration_spike_vs_control.csv` |
| `analysis/oig_style_source_consistency.R` | 4 `artifacts/oig_style_*.csv` files |

One layer further upstream, `build_truth_fusion_predictions.R` (mysteryroster-
dependent, gitignored output) feeds `classify_migration_moves_full_panel.R`'s
headline "movers are ~44x harder to confirm" finding via
`truth_fusion_predictions_dawid_skene.csv`. The one real Dawid-Skene bug in
mysteryroster's history (`9513fb8`, 2026-11-05 — a flat-tie abstention edge case on
disconnected worker-task graphs) was confirmed, by reading its own diff, to be
**documentation/warning-text only**: "No prediction-computation behavior was
changed." Not a live risk to that finding.

## 3. Closing the provenance gap

Added `"mysteryroster"` to `SEMANTIC_PACKAGES` in `R/lib/artifact_provenance.R`.
Zero call-site changes needed — every future `write_with_provenance()` call now
records mysteryroster's version + `source_sha`, exactly how the mechanism (built for
mysterynpi) was designed to generalize. Extended
`tests/test_semantic_package_fingerprint.R` with T1b/T5b/T10b, mirroring T1/T5/T10's
mysterynpi-specific assertions, so an accidental removal is caught the same way.

My local install was updated to current HEAD
(`de1aa5d4e4262e8006254e3463c0e0a80eec56ba`) before this audit began.

## 4. Differential audit results, per script

Each script was re-run end-to-end in an isolated `git worktree` under the current
mysteryroster HEAD, with only genuine read-only inputs symlinked in (confirmed, per
script, by checking every `read_csv()`/`write_with_provenance()` call site before
linking anything — see §6 for why this check matters), and the fresh output
byte-diffed against the already-committed CSV.

### 4a. `remake_oig_07_09_00440_midwifery.R` — clean

All 20 files in `artifacts/oig_remake/*.csv` are **byte-identical** to the committed
versions. `diff -q` against every file, zero differences.

### 4b. `build_leave_one_source_out_sensitivity.R` — clean

`artifacts/truth_fusion_leave_one_out_sensitivity.csv` is **byte-identical**. This
script runs all 6 source-exclusion variants through both `majority` and
`dawid_skene` (Crowd-Kit) fusion methods (RETICULATE_PYTHON pointed at
`~/.venvs/mysteryroster-crowdkit`) — roughly 2 hours of wall-clock runtime,
219,550-entity-year panel each pass. No difference anywhere.

### 4c. `audit_migration_corroboration_by_transition.R` — real diff, root-caused to data, not mysteryroster

Both `artifacts/migration_corroboration_summary_by_transition.csv` and
`artifacts/migration_corroboration_spike_vs_control.csv` **differ** from the
committed baseline — e.g. `any_corroboration` moves 106→101 of 966, and several
per-transition `n_any_corroboration` counts shift (6→4, 5→9, 1→5, 56→55, 101→92,
35→37).

**Root cause, confirmed with hard numbers, not assumed:**

1. The only mysteryroster function this script calls,
   `enrollment_move_lead_lag()`, is **byte-identical** between the mysteryroster
   commit active when the baseline was committed (2026-11-05 15:36, i.e. `62c7d64`,
   the most recent mysteryroster commit at or before that timestamp) and current
   HEAD — confirmed by extracting and diffing the exact function body at both
   commits directly (`git show <sha>:R/lead_lag_staleness.R`), not by reading the
   surrounding unified diff's context lines. The `wilson_ci()` relocation into
   `R/lib/wilson_interval.R` (this repo's own commit `945641a9`) carries the
   identical formula, confirmed line-by-line, and only affects CI columns, not the
   `n_any_corroboration` counts that actually moved.
2. Two of the script's input files were modified the day *after* the baseline was
   committed: `artifacts/physician_compare_historical_midwives.csv` (Nov 6, 13:03)
   and `artifacts/pecos_revalidation_cohort_state_by_year.csv` (Nov 6, 13:10) —
   both by this repo's own commit `30493777`, "Sub-annual NPPES panel + 3 new DAC
   vintages for finer spike resolution," part of the already-documented sub-annual
   migration investigation, unrelated to this audit.
3. The Medicaid DuckDB warehouse the script also queries is unchanged (file mtime
   2026-10-22, predating the baseline).

**Conclusion**: this script's committed output is stale relative to richer DAC/PECOS
vintage coverage recovered the day after it was committed — not affected by the
mysteryroster pin. Whether to refresh the committed CSVs with that richer coverage
is a separate, legitimate follow-up (a "promotion"-style decision about updating
already-published numbers), explicitly **not** acted on here — out of scope for a
pin audit.

### 4d. `analysis/oig_style_source_consistency.R` — blocked, not re-auditable right now

Cannot be re-run: 3 of its 8 required inputs are gitignored, local-only
intermediates that no longer exist on disk —
`artifacts/cohort_midwives_tier1_tier2_bon_validated.csv`,
`artifacts/midwife_pecos_organization_affiliations.csv`,
`artifacts/dac_cnm_locations.csv`. These were present when this script's output
(PR #291) was produced in early November and have since been cleaned up; they are
not something this audit caused. Regenerating them means running their producing
scripts (`build_pecos_organization_affiliations.R`, `extract_dac_cnm_education.R`,
and a third), which is its own task — deferred, not silently skipped. The script's
header now carries the pin with this limitation stated explicitly.

## 5. Pin, within the scope that actually exists

No CI job installs `mysteryroster` today (confirmed: zero references in `ci.yml`/
`nightly.yml`), unlike `mysterynpi`, whose CI integration already existed before its
audit. **No new CI job was added — explicit scope decision.** Each of the 4
consuming scripts' header now states the exact expected install command:

```r
remotes::install_github("mufflyt/mysteryroster@de1aa5d4e4262e8006254e3463c0e0a80eec56ba")
```

Whether to go further and wire `mysteryroster` into an actual CI job is a separate,
larger architecture decision, deferred.

## 6. A mistake made during this audit, and the rule it produced

Early in this audit, `artifacts/migration_corroboration_adjudication.csv` — one of
`audit_migration_corroboration_by_transition.R`'s own *output* files, not an input —
was symlinked into the isolated worktree by mistake, alongside the genuine read-only
inputs. The script's own write call followed that symlink straight through into the
live main checkout, overwriting a shared, gitignored file with no backup taken
first. The file is not git-tracked (so no history was lost) and is in principle
fully reproducible, but its companion `.provenance.json` sidecar was stale (dated
2026-11-05) relative to the CSV it described (already regenerated more recently by
an unrelated process before this audit touched it), so the exact pre-overwrite
provenance cannot be fully reconstructed.

Fixed by removing the bad symlink, confirming every other script's read/write split
before linking anything (§4's method), and re-running cleanly — the resulting diff
(§4c) was confirmed identical to the one observed under the mistaken setup, so the
mistake did not itself corrupt this audit's findings. Going forward: never symlink a
script's own output path into a worktree; only genuine read-only inputs. Before any
operation that might overwrite a file in the shared main checkout, snapshot it first
using this repo's own existing `.pre_<what>_<timestamp>` convention (precedent:
`artifacts/frozen_cohort/midwives_geography_guarded.csv.pre_repin_20261030T002231`).

## 7. What remains open

- **§4c**: whether to refresh `audit_migration_corroboration_by_transition.R`'s
  committed output with the richer DAC/PECOS vintage coverage now available.
- **§4d**: regenerating the 3 missing local intermediates so
  `analysis/oig_style_source_consistency.R` can be differentially re-audited.
- **CI integration** (§5): whether any of these 4 scripts should become part of the
  tested, continuously-rebuilt pipeline, the way `mysterynpi`'s consumers already
  are.

None of the above are acted on in this PR.
