# Handoff: the worksite rebase conflict, audited but not resolved

For whoever resumes `git rebase origin/main` on `main` (local commits
`7b3f4ce`, `29eb09b` as of this writing — neither pushed). Written here
because the owner explicitly declined to let the conflict be resolved by
picking whichever side's numbers looked newer or more complete, and asked for
an evidence-based audit first. This is that audit's record.

## The conflict

`git pull --rebase` on `main` hits three conflicts replaying local's
(unpushed) `7b3f4ce` onto `origin/main`:

1. `artifacts/midwife_work_setting_summary.csv` + its `.provenance.json` —
   **add/add**, same frozen input (`1a7bd6a8…`, same 2026-06-25 Trilliant
   snapshot), different computed numbers. See below.
2. `build_table1_midwives.R` — **not actually contradictory.** `origin/main`
   added CMS-DAC hospital-affiliation/Medicare-Part-D/HPSA Table 1 blocks;
   local added Trilliant-worksite/ACOG-district/age blocks. Keep both.
3. `docs/figures/cohort_exclusion_flow_evidence_tiers.csv.provenance.json` —
   trivial: only `written_utc` and `code_sha256` differ (same input, same
   data content auto-merged cleanly); take whichever side wins the other
   two conflicts.

## Finding 1: `origin/main`'s published Table 1 is a known-broken stale build, not newer truth

`origin/main`'s own `build_table1_midwives.R` header documents an incident
(~2026-09-11, PR #241): the script ran on a machine missing enrichment
inputs and published Sex 100% "not recorded" and ACOG district 99.7% "not
mappable" to `docs/table1_midwives.md`. A guard was added afterward
(`ALLOW_PARTIAL_TABLE1`, ships in that same PR) so this can't happen again —
but the **already-published file was never regenerated**. As of `origin/main`
tip, `docs/table1_midwives.md` still shows Sex "not recorded" for all 12,171
and ACOG "not mappable" for 12,131 of 12,171. Local's `7b3f4ce` version is
complete and correct (99.5% Female, full ACOG breakdown, age, worksite
blocks). **Do not treat `origin/main`'s checked-in Table 1 files as current**
— they predate the guard and have not been rebuilt since.

Separately: `~/isochrones-main` (the `ISOCHRONES_HOME` default the ACOG
mapping needs) doesn't exist on this machine by that name, but
`~/isochrones` does and has the same `R/acog_districts.R` — set
`ISOCHRONES_HOME=/Users/tmuffly/isochrones` rather than treating ACOG mapping
as missing data.

## Finding 2: the worksite numbers — root-caused, not fully reproducible yet

`blended_practice()` and `topology_by_midwife()` in `R/lib/work_site_topology.R`
are **byte-identical** between local and `origin/main` — not the source of
the disagreement. (They are now covered by 20 adversarial tests —
`tests/test_work_site_topology_saboteurs.R` — specifically targeting the
scenarios the owner asked about: shared hospital campuses, employer-only
rows, multiple records at one address, and affiliations with no resolved
coordinates. All 20 pass against the current implementation.)

The divergence is upstream, in what feeds those functions:

| hospital+birth-center evidence | strict | broad-only |
|---|---:|---:|
| local `7b3f4ce` (committed) | 241 | 34 |
| `origin/main` (committed) | 156 | 63 |
| **this session's rerun** (CABC + org-affiliation regenerated, HPT bundle still absent) | **203** | **76** |

Three different numbers from nominally the same frozen input. Causes found,
in order of confirmed impact:

1. **Local's committed build ran without two source files.** Its own
   committed provenance JSON for `midwife_work_setting_summary.csv` lists
   only 4 inputs — `cabc_matched_midwives_final.csv` and
   `organization_affiliation_resolved.csv` are missing from the list,
   because local's script silently drops nonexistent files
   (`INPUTS <- INPUTS[file.exists(INPUTS)]`) rather than erroring.
   `origin/main` removed that silent fallback (now hard-requires both files)
   — a real safety improvement worth keeping.
2. **This session regenerated both missing files from live/primary sources**
   (see "What was regenerated" below) and reran `build_trilliant_work_sites.R`
   locally: strict/broad moved from 241/34 to 203/76. This confirms cause 1
   was real, but the result still doesn't match `origin/main`'s 156/63.
3. **The remaining gap: the external hospital CCN/price-transparency
   reference bundle is absent on this machine.**
   `/Volumes/MufflySamsung/hpt_prices/` has only `trilliant/` and
   `direct_downloads/` — `reference/cms_enrollments/`,
   `reference/npi_ccn_crosswalk.csv`, `reference/hospital_universe.csv` and
   `crosswalk/facility_ccn.parquet` are all missing. Local's script still has
   a fallback for this (degraded hospital reference, **empty** NPI→CCN
   crosswalk) that `origin/main` removed (hard-requires the bundle). This
   session's rerun used that fallback — confirmed by the script's own
   printed `with_price_file = 0` — so its 203/76 is **still not a verified
   match for `origin/main`'s number**, only an improvement on local's.
4. Local separately adds one real, non-conflicting feature `origin/main`
   lacks: excluding ~40 overseas/military/territory addresses from physical-
   worksite classification (consistent with how Table 1 already excludes the
   same ~40 people from ACOG district). Minor contributor at most.

**To finish this**: locate or restore the HPT reference bundle (ask whether
it exists on another machine/backup — it was not searched for beyond this
machine), then rerun `build_trilliant_work_sites.R` with `origin/main`'s
stricter (no-fallback) version of the script. Only then compare against
156/63. Until that bundle is in hand, no number here — committed or
rerun — should be published as final.

## What was regenerated this session (not committed; gitignored by design)

- **`artifacts/organization_affiliation_resolved.csv`** — ran
  `build_organization_affiliation_resolver.R` directly; all 6 evidence arms
  present (pecos_reassignment, care_compare_group, nppes_org_colocation,
  facility_affiliation, hospital_affiliation, birth_center_registry), no
  external dependency needed. Person-level, gitignored per the script's own
  design (same as before).
- **`artifacts/cabc_matched_midwives_final.csv`** — `extract_all_cabc_birth_centers.py`
  requires a browser-rendered snapshot of
  `https://birthcenteraccreditation.org/find-accredited-birth-centers/`
  (listings render client-side). Captured live via browser automation on
  2026-10-19: read the name and address text for all 109 currently-listed
  centers directly out of the rendered DOM, re-wrapped in the minimal markup
  the parser's regex expects, saved to `data/cabc_directory_snapshot.html`
  (gitignored by the repo's blanket `*.html` rule — not committed, matching
  how the script's header already described this file as "not in the repo").
  Ran the unmodified parser against it: **220 midwives matched across 66
  centers** (109 centers now listed total; historical tracked figure was 221
  midwives / 111 centers — a real, expected roster change, not a bug, per
  the script's own comment that re-parsing a fresh capture won't reproduce
  old counts byte for byte).

Both are reproducible by anyone with this machine's artifacts: rerun
`build_organization_affiliation_resolver.R` directly, and for CABC, either
re-capture a fresh snapshot the same way or ask whoever holds an older
snapshot for it.

## What is NOT resolved

- The HPT reference-bundle gap (Finding 2, point 3) — unresolved.
- The rebase itself — not attempted again; `git rebase --abort` was run after
  the first conflict, `main` is clean, nothing pushed.
- Whether `origin/main`'s 156/63 is itself fully correct (i.e., whether its
  generating run had a complete, correct HPT bundle) — not verified, only
  assumed from its provenance JSON listing all 5 inputs. Not independently
  re-derived.
