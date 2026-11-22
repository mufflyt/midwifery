# Temporal evidence validation

Two questions every longitudinal claim in this repository must survive, and
where each is enforced.

## 1. What year is this record actually from?

`R/lib/source_year.R::assert_source_year()` assigns every source-year a
verification level, in order:

1. **in_file_date** — a date column inside the file itself (preferred)
2. **release_id** — an authoritative release identifier on the source product
3. **fingerprint** — a pinned SHA-256 of a file whose vintage was established
4. **unverified** — a bare four-digit token (e.g. a filename `2024`) is *not*
   accepted as proof of a year
5. **refuted** — the file's contents contradict the declared year; fails

The rule exists because the first construction of this project took the year
from filenames, and a file named for one year can hold another. The declared
coverage contract (`config/state_source_audit_sources.csv` +
`R/lib/source_coverage.R`) calls it on every audited source-year in both
directions: a declared year absent from the file is *refuted*, a year in the
file nobody declared is *undeclared* — the file set may never decide the
sample.

**Wiring status:** `assert_source_year()` is enforced for every source in the
state-source audit (all 97 declared source-year rows pass). It is
implemented and tested but not yet called inside the individual producers
(Part B/D, PPEF, Open Payments, T-MSIS spending) — those producers take the
year from their own validated inputs, which the audit then re-checks. Closing
that gap means calling it at production time, not only at consumption.

## 2. When two sources disagree across time, which mechanism produced it?

`build_lead_lag_decomposition.R` decomposes `mrost_lead_lag.csv` into
`artifacts/lead_lag_decomposition.csv`, one row per source, separating:

| measured quantity | mechanism |
|---|---|
| `b_adopts_a_at_t1` / `b_adopts_a_multi` | source-side **reporting delay** — the source caught up to the registry later |
| `a_reverts_to_b_at_t1` / `a_reverts_b_multi` | **registry-side delay** — the source already held the value NPPES adopted; the registry's move was retrospective or late |
| `persistent_discordant_at_t1` | **ascertainment gap** — never resolves; or a definitional difference (flagged per source, not subtracted) |
| `cross_section_in_prior_b` | **source-led anticipation** — the source held the registry's destination value before the registry dated the move |

Measured on the 2026-11-18 run:

| source | source-late | registry-late | persistent | reading |
|---|---:|---:|---:|---|
| PECOS revalidation | 5.0% | 10.6% | 79.3% | mostly unresolved; resolves in both directions — no single laggard |
| Medicare Part B claims | 1.8% | 60.5% | 34.6% | claims **lead** the registry; NPPES reverts to the claims state |
| Medicare Part D claims | 0.9% | 60.2% | 35.1% | same pattern — billing sees the move first |
| Open Payments | 35.9% | 45.2% | 11.8% | resolves fast, in both directions |
| Medicaid enrollment | 5.3% | 3.8% | 85.1% | dominated by persistence, which for T-MSIS is partly *definitional* (enrollment-in-state ≠ practice-in-state), flagged in the artifact |

**What the claims finding means for "which source is timeliest":** for this
workforce, Medicare claims observe a practice move before the registry
records it — the registry catches up to the claims state ~60% of the time
when they disagree. The directory sources (DAC, Healthgrades) are snapshots
and cannot enter this analysis at all; that absence is a finding, not a gap
to paper over.

**Limits.** The mechanism labels are assigned at the transition level from
adoption direction; "retrospective date" is inferred from source-led
anticipation, not observed directly — NPPES does not publish when the change
*happened*, only `last_update_date`. A definitional component is flagged
(T-MSIS enrollment, PECOS on-file reassignments) rather than subtracted,
because the columns alone cannot split it out.
