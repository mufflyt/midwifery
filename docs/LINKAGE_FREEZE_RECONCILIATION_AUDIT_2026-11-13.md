# Linkage-freeze reconciliation audit, 2026-11-13

**Question.** `artifacts/amcb_npi_linkage_FROZEN.csv` on this machine hashes to
`dbcc76f4…` and carries 16,898 cohort members. Its tracked manifest describes
`9f224007…` with 16,775. Which is right, what explains the difference, and may
either be promoted?

**Answer.** The manifest is right and the file on disk is two re-freezes stale.
The reconciled freeze **cannot be rebuilt on this machine** — the inputs it was
built from no longer exist here — so nothing is promoted and the manifest is not
edited. The recovery route is the data vault, which this repo already implements
and which is **not provisioned on this machine**.

Scope: audit only. No cohort, manifest, freeze or published figure was changed.

---

## 1. The three freezes

| Freeze | sha256 | rows | cols | cohort members | on this machine |
|---|---|---:|---:|---:|---|
| 2026-08-10 | `dbcc76f420ac9be8…d3a2209b` | 22,309 | 54 | 16,898 | **yes**, in `artifacts/` |
| 2026-09-10 | `1a7bd6a8c8f1c089…bd0887da2` | 22,357 | 60 | 17,028 | no |
| 2026-10-22 (**manifest-current**) | `9f224007d99ac91d…184b8716` | 22,357 | 60 | 16,775 | no |

Sources: `artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json` (current),
`artifacts/amcb_npi_linkage_FROZEN_2026-10-22.csv.manifest.json` (the archived
2026-09-10 freeze — the date in that filename is when it was *superseded*, not
when it was built). Row, column and member counts for the on-disk file were
measured, not quoted.

`artifacts/amcb_npi_linkage_FROZEN_2026-08-08.csv` is present and **does** match
its own manifest (`b44bf2bc…`, 22,309 rows), so the archive mechanism works; it
is only the two later freezes that are missing.

## 2. Membership: the 123 is a net of two opposing movements

    16,898  (dbcc76f4, 2026-08-10, 22,309 rows, 54 cols)
      +130  A/B reconciliation on the 2026-09-02 scrape: roster 22,309 -> 22,357,
            2018-2026 NPPES candidates admitted. 5,960 rows newly matched,
            198 LOST their match (manifest: net +5,762 at match level).
    17,028  (1a7bd6a8, 2026-09-10, 22,357 rows, 60 cols)
      -253  class-4 (Levenshtein surname) matching retired from
            match_amcb_to_npi.R; evidence class 4 not reassigned.
    16,775  (9f224007, 2026-10-22, 22,357 rows, 60 cols)
    ------
      -123  net

**The cohorts are not nested**, in either direction. Step 1 adds 130 while
losing 198 matches; step 2 removes 253 while moving 162 ACTIVE people into
`unmatched` and 6 into `name_component/excluded`. A membership difference of 123
therefore describes no set of 123 people.

The 2026-10-22 manifest's ACTIVE-subset accounting was re-checked and
**conserves exactly** at 15,328 on both sides:

| tier (ACTIVE subset) | before | after | delta |
|---|---:|---:|---:|
| primary_midwifery | 12,192 | 12,170 | −22 |
| sensitivity_nursing | 889 | 821 | −68 |
| name_component/excluded | 95 | 101 | +6 |
| resolved_by_absence | 5 | 5 | 0 |
| contested quarantine | 40 | 38 | −2 |
| tied quarantine | 1,476 | 1,400 | −76 |
| unmatched | 631 | 793 | +162 |
| **total** | **15,328** | **15,328** | **0** |

The two reported cohort tiers lose 90 ACTIVE members. The manifest does not
report the ACTIVE `sensitivity_fuzzy` count, so the remaining −163 **cannot** be
split between lost ACTIVE fuzzy members and non-ACTIVE certificants without the
files themselves. That split is not inferred here.

**Record-level comparison is impossible.** It needs `9f224007` and `1a7bd6a8`,
and neither exists on any reachable machine (§4). Nothing in this report
attributes the 123 to named individuals.

## 3. Schema: a strict subset, not a divergence

The on-disk freeze has exactly **54 of the manifest's 60 columns and no extra
column**, which is consistent with an earlier vintage rather than a branch:

    n_mid_vetoed_c2   resolved_by_absence_c2   unmatched_after_middle_veto
    match_resolution  exact_first_last_multiple_candidates   match_status

The last three are created by `reconcile_linkage.R` itself, so the on-disk file
demonstrably never went through reconciliation.

## 4. Why the reconciled freeze cannot be rebuilt here

`reconcile_linkage.R` is fully parameterised (`RECONCILE_FULL`,
`RECONCILE_BASE`, `FROZEN_OUT`), so a rebuild could be written to an isolated
path without touching the existing freeze. Every **input** is missing:

1. **Both A/B arms are absent.** The manifest requires
   `amcb_npi_linkage_panel-midwifery-plus-nursing_years-2007-2026.csv`
   (`14c4271b…`) and `…_years-through-2017.csv` (`a165eb95…`). Neither exists
   anywhere on this machine; only 2007-**2025** arms do.
2. **The script refuses the stale arms, correctly.** Its own
   `stopifnot(nrow(full) == 22357)` rejects the 22,309-row
   `artifacts/amcb_npi_matched*.csv` files that *are* on disk.
3. **The AMCB scrape it needs does not exist here.** The manifest names a live
   AMCB directory scrape of **2026-09-02**. All 16 copies of `midwives.csv`
   across every worktree and the `Broken_Mac_Rescue` tree are **byte-identical**
   (`fe035788…`, 22,309 rows, 2026-08-14). `midwives.csv` was tracked in git
   before being ignored, and both historical blobs (`fe035788…` and
   `b409ed02…`, 2026-08-06) also carry 22,309 rows. The +48 rows the reconciled
   freeze rests on are not recoverable from any of them.
4. **The archive the manifest says it wrote is also gone** —
   `amcb_npi_linkage_FROZEN_2026-10-22.csv` (`1a7bd6a8…`) is absent.

Checked independently of filenames: 248 CSV files over 500 KB across the repo,
`midwifery_person_level_backup_20260814` and the `Broken_Mac_Rescue` tree were
counted, and **none has 22,357 rows**. Nothing carrying the reconciled roster is
on this machine under any name.

Re-scraping AMCB today would produce a **2026-11 roster**: a fourth cohort, not
a reproduction of `9f224007`. Per instruction, no hash was fabricated, the
manifest was not edited, and no replacement was built and labelled as the
reconciled freeze.

### The route that does exist

`R/lib/data_vault.R` implements exactly this recovery: `vault_linkage_freeze()`
returns the freeze whose sha256 the tracked manifest names, from `artifacts/` if
it is the right file and **from the vault otherwise**, re-hashing it
(`vault_find()`). `docs/DATA_VAULT.md` records this incident as the reason the
vault exists, naming `dbcc76f4…` as "the 2026-08-10 freeze" and the build that
"described 11,920 midwives instead of the registered 12,171".

**The vault is not provisioned on this machine**: no Dropbox install, no
`~/.dropbox/info.json`, no `~/Dropbox*` or CloudStorage path, `MIDWIFERY_VAULT`
unset, and no `midwifery-data` directory anywhere. The freeze most likely exists
in the vault, or on the machine that built it on 2026-10-22. Publishing it with
`vault_publish()` from that machine resolves this without any rebuild.

## 5. Downstream impact, from the repo's own discovery tool

`frozen_dependency_report()` (`R/frozen_dependency_graph.R`):

| | |
|---|---:|
| consumers of the frozen cohort | 98 |
| network-excluded (cannot rebuild offline) | 5 |
| rebuildable set | 91 |
| producers excluded (`freeze_cohort.R`, `reconcile_linkage.R`) | 2 |
| with statically resolved outputs | 48 |
| **with writes static analysis cannot resolve** | **50** |

`audit_frozen_consumer_classes.R` (reproduces its tracked output byte-identically):
85 consumers read both POPULATION and LINKAGE columns, 8 linkage-only, 4
population-only, 1 unclassified (`validate_training_institution_against_acme.R`,
which must be read by hand).

So a promotion would require rebuilding 91 scripts in dependency order, and for
**50 of them the outputs cannot be enumerated statically** — which is why no
promotion is recommended without the freeze in hand and
`rebuild_frozen_dependents.R` driving it.

## 6. Test status, and what each failure actually is

Run against the only freeze that exists here (`dbcc76f4`), in an isolated
worktree:

| Check | Result | Classification |
|---|---|---|
| A1, A2, A3, A3b | pass | — |
| **A4** | 8 rows carry NPPES geography with no NPI and no `class5_candidate_npi` | **environment mismatch** |
| **A5** | `table1_csv_n=12171 table1_md_n=12171 canonical_n=11920` | **environment mismatch** |
| **`ci_science_laws` L12** | stats catalog cannot build; `sum(active_unmatched_by_reason) != active_unmatched_n` | **environment mismatch** |
| `ci_skip_budget` | 5 tests skip on absent gitignored inputs | **not evaluable** in a bare worktree; green in `ci.yml` on `main` |

None is a scientific inconsistency, and none is a regression. Evidence:

- **A4.** All 8 rows are class-5 `surname_component_exact_first` /
  `ambiguous_unruled_out_component` rows that kept their candidate's NPPES
  geography but have an empty `class5_candidate_npi`. The 2026-09-10 manifest
  records the cause: readr's 1000-row type guess inferred that column as logical
  from an all-NA sample and "silently coerced **8** real NPI values to NA on
  read". Current `reconcile_linkage.R` reads with `guess_max = Inf`, so the
  defect is frozen into the stale artifact and cannot be reproduced by the code.
  The on-disk file holds 156 non-empty `class5_candidate_npi` values against 163
  in the current manifest.

  This one is not inference. `ci_artifact_contracts.R`'s own comment above
  `KNOWN_ORPHANS` records that the baseline was **lowered from 8 to 0 on
  2026-09-11** because "nobody had re-run it since `reconcile_linkage.R`'s
  `guess_max = Inf` fix (cc5a301, PR #182) regenerated
  `amcb_npi_linkage_FROZEN.csv` without the earlier type-guess corruption. The 8
  orphans this was tracking did not reappear against that corrected file." The
  gate is therefore reporting 8 orphans against a file from before that fix, and
  a corrected freeze has already been *observed* to give 0. It also states "156
  rows are in this state by design", which the measurement reproduces exactly.
- **A5.** 11,920 is the exact figure `docs/DATA_VAULT.md` records for this
  incident. The tracked Table 1 (12,171) was built from a correct freeze; the
  canonical cohort recomputed from the stale freeze gives 11,920.
- **L12.** `match_status` is one of the six columns the stale freeze lacks (§3),
  so the unmatched-by-reason breakdown is empty and cannot sum to its total.

### The wrong freeze is worse than no freeze

Measured directly, by hiding the file and running the gate again:

| `artifacts/amcb_npi_linkage_FROZEN.csv` | `ci_manuscript_numbers` |
|---|---|
| present (the stale `dbcc76f4`) | **FAIL** — stats catalog cannot build |
| absent (runner-equivalent) | **PASS** |

So this machine is **strictly worse off than a bare CI runner**. These are not
private-data checks that finally get to run here; they are checks that a wrong
input poisons, and that pass when the input is simply not there. `L12` is
registered `public` precisely because its inputs are tracked — it passes on
every runner — and it fails here only because a superseded freeze is present
for it to read.

Two consequences:

- The fastest way to make this machine's gates honest is to **move the stale
  freeze aside**, not to keep it for the sake of having something. Until
  `9f224007` arrives, `artifacts/amcb_npi_linkage_FROZEN.csv` is a liability.
- This is the strongest argument for the §7.4 backlog. A consumer that calls
  `verify_linkage_freeze()` **stops**; one of the 91 that does not **computes a
  wrong answer and reports success**. The gates caught it here only because
  three of them happen to assert something a stale file cannot satisfy.

### The finding that matters most

`ci.yml` states that the runner "never has access to the gitignored,
person-level `amcb_npi_linkage_FROZEN.csv`", so these steps "report SKIP on
every CI run" and the exit code is real "on any machine that DOES have the
private data — which is where the actual enforcement happens."

So A4, A5 and the freeze-dependent science laws are **skipped in CI and failing
on the one machine that runs them**, which has the wrong file. These assertions
are currently enforced **nowhere**. A green CI tick is not evidence about them,
and "red locally only" is not the reassurance it sounds like.

## 7. Changes made on this branch

Audit and guardrails only; no cohort, freeze, manifest or figure touched.

1. **Table 1 keeps the privilege-derived hospital block**, and its header note
   now states for the reader that a CCN affiliation is a Medicare facility
   privilege — "not a practice location and not a measure of clinical activity",
   not comparable with the address-derived geography rows.
   `tests/test_manuscript_tables.R` asserts the caveat is present, so it cannot
   be dropped silently.
2. **The CMS NDH 153-address record is preserved** exactly as CMS published it.
   It cannot distort any geographic analysis: NPI 1417904962 is in neither
   `amcb_npi_linkage_FROZEN.csv` nor `cms_ndh_bulk_cohort.csv`, and the only
   readers of either NDH artifact are their producer and the test. A sensitivity
   analysis would have nothing to perturb, so the **bound is recorded** instead
   (153 of 64,941 national addresses = 0.236% of address mass; excluding it moves
   the maximum from 153 to 60; in the cohort file the row is absent, maximum 52
   across 16,361 CNMs, none above 60) and a tripwire now fails if any script
   starts reading those artifacts, so the defect is re-evaluated against that use.
3. **Freeze pinning is now declared and per consumer, not ambient.**
   `ALLOW_FREEZE_SHA256` used to accept any hash with no record. It now requires
   the hash to be declared in `artifacts/freeze_pins.tsv` **for the script
   reading it**, with a scope and a stated purpose, and announces the pin on
   every run; pinning in code still needs no declaration, because the call site
   is the record.

   Binding a pin to one consumer matters more than the declaration itself. Keyed
   on the hash alone, declaring the 2026-08-10 freeze for one dated experiment
   would also unlock it for every other consumer — `build_table1_midwives.R`
   included — which is the permissiveness this was meant to remove. Verified:
   with `ALLOW_FREEZE_SHA256=dbcc76f4…` set,
   `experiment_trilliant_identity_linkage.R` is accepted (with its purpose
   printed) while `build_table1_midwives.R` and
   `extract_open_payments_cohort_by_year.R` are both refused.

   The one legitimate pin is declared: `dbcc76f4…` for
   `experiment_trilliant_identity_linkage.R`, whose appendix §9 already states
   the limitation. No pin may claim `production` scope — production is the
   manifest's freeze.
4. **Verification coverage is now ratcheted.** 91 of 98 consumers read the
   freeze without verifying it; `tests/frozen_verify_baseline.txt` records them
   and `tests/test_frozen_dependency.R` T14–T17 fails on any **new** unverified
   consumer and on any baseline line that could be deleted. Verified with a
   positive control.

5. **The freeze manifest is now checked by CI, which could never see the
   freeze itself.** `ci_data_regression_guard.R` checked
   `linkage_manifest.json` (D1, D2) but nothing checked the manifest that
   defines the cohort. Two new PUBLIC sections close that, both from tracked
   files only, so they run on a runner where A4/A5 cannot:

   - **D11** pins the manifest's `membership_rule` to
     `COHORT_MEMBERSHIP_TIERS`, the code that actually decides
     `cohort_member`. Nothing held the scientific statement and its
     implementation together, so either could be edited alone.
   - **D12** checks the freeze lineage across all three tracked manifests:
     64-hex hashes, `cohort_members <= artifact_rows`, hashes distinct, the
     *current* manifest's hash not also an archived one (which would mean the
     freeze called current is a superseded vintage), and the decision text's
     "archived as sha256 …" claim resolving to a real archived manifest — the
     cross-check this audit first did by hand.

   Four positive controls confirm they fire: a dropped tier, a current manifest
   pointed at an archived hash, an unresolvable archive claim, and members
   exceeding rows.

## 8. Recommended decision

**Do not promote anything.** Specifically:

- **Do not** promote `dbcc76f4…`. It is the documented cause of the 11,920
  figure, it lacks six columns the current schema requires, and it carries the
  readr defect A4 detects.
- **Do not** edit the manifest to match it. The manifest is the only surviving
  description of the reconciled cohort.
- **Do not** re-scrape AMCB and call the result a reconciliation. That produces
  a fourth cohort and would silently replace a documented decision.
- **Do** provision the data vault and `vault_publish()` the `9f224007…` freeze
  from the machine that built it on 2026-10-22. That is the designed path, needs
  no rebuild, and is verified by hash on arrival.
- **Meanwhile**, consider moving `artifacts/amcb_npi_linkage_FROZEN.csv` aside
  on this machine. A measurement above shows the gates do better with no freeze
  than with the wrong one, and keeping it invites exactly the silent substitution
  `docs/DATA_VAULT.md` was written about. The Trilliant identity experiment is
  the only sanctioned reader, and it now names the file by hash through
  `freeze_pins.tsv`, so it does not need the file under the canonical name.
- **Then** re-run A4, A5 and `ci_science_laws` against it. A4 is expected to
  return to 0 orphans, because that was observed on 2026-09-11 against the
  post-fix freeze. A5 and L12 are expected to pass because the counts and the
  missing `match_status` column are both properties of the stale file. If any
  does not pass, that failure is a genuine finding rather than this environment
  mismatch — which is the point of fixing the environment first.
- Until then, treat Figure 4 and any count resting on 16,898 as built on a
  superseded cohort, as `docs/ci-a4-a5-local-failures.md` already records.

### Stale prose found, left unchanged (out of scope, worth a follow-up)

- `audit_frozen_consumer_classes.R` header: describes "ONE 54-column file" and
  "refreeze_option2_20260810T192207, 16,898 members" — the 2026-08-10 freeze.
- `.github/workflows/ci.yml:6`: "a 22,309-row FROZEN crosswalk" — now 22,357.
- `docs/TECHNICAL_APPENDIX_TRILLIANT_IDENTITY_EXPERIMENT.md` (header and §9):
  calls `1a7bd6a8…` "the current freeze"; it was superseded on 2026-10-22.
