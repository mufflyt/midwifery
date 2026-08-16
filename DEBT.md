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
