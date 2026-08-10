# Cohort re-freeze, 2026-08-10 — decision record

## What was decided

`artifacts/frozen_cohort/` was re-frozen against the current
`midwives_geography_guarded.csv`: **17,538 → 16,892 rows**, `county_best`
coverage **86.5% → 97.7%**.

## Why the alternative was not available

The fingerprint pinned sha256 `6e325de0…` (17,538 rows, source mtime
2026-08-08 18:59:28). **That payload no longer exists anywhere.** All three
copies on disk — the working file, the frozen copy, and
`artifacts/midwives_geography_FROZEN.csv` — hash to `9455138198e4…` (16,892
rows, mtime 2026-08-08 20:17:42). It is not in git either: the frozen payload
is gitignored by design, because it is person-level.

So the state before this decision was not "old pin vs new source". It was a
**broken pin**: the fingerprint claimed 17,538 while the file beside it held
16,892. That is worse than either option, because every check that reads the
fingerprint describes a file that is not there.

How it broke: the source was regenerated on 2026-08-08 at 20:17, after the
19:23 freeze. An adversarial-loop cycle then re-froze the payload; the cycle-18
review reverted the tracked files (`INPUT_FINGERPRINT.json`,
`analytic_cohort.csv`) but **could not revert the payload**, which git never
had. The revert therefore restored metadata onto data it no longer described.

## Why re-freezing costs the study nothing

Recovered from the tracked `analytic_cohort.csv` (17,538 rows), which survived
even though the payload did not:

| | n |
|---|---:|
| In old cohort, absent from live geography | 1,563 |
| **…of which are in the ACTIVE primary-linked cohort** | **0** |
| In live geography, absent from old cohort | 917 |
| **…of which are in the ACTIVE primary-linked cohort** | **140** |

Not one of the 11,913 analytic midwives is in the lost set. The 1,563 are
non-ACTIVE or non-primary-linked records. The re-freeze **strictly improves**
the analytic cohort: 140 midwives gain geography, none lose it.

## Verified effect

- Table 1 cohort: **11,913, unchanged**.
- Table 1 diff: three lines, all in the Healthgrades attribution block
  (19 → 69 shared profiles), which is crawl progress and not the re-freeze.
- `artifacts/midwives_geography_FROZEN.csv` was **already** the 16,892 version,
  so the rest of the pipeline had been running on this source all along.
  `frozen_cohort/` was the only lagging copy.

## What this does not fix

The freeze mechanism still cannot be rolled back, because the payload it pins
is gitignored. A future `freeze_input()` should either write the payload to a
content-addressed store that is not ignored, or record enough (row keys plus
per-column digests) that a lost payload can be *detected and described* rather
than silently replaced. Detection now exists — cycle 18's widened T187 reports
a diverged pin — but recovery does not.
