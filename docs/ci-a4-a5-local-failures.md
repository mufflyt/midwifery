# Why A4 and A5 fail locally and pass in CI

*Investigated 2026-11-12, during the state-source-audit reproducibility work.
Raised because the full gate suite was not green on a development machine.
No check was weakened, and nothing here is a reason to relax one.*

## Summary

`tests/ci_artifact_contracts.R` reports two failures on this machine:

```
FAIL A4: 8 row(s) carry NPPES geography with neither an accepted npi nor a
         recorded class5_candidate_npi, UP from 0.
FAIL A5: the Table 1 CSV and markdown do not describe one cohort --
         table1_csv_n=12171 table1_md_n=12171 canonical_n=11920.
```

Both have **one root cause**, and it is not in the tracked repository:
`artifacts/amcb_npi_linkage_FROZEN.csv` on this machine is the raw August
freeze (dated 2026-08-14, 54 columns, SHA-256 `dbcc76f4…`) and **predates the
`match_status` column that `reconcile_linkage.R` adds**. It is person-level
and gitignored (`.gitignore:607`), so it exists only here.

## Why each check fails

**A4.** The contract is that NPPES geography may appear only behind an
accepted `npi` or a recorded `class5_candidate_npi`. Eight rows carry a state
and city with neither. Every one of them has
`npi_match_status == "ambiguous_unruled_out_component"` — a connected group
the bijection could not decompose. `reconcile_linkage.R` is what resolves
those into `match_status` and promotes or records the candidate; this
unreconciled freeze never had that pass run against it, so the geography sits
on rows whose identity was never settled. The check is correct and the data
is wrong, in that order.

**A5.** The baseline in `tests/ci_table1_cohort_baseline.txt` records the
known mismatch as `table1_csv_n=11920 …`. The CSV has since been rebuilt to
12,171, so the CSV and the markdown now **agree** — real progress on the
original defect — while `canonical_active_primary()`, evaluated against this
stale freeze, still answers 11,920. The observed string therefore matches no
baseline line, and the gate fails. The disagreement is between the current
Table 1 and an old freeze, not between the two Table 1s.

**The same cause breaks the stats catalog.** `mw_build_catalog()` aborts here
on `sum(active_unmatched_by_reason) == active_unmatched_n`, preceded by four
`Unknown or uninitialised column: match_status` warnings — the same missing
column, surfacing in a third place.

## Confirmed independently, 2026-11-13, by the freeze's own manifest

The first pass of this investigation inferred the staleness from a missing
column. There is stronger evidence sitting beside the file: its own tracked
manifest, `artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json`, records what
the freeze is supposed to be, and the file on this machine is not it.

| | manifest says | file on disk |
|---|---|---|
| sha256 | `9f224007d99ac91d…` | `dbcc76f420ac9be8…` |
| rows | 22,357 | 22,309 |
| columns | 60 | 54 |
| `cohort_members` | **16,775** | **16,898** |
| run | `reconcile_ab_20261022T134500_remove_fuzzy_surname_matching` | — |

So the freeze on disk is the predecessor of the 2026-10-22 reconciliation
that removed fuzzy surname matching (17,028 → 16,775, NEWS 2026-10-22). Every
copy on this machine is the same `dbcc76f4` file — checked in
`~/midwifery-osmde`, `~/mw-truth` and two `Broken_Mac_Rescue` trees — so the
reconciled freeze cannot be restored here, only regenerated.

### The gate that would have caught it, and the 94 scripts that skip it

`verify_linkage_freeze()` in `R/lib/cohort_definitions.R` does exactly this
comparison and refuses a freeze its manifest does not describe. **94 of the
100 scripts that read the freeze never call it** — only the six Trilliant
producers do. That is how
`artifacts/cohort_midwives_open_payments_profile_supplement.csv` came to be
rebuilt on 16,898 members and reported against a published figure computed on
16,775: not a wrong calculation, a wrong cohort, silently. The guard was added
to `extract_open_payments_profile_supplement.R` on 2026-11-13, so that
producer now refuses unless `ALLOW_FREEZE_SHA256` is set deliberately. **The
other 93 are not fixed**, and sweeping them is a separate change: the guard
has to be added one producer at a time, because each has to be re-run and its
artifact re-checked afterwards, and some legitimately analyse a pinned
historical freeze.

## Why CI is unaffected

| check | behaviour without the freeze (CI) |
|---|---|
| A4 | **skips** — `ci_skip("amcb_npi_linkage_FROZEN.csv absent … A4 asserts locally only")` |
| A5 | **passes** — `agree <- csv_n == md_n && (is.na(canon_n) \|\| csv_n == canon_n)`; with 12,171 == 12,171 and `canonical_n` unchecked, it is TRUE |

Both failures are therefore artefacts of a development machine holding a
superseded person-level file. They are real, and they are local.

## What would actually fix it

Regenerate the freeze through `reconcile_linkage.R` so it carries
`match_status`, then rebuild `artifacts/table1_midwives.csv` from it. That
needs the person-level enrichment inputs in `build_table1_midwives.R`'s
`TABLE1_ENRICHMENT`, which are absent from this machine — the same blocker
recorded in `tests/ci_table1_cohort_baseline.txt` and issue #233. Until then
the two baseline lines stay as they are.

**Do not** add the currently observed A5 string to the baseline. The baseline
is shrink-only by construction, and the present state is a stale local input,
not a reviewed condition worth freezing into the repository.
