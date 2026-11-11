# Longitudinal Reconstruction Changelog

Method changes from the longitudinal source-reconstruction work, with what each
did to the numbers. Entries that **withdraw** a published figure print the wrong
number beside the right one; those are the entries that matter.

---

## 2026-11-10 — Medicaid is not an unreliable source; the comparison was wrong

**Withdrawn.** Three statements about `medicaid_enrollment`:

| Published | Status |
|---|---|
| odd-one-out rate **0.166**, five times the next worst source | withdrawn — measured the comparator |
| truth-fusion agreement **77.5% / 77.6%** | withdrawn — same cause |
| "the clear systematic outlier" | unsupported |

**Root cause.** `expand_segments_to_years()` computed every `(year, npi, state)`
a midwife was concurrently enrolled in, then kept one per NPI-year by modal rule
and emitted the rest nowhere — **59,380 of 178,907 memberships, 33.2%**. Every
comparison then tested whether another source *equalled one arbitrary pick*
rather than whether it *named a state she was enrolled in*. A midwife enrolled
in CO, NM and AZ was recorded as AZ and scored as disagreeing with a source that
said CO.

**Corrected.** On the same 107,386 comparable NPI-years:

| | agreement with NPPES |
|---|---|
| equality with the modal pick | 74.7% |
| **membership of the enrolled set** | **88.5%** |
| 2024 alone | **91.4%** |

**14,815 NPI-years newly scored as agreeing.** No underlying record changed.

**No location assignment moved.** Truth fusion reads the single-valued series,
which is unchanged; the footprint is a separate artifact. Whether fusion
*should* resolve a multi-state source toward consensus is an open decision, not
something changed here.

**Caveat.** 88.5% shows the two sources are consistent under the corrected
comparison. It does not show that either names the midwife's true practice
location.

Files: `extract_medicaid_enrollment_state_by_year.R` (footprint emitter),
`audit_medicaid_set_membership.R`. Tests: `[19]`, 7 checks. Saboteur:
`medicaid-footprint-collapsed`, killed.

---

## 2026-11-10 — A prior correction of mine was itself incomplete

An earlier entry attributed Medicaid's disagreement to multi-state practice
being a multi-valued question. Half right, one step short: the reduction did
not merely *pick* one of several true states, it *discarded the others*. The
estimand explanation was superseded by the set-membership finding above.

Before that, I predicted the date-range expansion (A2) would resolve Medicaid's
outlier status. It did not — odd-one-out moved **0.166 → 0.163**, fusion
**77.5% → 77.6%**. The expansion was still correct and necessary; the prediction
was wrong, and the prediction was mine.

---

## 2026-11-10 — Medicare billing gaps are not workforce exit

**27.1% is the wrong headline.** It divides by all 8,147 Part D midwives,
including 1,682 seen in a single year who cannot have an interior gap. The
conditional rate among midwives whose span covers ≥3 calendar years — the ones
who could actually have one — is **40.1%** (2,209 of 5,514).

**Registry exit explains none of it.** Of 396 dated NPI deactivations in this
cohort, **zero** fall inside a gap. Zero conflicting timelines.

**Corroboration is mostly administrative, not clinical.** Of 2,731 episodes:

| evidence during the gap | episodes | midwives | share |
|---|---|---|---|
| confirmed dated billing | 285 | 266 | **10.4%** |
| Medicaid enrolment only | 2,223 | 1,831 | 81.4% |
| none | 223 | 195 | 8.2% |

An earlier draft reported 90–93% "corroboration" by counting enrolment as
activity. Enrolment is administrative presence, not care delivered. For
multi-year gaps, confirmed billing covers **any** missing year in 11.9% of
episodes and **every** missing year in **2.1%**.

**Suppression thresholds differ by program**, verified on the files: Part D
admits on claims (`Tot_Clms ≥ 11`), Part B on beneficiaries and services
(`Tot_Benes ≥ 11`, `Tot_Srvcs ≥ 11`). 35–41% of cohort Part D rows carry a
suppressed beneficiary cell — those providers *are* in the file with one field
withheld, which is a different mechanism from omission and is not evidence about
how many were omitted.

Files: `audit_billing_gaps_vs_registry_status.R`,
`audit_billing_gap_mechanisms.R`, `audit_billing_gap_headline_figures.R`,
`R/lib/billing_gaps.R`.

---

## 2026-11-09/10 — Part D gains a state for every year; PPEF recovered

**Part D**: 7,126 NPI-years over 4,349 midwives → **39,235 over 8,147**,
2013–2024. The warehouse holds 2013–2021 only as the `_standardized` cut, which
drops `Prscrbr_State_Abrvtn`; the CMS by-provider files carry it. Agreement with
NPPES moved 96.2% → **96.6%** while the base grew five-fold — stability under
more evidence, not a new finding.

**PPEF**: 16 previously unread vintages, **127,372 rows / 11,931 midwives**,
2016-08 → 2024-07. August 2016 alone holds **6,388** midwives with a state, five
years before the existing PECOS series begins.

**Medicaid enrolment** moved from the snapshot tier to longitudinal: 119,527
NPI-years, 2013–2024. The whole-file modal state differed from the year-specific
state on **14.4%** of NPI-years (30.5% in 2013 → 5.7% in 2024).

**`medicare_part_d_presence` removed** as a separate source — it would have
counted Part D twice.

---

## Open, not done

- Part B and Part D remain one claims lineage counted as two votes: **100.0%
  agreement on 13,745 NPI-years**, up from 2,423, so this work *grew* the
  inflation. `attribute_claims_collapse_lineage()` is not applied.
- NPPES snapshots are **6.0–19.1 months apart** (median 12.0); every
  year-over-year rate assumes a period that does not exist.
- Wilson intervals over transition counts treat repeated measurements of the
  same midwife as independent and are anticonservative.
- `assert_source_year()` is implemented and tested but not yet called by any
  producer.
- DAC 2017–2025 sits in the warehouse unused; its producer aborts on five
  absent NBER files before reaching the code that would read it.
