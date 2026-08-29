# Known debt

Findings that are real, measured, and deliberately not fixed yet. Each entry
states the measurement, the decision it needs, and who owns it.

This file exists because the alternative is prose in a session transcript, and
that evaporates. It follows the pattern this repository already uses for
`tests/ci_leak_baseline.txt` and `tests/ci_nightly_exceptions.txt`: named debt
with a stated reason, policed by a gate so it cannot quietly rot.

`tests/ci_debt_check.R` enforces the format. Every open entry needs an owner
and a `raised` date; a closed entry needs a `closed` date and a resolution.

---

## D1 — Non-atomic artifact writes

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** `atomic_write()` / `atomic_saveRDS()` / `atomic_write_csv()` in `R/lib/resume_state.R`, wired into both scrapers; asserted by A1-A8 in `tests/test_recovery_resume_equivalence.R`

Checkpoints were `saveRDS()` followed by `write_csv()`, both straight to their
final paths. Killed between the two, the checkpoint outran its output; killed
during either, a truncated file replaced a complete one. The output is 3.4 MB
and is rewritten wholly every checkpoint, so the window was not small.

Writes now go to a temporary file **in the same directory** and are renamed
into place. Same directory matters: across filesystems `rename` degrades to
copy-then-delete, which is the non-atomic behaviour being removed.

A validator runs before the rename, so a write that completed but produced
nonsense does not replace a good file. An empty CSV is refused outright --
that is the shape of the 2026-08-09 truncation, a complete file overwritten
with almost nothing.

A2/A3 assert the case that motivated this: a writer that dies mid-write leaves
the previous file intact, byte for byte.

**Follow-up now unblocked:** `CKPT_EVERY` was set to 10 rather than 5 because
more frequent checkpoints meant more torn-write exposure. That trade no longer
exists, so 5 is reconsiderable on livelock grounds alone.

---

## D2 — Stage-2 resolver ordering coverage is external-private

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** added `tests/test_isochrones_stage2_rank_one_to_one.R`, registered as an `external-private` nightly exception, which runs the canonical upstream `test-rank-one-to-one-non-greedy.R` whenever a private `mufflyt/isochrones` checkout is available
- **belongs to:** `mufflyt/isochrones`, `R/npi_resolution.R`
- **tracked at:** https://github.com/mufflyt/isochrones/issues/546

`rank_one_to_one()` enforces one-NPI-one-person. That allocation step is the
single place in this pipeline where an ordering bug is genuinely likely, and it
lives in a repository public midwifery CI cannot clone: isochrones is private
and midwifery is public.

Stage 1 is fully attacked: `tests/test_amcb_resolver_permutation.R` runs 300
randomised orderings plus six adversarial ones over a hostile fixture. That
harness is directly portable -- hostile fixture, N orderings, fingerprint
comparison, negative control.

**Resolved here:** the public runner still cannot clone the private repository,
but this repo now carries a concrete sentinel test and the nightly exception
registry accounts for it. The remaining work belongs upstream: make the
isochrones-side test blocking in isochrones CI.

---

## D3 — Unrecognised taxonomy fails OPEN

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** `amcb_linkage_tier()` now normalises known taxonomy labels and assigns dirty/unknown labels to `sensitivity_unknown_taxonomy`, which is cohort-eligible but no longer published as `primary_midwifery`; production now calls the helper instead of carrying an inline tier copy
- **found by:** `tests/test_metamorphic_invariance.R` (N1/N2)

Before the fix, `amcb_linkage_tier()` tested `npi_tax_class == "nursing"` and
fell through to `primary_midwifery` on anything else. Measured:

| value | tier |
|---|---|
| `nursing` | `sensitivity_nursing` |
| `NURSING` | `primary_midwifery` |
| `" nursing "` | `primary_midwifery` |
| `garbage` | `primary_midwifery` |
| `""` | `primary_midwifery` |

So a value the resolver did not understand was promoted to the **strongest**
tier. Dirty upstream data made a match look stronger, not weaker, which inverted
the principle that missing information must never increase certainty.

Cohort membership stays unchanged because the new unknown-taxonomy tier is still
eligible. What changes is the published claim about HOW someone was identified:
unknown taxonomy is now visible as sensitivity evidence, and N2/N3 in
`tests/test_metamorphic_invariance.R` pin that behaviour.

**Resolved policy:** known labels are normalised (`NURSING` and `" nursing "`
are nursing); unknown labels become `sensitivity_unknown_taxonomy`. This keeps
identity evidence cohort-eligible while making the dirty taxonomy visible.

---

## D4 — Artifacts built before the `is_enrolled_dac` fix

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** all three affected artifacts regenerated; Table 1 verified never to have been affected

**Table 1 was never wrong.** It derives Medicare enrollment from
`artifacts/dac_cnm_education.csv`, produced by `extract_dac_cnm_education.R`,
which reads `DAC_NationalDownloadableFile_2026-06.csv` -- the correct register
at the correct vintage. Its "7,050 not enrolled" row never touched the buggy
flag. Checking that first turned a feared publication-level correction into a
bounded one.

Three untracked person-level artifacts DID carry it, and are regenerated:

| artifact | enrolled before | after |
|---|---:|---:|
| `cohort_midwife_hospital_matches.csv` | 1,958 | **5,420** |
| `cohort_midwife_hospital_affiliations_multitier.csv` | 1,958 | **5,420** |
| `cohort_midwife_hospital_rigorous_attributions.csv` | 1,958 | **5,420** |

**3,462 midwives corrected** in each. All four producing scripts now pass the
register explicitly through `dac_national_npis`.

**A blocker had to be cleared first.** Regeneration failed on a 404: CMS
rotates the resource id in its download URL on every refresh, and the pinned
`_1782750576` had been superseded by `_1785521778` when the dataset was
refreshed on 2026-07-31. That dead URL is also why
`tests/test_match_npi_to_hospitals.R` sits in the nightly exception registry.
`resolve_facility_affiliation_url()` now resolves it from the provider-data
catalog with the last known id as a fallback, so it degrades to "try the old
URL" rather than to nothing.

---

---:|
| in the national register (truly enrolled) | 5,931 |
| in the facility-affiliation file (what the flag used) | 1,665 |
| **enrolled with NO facility affiliation — were FALSE** | **4,266** |
| affiliation but absent from the register | 0 |

A **3.56x** understatement of Medicare enrollment. The handoff estimated 3,319
affected; the measured figure is 4,266.

**Corrected 2026-08-16.** The first measurement used a 2024-05 copy of the
register from an external volume and reported 3,912 enrolled, 2,817
mislabelled, and 570 affiliated NPIs with no register entry, which was raised
as an unexplained anomaly. It was not one: against the correct 2026-06 file the
570 is **zero**, and those providers had simply enrolled between the two
vintages. The stale file understated the understatement. The subset law is now
asserted (C1/C2) so a stale register announces itself instead of looking like a
data anomaly.

**Decision needed:** which published outputs used this flag, and whether they
are regenerated or withdrawn. Regenerating a Table 1 row changes a reported
number, which is a scientific decision rather than a code one.

---

## D5 — Two Open Payments employer-linkage implementations disagree 83.6%

- **status:** open
- **owner:** tyler
- **raised:** 2026-08-16
- **source:** `docs/OPEN_PAYMENTS_LINKAGE_COMPARISON.md`

Two independent implementations build employer/facility linkage from the same
Open Payments source. Where **both** name an organization for the same midwife
-- 450 overlapping midwives -- they agree on the Type-2 NPI for **74, or
16.4%**.

The comparison document's own conclusion: *"Two implementations of the same
concept, from the same source, disagreeing 83.6% of the time. At least one is
substantially wrong. Neither should be declared canonical on coverage alone
until this is explained."*

Nothing has been promoted or deleted, which is right. But the finding lived
only in a document no gate reads, and this register exists precisely so that a
measured disagreement of that size cannot quietly become someone's default.

This is the largest unexplained quantity currently open. Every other entry here
concerns a mechanism whose behaviour is known; this one concerns a number
nobody can yet defend.

**Decision needed:** diagnose the disagreement before either implementation is
used for anything published. The comparison document already lays out inputs,
keys, normalization and rules side by side, which is where a diagnosis starts.

## D6 — Care Compare and PECOS agree on 43% of organization relationships

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** interpretation corrected and recorded as a ruling in `docs/DECISIONS_CONTRACT.md`; arms kept separate behind `classify_affiliation_status()`

**The original framing was wrong.** D6 read the 43.4% agreement as "current
versus cumulative", with PECOS as an ever-affiliated history. It is not: the
PPEF population is restricted to enrollments **currently approved** as of the
data version, so PPEF was never cumulative.

The correct reading is narrower and more useful:

> A PPEF reassignment is a Medicare reassignment relationship **on file in
> PECOS at the snapshot date** -- neither employment nor an all-time history.

CMS instructs practitioners to update PECOS when they end a reassignment or end
employment, and warns that failing to withdraw leaves billing relationships on
file. So an on-file reassignment can **lag** the real relationship without
being a historical record of it.

**Why the 43% is preserved rather than reconciled.** At least four things could
produce it, and the data cannot yet separate them:

1. PECOS carries genuine concurrent billing affiliations Care Compare omits;
2. some PECOS relationships are administratively stale;
3. Care Compare is incomplete for CNM/CMs;
4. the two products operationalise "group affiliation" differently.

Resolving them by source precedence would manufacture certainty. So each arm is
retained separately and `R/lib/organization_affiliation_status.R` derives a
status from their combination:

| status | pairs | % |
|---|---:|---:|
| `medicare_reassignment_only` | 9,174 | 61.3 |
| `probable_current` | 4,558 | 30.4 |
| `high_confidence_current` | 1,240 | 8.3 |

5,329 midwives have at least one current affiliation. **4,463 have only
`medicare_reassignment_only`** -- a reassignment on file with no Care Compare
corroboration. Under the original framing those would have been labelled
historical. They are not: that status asserts a relationship is on file and
says current practice status is uncertain, which is all the data supports.

**The endpoint changed too.** Not "who employs this CNM/CM?" but "what practice
organizations is this CNM/CM affiliated with, and how strong is the evidence
that each affiliation is current?"

**Longitudinal work now has a real basis.** The CMS Revalidation Clinic Group
Practice Reassignment dataset publishes monthly and CMS keeps prior months at
distinct URLs: 39 releases from 2021-12 to 2026-08, carrying group PAC id,
revalidation due dates for both sides, and an individual employer-association
count. `archive_revalidation_reassignment.R` downloads each, keeps the raw
file, and loads it into a DuckDB warehouse. That is an interval-censored
affiliation history available now, rather than one accumulated over a year --
subject to the same rule that first and last appearance are bounds, not dates.

---

---:|
| share at least one org PAC id | 1,227 (**43.4%**) |
| disjoint PAC id sets | 1,598 |
| Care Compare only | 2,506 midwives |
| PECOS only | 4,456 midwives |

Matching on organization NAME instead gives 43.1%, so the disagreement is
real and not a name-normalisation artefact.

**This is probably not the same kind of problem as D5.** There, two
implementations of ONE concept disagreed 83.6% of the time and at least one had
to be wrong. Here the two arms may be measuring different relations:

- Care Compare is a curated directory of where CMS lists a clinician
  **practising** -- mean 1.09 organizations per midwife, max 6.
- PECOS reassignment records **every entity receiving reassigned benefits**,
  and a reassignment is not obliged to be terminated promptly -- mean 1.43,
  max 16.

The clearest disagreement in the data has Care Compare listing one
organization and PECOS listing seven, none shared. That pattern is what a
current-directory versus cumulative-billing distinction would look like.

**Decision needed:** establish whether PECOS reassignments persist after a
relationship ends. If they do, 43% is the expected agreement between a current
and a cumulative measure, and the two arms should be combined as
`current_affiliation` versus `ever_affiliated` rather than reconciled. If they
do not, then one arm is wrong and this becomes a D5-shaped problem.

The PPEF reassignment file carries no date column, so this cannot be settled
from the file alone.

---

## Closed

## D0 — Provenance determinism of the recorded name variant

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-16
- **closed:** 2026-08-16
- **resolution:** deterministic tiebreak added in `amcb_per_npi()`

`which.min()` returns the first minimum, so when a person had two candidate
rows for one NPI tied at the same evidence class, the recorded spelling was
whichever arrived first. Measured at 231 of 300 candidate orderings; accepted
identity never moved.

Checked before deciding: the column appears in **no tracked artifact**, but it
does appear in `amcb_crosswalk_review_sample_*.csv` and
`amcb_class5_review_census.csv` -- files a human reads when judging whether a
weak match is real. Two reviewers running the pipeline on different days should
not be shown different evidence for the same person, so this was cosmetic in
the sense that identity was safe and NOT cosmetic in the sense that it fed a
human decision.

`amcb_per_npi()` now sorts before taking the first row, making the survivor a
property of the data rather than of row order. Variant instability: 231/300 to
0/300.

---

## D7 — L5 cannot run on a clean checkout, and the coverage gate says so

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-25
- **closed:** 2026-08-29
- **resolution:** L5 reclassified `private-ok` in `tests/science_law_registry.tsv` (commit `0e0c89c`), so the skip is expected rather than a failure. This is route 3 of the three below, using the existing label instead of adding a state. The enforcement cost is carried forward as **D9**.
- **source:** `tests/science_law_registry.tsv`, `.gitignore:145`

L5 (*every routed provider is in the union*) needs two inputs. One,
`artifacts/osmde_validation_table.csv`, is tracked. The other,
`artifacts/maps/midwifery_isochrone_union_30min.rds`, is **gitignored** --
`.gitignore:145` excludes `artifacts/maps/` wholesale.

L5 is registered `public`, and the registry defines that as *"must run on any
runner; a skip is a FAILURE."* So on any checkout holding only tracked files --
which is every GitHub runner -- L5 skips and `tests/ci_law_coverage.R` fails
with one unexpected skip. Measured in an isolated worktree at `origin/main`:

    Laws exercised:              9/10
    Unexpected skips:            1
    FAIL 1 law(s) were not exercised: L5 (public) -- no subjects

**This was masked by the way it was verified, not by the gate.** Every
`10/10, 0 unexpected skips` reported while the law suite was being built --
including in PR #88 -- was produced in a working tree that happens to hold that
untracked `.rds`. The README already warns about exactly this: *"Passing in
your working tree proves nothing, because your working tree has the data."* The
coverage gate was correct throughout; the environment it was run in was not.

The gate is doing its job here. A law nobody can evaluate is indistinguishable,
in a green build, from a law that passed, and refusing to run is the honest
outcome.

**Decision needed:** three routes, and they differ in what they cost.

1. **Have the nightly build or restore the surface** before the science job.
   Keeps L5 at full strength on every runner. Costs runtime, and the surface is
   derived from the private isochrone library.
2. **Track the artifact.** Simple, but `artifacts/maps/` is excluded for size,
   and the leak baseline may only shrink.
3. **Add a registry state** distinguishing *pipeline-derived, absent from git*
   from *person-level private*. Honest about why the skip happens and keeps it
   counted rather than swallowed -- but it adds a fourth state to a three-state
   contract, and every state that permits a skip is a state a law can hide in.

Route 3 is the smallest change and the largest concession. Nothing should be
re-registered `private-ok` in the meantime: that label would assert the input is
person-level, which it is not.

---

## D8 — The coverage gate cannot tell a crashed law from a silent one

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-29
- **closed:** 2026-08-29
- **resolution:** `run_file()` now returns `attr(out, "status")` and `gate_crashed()` reports a non-zero exit *with no `[LAW]` markers* as CRASHED, with the last lines of output. A non-zero exit alone is NOT a crash — a gate that evaluates its law and finds a violation also exits non-zero, and calling that a crash would turn every genuine law failure into a false diagnosis. Three controls in `tests/test_law_coverage_detect.R`.
- **source:** `tests/ci_law_coverage.R` `run_file()`, commit `0e0c89c`

`run_file()` executes each gate with `system2(..., stdout = TRUE, stderr = TRUE)`
and keeps only the text. **The exit status is never read.** A gate that ran
cleanly and emitted no markers, and a gate that died on its first line, are
therefore indistinguishable: both arrive as text containing no `[LAW] ...
EXERCISED`, and both are scored "no subjects".

This is not theoretical. Every nightly from 2026-08-26 reported L6-L10 as having
no subjects. All five had in fact **crashed instantly** with "no package called
X", because their gates need dplyr/readr/stringr/readxl/sf/DBI/duckdb and the
science job installs no packages. The build failed -- correctly, on the gap --
but named the wrong cause, and the real error was sitting in the captured text
that nothing looked at.

The gate was designed around the principle that a law which does not run is
indistinguishable from one that passed. It turns out there is a third state it
also cannot distinguish, and that one is diagnosable for free: a non-zero exit
status is already in hand and is being discarded.

**Decision needed:** none, really -- this is a small fix rather than a policy
question. Capture `attr(out, "status")`, and report a non-zero exit as a crash
with the last lines of output, distinct from both "exercised" and "skipped". The
reason it is filed rather than done is that it changes the meaning of a gate's
output during a week when three other things changed it, and it deserves its own
mutation in `tests/test_law_coverage_detect.R` proving a crashed gate is
reported as crashed.

---

## D9 — L5 is registered `private-ok`, but its input is not private

- **status:** closed
- **owner:** tyler
- **raised:** 2026-08-29
- **closed:** 2026-08-29
- **resolution:** **L5 is enforced on every runner and is registered `public` again.** The label change described below was the first, partial answer; it made the gap honest without closing it. The gap turned out to be unnecessary: L5 reads no geometry. It compares `n_origins_dissolved` against the routed count, and L4 compares two `area_km2` values — every quantity either law needs is a scalar sitting beside 30 MB of polygons. Those scalars are now written to `artifacts/isochrone_union_manifest.csv` (327 bytes, tracked) by `build_midwifery_isochrone_map.R` at the moment the surfaces are written, and the laws read that. Because a tracked summary of an untracked artifact can drift, the gate re-derives every row wherever the surface *is* present and fails on disagreement — checked against the real thing on a developer machine, used on a runner. `derived-ok` remains in the vocabulary for a genuine case; no law currently uses it. The `Laws exercised` count was corrected at the same time: it had been adding the skips back in, so the summary read `10/10` while nine laws had run — the shape this entry exists to prevent, in the line most likely to be read on its own. Rebuilding the surface in CI was ruled out rather than chosen: it is 31 MB and built by `build_midwifery_isochrone_map.R` from the private `~/isochrones` checkout, which no runner has. **The enforcement gap is unchanged — it is now labelled honestly and counted in the open, instead of being absorbed into a category that sounds unavoidable.** Six controls in `tests/test_law_coverage_detect.R`, including one proving `derived-ok` cannot launder a `public` law's skip.
- **source:** `tests/science_law_registry.tsv`, closing of **D7**

D7 is closed and this is what closing it cost.

L5 (*every routed provider is in the union*) is now registered `private-ok`, a
label the registry defines as *"may skip when person-level data is absent, and
that skip is EXPECTED, not unexpected."* L5's missing input is
`artifacts/maps/midwifery_isochrone_union_30min.rds` -- a derived isochrone
surface excluded by `.gitignore:145` for **size**. It is not person-level data.

Two consequences, and the first is the one that matters:

1. **L5 is now unevaluated on every runner and nothing complains.** Before, the
   nightly went red; now the skip is counted as expected and the build is green.
   The law still holds locally, where the surface exists, but the enforcement
   that CI provides is gone. "A law that does not run is indistinguishable from
   one that passed" is the sentence the coverage gate was written around, and
   this is a sanctioned instance of it.
2. **The registry now asserts something untrue** about why L5 skips. The privacy
   column is the machine-readable statement of *why* a law may be absent, and a
   reader who trusts it will conclude the isochrone surface is person-level.

Nothing here argues the reclassification was wrong as a stopgap: a permanently
red nightly gets muted, and a muted nightly checks nothing at all. The point is
that the cost was paid quietly and should not stay quiet.

**Decision needed:** either restore enforcement -- have the nightly build or
restore the surface before the science job, which keeps L5 at full strength -- or
add a registry state that says what is actually true (*pipeline-derived, absent
from version control*), so the skip stays counted and honestly labelled. The
second is a fourth state in a three-state contract, which is a real cost;
every state that permits a skip is a state a law can hide in.
