# Scope: CNM/CM inclusion criteria

Written 2026-08-14 for co-author review; updated 2026-08-16 after the inclusion
criterion was ratified. This document exists because the difference between
"CNM/CM workforce" and "total midwifery workforce" changes how a reader reads
every map in this project.

---

## The cohort, precisely

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
three restrictions deep, and each one is defensible on its own. Stacked, they
are easy to forget.

---

## Who is outside the inclusion criteria, and why it matters clinically

**Certified Professional Midwives (CPMs)** are certified by the North American
Registry of Midwives, not AMCB. They are outside this study's inclusion
criteria, not an accidentally missing subgroup.

The same is true of **state-licensed and licensed direct-entry midwives (LMs,
LDMs)**, whose credential is issued by a state rather than a national
certifying body, and of any traditional or unlicensed practitioner.

This is not a technicality for a midwifery workforce paper. CPMs and LMs attend
a large share of **community births** — home births and freestanding
birth-center births — and their distribution across states is very uneven,
because state licensure of direct-entry midwifery varies enormously. In states
where licensed midwifery is well established, a county can have substantial
midwifery care and **zero CNMs/CMs in this dataset**.

The implication is one-way and predictable: **CNM/CM supply is not total
midwifery supply**, especially where non-AMCB midwifery is strongest.

### What we have not done

We have not quantified non-AMCB midwifery supply. Doing so needs a source outside this
repository — NARM's certificant registry, state licensing boards, or MANA
statistics — and none has been ingested. Until it is, the correct statement is
scope-based ("outside this CNM/CM cohort"), not numeric. **Do not put a
percentage on non-AMCB midwifery without the data behind it.**

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

**Not safe to say from this inclusion-defined cohort alone:**

- "midwifery access" or "midwife supply" when meant as total midwifery
- that a county has no midwives of any credential
- anything about home birth or community birth
- state-to-state comparisons of *total* midwifery workforce, because the
  invisible share differs by state in a way we have not measured

---

## One sentence for the manuscript

If nothing else from this document survives, this should:

> This analysis includes midwives certified by the American Midwifery
> Certification Board (CNM and CM). Certified Professional Midwives and
> state-licensed direct-entry midwives are outside the inclusion criteria, so
> results describe CNM/CM supply rather than total midwifery supply.
