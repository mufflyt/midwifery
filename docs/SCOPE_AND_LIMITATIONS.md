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
AMCB status **ACTIVE** and a **primary-tier NPI link** — 11,920 people, out of
22,309 in the directory.

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

## Practice setting: built, but not in Table 1

Four layers describe *where* a midwife practises, and none appears in Table 1:

| layer | coverage |
|---|---|
| CABC-accredited birth centers | 221 midwives across 111 centers |
| Freestanding birth center identification | built |
| Building taxonomy (MOB / hospital campus / birth center / outpatient clinic) | built |
| CPT delivery claims (59400 / 59409 / 59410) | 7,470 midwives, 62.67%, confirmed attending deliveries |

Table 1's 23 blocks cover certification, demographics, geography, hospital
affiliation, Medicare participation and Healthgrades attributes. Practice
setting is absent from all of them.

That may be the right call — coverage is thin, and hospital affiliation already
carries part of the signal. But **it is not recorded as a decision anywhere**,
so a reader cannot tell whether practice setting was considered and rejected or
simply never assembled. For a midwifery workforce paper, where a midwife
practises is close to the central descriptive variable, and its absence will be
asked about.

**This should become a ruled decision** alongside D10–D13 rather than remaining
an omission.

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
