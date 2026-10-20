# Study scope: CNM/CM supply

Written 2026-08-14 for co-author review; updated 2026-08-16 after the inclusion
criterion was ratified. This document records the study estimand and the
language that must travel with county, state, district, access, employer,
training, and projection outputs.

---

## Study scope

This study evaluates the supply, distribution, characteristics, and
accessibility of Certified Nurse-Midwives (CNMs) and Certified Midwives (CMs) in
the United States. Other categories of midwifery practitioners are outside the
prespecified study population and are not included in the denominator,
analyses, or interpretation.

Everything here descends from one source: the **American Midwifery
Certification Board** public verification directory.

AMCB certifies two credentials and no others:

| credential | in cohort | share |
|---|---|---|
| **CNM** — Certified Nurse-Midwife | yes | 99.0% |
| **CM** — Certified Midwife | yes | 1.0% |

Layered on top, the analytic cohort is further restricted to certificants with
AMCB status **ACTIVE** and a **primary-tier NPI link** — **12,171** people, out
of **22,357** in the directory, per the currently registered cohort
(`artifacts/table1_provenance.csv`). An earlier freeze (2026-08-10) reported
11,920 of 22,309 under the same criteria; both numbers describe the identical
estimand, and the earlier one still appears in some figures and analyses built
before the 2026-09-02 re-scrape.

So a statement from this dataset is a statement about *actively certified
nurse-midwives and certified midwives who could be matched to an NPI*. It is
three restrictions deep, and each one is part of the stated estimand rather
than an attempt to measure a broader workforce.

**Durable rule.** CNM/CM scope is intentional, not a limitation. All workforce
counts, geographic analyses, access measures, employer analyses, training
analyses, and projections refer exclusively to CNMs and CMs. The project does
not attempt to measure total midwifery supply. Exclusion of CPMs, LMs/LDMs,
traditional midwives, or unlicensed practitioners must not be described as
missingness, undercoverage, or a study limitation.

---

## The naming problem, now corrected in the producer

The prose and the old column names disagreed, and the prose was the correct one.

The generated county sentences say:

> "3 **certified nurse-midwives** were located here. That is 0.7 per 10,000
> women aged 15-44…"

The old columns in the same file said:

| old column | reads as | replacement |
|---|---|---|
| `n_midwives` | all midwives | `n_cnm_cm` |
| `midwives_per_10k_women` | midwifery supply | `cnm_cm_per_10k_women` |
| `births_per_midwife` | births per midwife | `births_per_cnm_cm` |
| `no_located_midwife_with_births` | **no midwife here** | `no_located_cnm_cm_with_births` |

The last one was the dangerous one. A county flagged
`no_located_midwife_with_births = TRUE` read as a maternity-care desert. The
renamed column says what it means: no AMCB-certified CNM/CM was located there.

Anyone loading the CSV sees the column name, not the sentence. The 2026-08-16
decision therefore renames the county outputs so the inclusion criteria travel
with the data.

---

## Practice setting: now in Table 1 (D15, resolved 2026-09-28)

**Update 2026-09-28.** D15 in `docs/DECISIONS_CONTRACT.md` ("Does practice
setting belong in Table 1?") was Option A: a practice-setting block was added.
Table 1 now carries an "Any observed hospital work site" row (7,685 of 12,171,
64.4%, with at least one hospital work site observed) and a "Primary
claims-site setting" breakdown (Hospital 6,527, 64.3%; Clinic/practice 2,605,
25.7%; FQHC/community health 651, 6.4%; Birth center 169, 1.7%; remaining
categories smaller), sourced from `artifacts/midwife_work_setting_summary.csv`
via `build_trilliant_work_sites.R`. The rest of this section is kept as the
record of what was true before that: three further layers describe *where* a
midwife practises, and did not yet appear in Table 1:

| layer | coverage |
|---|---|
| CABC-accredited birth centers | 221 midwives across 111 centers |
| Freestanding birth center identification | built |
| Building taxonomy (MOB / hospital campus / birth center / outpatient clinic) | built |

**Delivery attendance is not observable in public Medicare data.** The Medicare
Physician & Other Practitioners by-provider-and-service file has **zero** rows
for the global and delivery-only obstetric codes (59400, 59409, 59410, 59510,
59514, 59515, 59610, 59612, 59614, 59618, 59620, 59622) for any provider in any
year 2013–2023, because CMS suppresses every provider-code cell under 11
beneficiaries and Medicare pays for few births
(`artifacts/medicare_delivery_code_observability.csv`). A row that used to sit in
this table — "CPT delivery claims: 7,470 midwives, 62.67%, confirmed attending
deliveries" — never read a procedure code. It counted Doctors & Clinicians rows
whose primary specialty is CNM: one row per practice location, 4,806 distinct
midwives, and an enrollment attribute rather than a behaviour. Retracted
2026-09-13.

Table 1 now adds hospital-work-site and primary-claims-setting blocks to its
other certification, demographics, geography, hospital-affiliation, Medicare
participation and Healthgrades blocks (see the Update above). The three layers
in the table just above this paragraph (CABC accreditation, freestanding
birth-center identification, building taxonomy) are still not in Table 1 —
that remains the right call per D15's ruling below, since the claims-derived
blocks already added carry the bulk of the signal and the three remaining
layers have thinner, more uneven coverage.

**Ruled**, D15 in `docs/DECISIONS_CONTRACT.md`, 2026-09-28: Option A, add a
practice-setting block with coverage stated.

---

## What this dataset supports, and what it does not

**Safe to say:**

- how many actively certified CNMs/CMs are locatable, and where
- how CNM/CM supply varies by county, rurality and ACOG district
- how CNM/CM supply compares against births, obstetric hospitals and OB/GYN
  supply

**Outside the study scope:**

- estimates of practitioner groups other than CNMs and CMs
- statements about all midwives regardless of credential
- denominators, access measures, or projections for a total-midwifery estimand

---

## One sentence for the manuscript

If nothing else from this document survives, this should:

> This analysis includes midwives certified by the American Midwifery
> Certification Board (CNM and CM). Other categories of midwifery practitioners
> are outside the prespecified study population and are not included in the
> denominator, analyses, or interpretation.
