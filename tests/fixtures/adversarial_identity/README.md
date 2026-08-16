# Adversarial identity-resolution corpus

A permanent, versioned synthetic corpus of the ways an identity resolver gets
fooled. Items 7, 45 and 46 of the adversarial testing programme.

**No real people.** Every identifier here is invented. The NPI-shaped columns
are named `synthetic_npi` rather than `npi` on purpose: `tests/ci_leak_guard.R`
flags any tracked CSV carrying a column called `npi`, and its baseline is a
ratchet that may shrink and never grow. Invented identifiers for invented
people should not look like person-level data.

## Files

| File | What it holds |
|---|---|
| `corpus.csv` | positive controls, negative controls, collision families |
| `decoy_escalation.csv` | ordered decoy sequences and their intended trajectories |

## The corpus is not optimised for match rate

Most of it is *supposed* to stay unresolved. A change that raises the match rate
here is a regression until proven otherwise. The scientific question is not
"can we find a candidate" but:

> Can the resolver distinguish "the evidence identifies this person" from
> "one candidate happens to look best"?

`tests/test_adversarial_identity_resolution.R` section J asserts the corpus is
still genuinely adversarial — that it still contains ties, collisions, weak
evidence classes and expected-unresolved cases — because an easy corpus passes
silently.

## Columns

- `family` — the adversarial family; rows sharing a family are one scenario
- `kind` — `positive`, `negative`, or `collision`
- `amcb_id` — synthetic person
- `synthetic_npi` — synthetic candidate identifier
- `name_evidence_class` — 1 strongest … 5 weakest, as candidate generation assigns
- `taxonomy_axis` — `midwife` or `nursing`
- `expect` — `member`, `held_out`, or `quarantined`
- `expect_synthetic_npi` — required identifier when `expect == member`
- `why` — why this is the scientifically correct answer

## Reuse

This corpus is meant to be reused, not copied. Later work — metamorphic tests,
source-dropout, threshold-neighbourhood sweeps, independent reference models —
should load these same people rather than inventing new ones, so that a change
in resolver behaviour shows up in one place.

## What it cannot decide

Several families it names (license-state collisions, credential
incompatibility, shared address, former-name provenance) are decided during
**candidate generation** in `match_amcb_to_npi.R`, upstream of anything the
test can call. They arrive at the resolver already reduced to an evidence
class, so the corpus represents them by that class and the test prints the
limitation every run rather than implying coverage it does not have.

One-NPI-one-person is enforced by `rank_one_to_one()` — stage 2, in the private
`mufflyt/isochrones` repository. Stage 1 can only *detect* contention.
