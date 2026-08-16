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

- **status:** open
- **owner:** tyler
- **raised:** 2026-08-16
- **found by:** `tests/test_recovery_resume_equivalence.R`, while choosing `CKPT_EVERY`

`scrape_healthgrades_midwives.R` and `enrich_healthgrades_profiles.R` checkpoint
with a bare `saveRDS()` followed by a bare `write_csv()`. Neither writes to a
temporary file and renames, so:

- a kill BETWEEN the two lines leaves a checkpoint newer than its output;
- a kill DURING `write_csv()` leaves a torn CSV where a complete one was.

The output is 3.4 MB and is rewritten **wholly** on every checkpoint, so the
window is not small. This is the reason `CKPT_EVERY` was set to 10 rather than
5: more frequent checkpoints reduce livelock exposure but increase torn-write
exposure, and that trade only tips further once the write is atomic.

**Decision needed:** make artifact writes atomic (temp file, validate, rename),
then reconsider `CKPT_EVERY`. This is item 30 of the adversarial programme.

---

## D2 — Stage-2 resolver ordering is untested

- **status:** open
- **owner:** tyler
- **raised:** 2026-08-16
- **belongs to:** `mufflyt/isochrones`, `R/npi_resolution.R`
- **tracked at:** https://github.com/mufflyt/isochrones/issues/546

`rank_one_to_one()` enforces one-NPI-one-person. It is a greedy bijection, so
it is order-sensitive **by construction** -- the single place in this pipeline
where an ordering bug is genuinely likely -- and it is the one place midwifery
CI cannot reach, because isochrones is private and midwifery is public.

Stage 1 is fully attacked: `tests/test_amcb_resolver_permutation.R` runs 300
randomised orderings plus six adversarial ones over a hostile fixture. That
harness is directly portable -- hostile fixture, N orderings, fingerprint
comparison, negative control.

**Decision needed:** none here. Port the harness into isochrones CI. Weakening
midwifery CI to reach a private repository would be the wrong fix.

---

## D3 — Unrecognised taxonomy fails OPEN

- **status:** open
- **owner:** tyler
- **raised:** 2026-08-16
- **found by:** `tests/test_metamorphic_invariance.R` (N1/N2)

`amcb_linkage_tier()` tests `npi_tax_class == "nursing"` and falls through to
`primary_midwifery` on anything else. Measured:

| value | tier |
|---|---|
| `nursing` | `sensitivity_nursing` |
| `NURSING` | `primary_midwifery` |
| `" nursing "` | `primary_midwifery` |
| `garbage` | `primary_midwifery` |
| `""` | `primary_midwifery` |

So a value the resolver does not understand is promoted to the **strongest**
tier. Dirty upstream data makes a match look stronger, not weaker, which
inverts the principle that missing information must never increase certainty.

Cohort membership is unchanged (both tiers are eligible), so no count moves and
no other test fires. What changes is the published claim about HOW someone was
identified. Current behaviour is pinned by N2 so that changing it is
deliberate.

**Decision needed:** reject an unknown taxonomy, or treat unknown as nursing
and accept that records with dirty taxonomy lose the primary tier.

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
