# Scope: who this dataset counts, and who it does not

Written 2026-08-14 for co-author review. This document exists because the
answer was implicit everywhere and stated nowhere, and because the difference
between "midwives" and "the midwives we can see" changes how a reader reads
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

## Who is missing, and why it matters clinically

**Certified Professional Midwives (CPMs)** are certified by the North American
Registry of Midwives, not AMCB. They are **not in this dataset at all** — not
as a category with zero rows, not as an excluded group. They are simply
invisible to it, because the source directory never contained them.

The same is true of **state-licensed and licensed direct-entry midwives (LMs,
LDMs)**, whose credential is issued by a state rather than a national
certifying body, and of any traditional or unlicensed practitioner.

This is not a technicality for a midwifery workforce paper. CPMs and LMs attend
a large share of **community births** — home births and freestanding
birth-center births — and their distribution across states is very uneven,
because state licensure of direct-entry midwifery varies enormously. In states
where licensed midwifery is well established, a county can have substantial
midwifery care and **zero midwives in this dataset**.

The direction of the error is one-way and predictable: **this dataset
understates midwifery access, most severely exactly where non-AMCB midwifery is
strongest.**

### What we have not done

We have not quantified the gap. Doing so needs a source outside this
repository — NARM's certificant registry, state licensing boards, or MANA
statistics — and none has been ingested. Until it is, the correct statement is
directional ("understates, unevenly by state"), not numeric. **Do not put a
percentage on this without the data behind it.**

---

## The naming problem, which is live in committed artifacts

The prose and the column names disagree, and the prose is the correct one.

The generated county sentences say:

> "3 **certified nurse-midwives** were located here. That is 0.7 per 10,000
> women aged 15-44…"

The columns in the same file say:

| column | reads as | actually counts |
|---|---|---|
| `n_midwives` | all midwives | AMCB-certified CNM/CM, ACTIVE, NPI-linked |
| `midwives_per_10k_women` | midwifery supply | CNM/CM supply |
| `births_per_midwife` | births per midwife | births per CNM/CM |
| `no_located_midwife_with_births` | **no midwife here** | no *CNM/CM* located here |

The last one is the dangerous one. A county flagged
`no_located_midwife_with_births = TRUE` reads as a maternity-care desert. It
means no AMCB-certified midwife was located there — a county served entirely by
CPMs would carry that flag while having midwifery care.

Anyone loading the CSV sees the column name, not the sentence. Anyone reading
the sentence is correctly informed. Whichever a reader meets first determines
what they believe.

**Recommendation:** rename to `n_cnm_cm`, `cnm_cm_per_10k_women`,
`births_per_cnm_cm`, `no_located_cnm_cm_with_births`, or — if renaming breaks
too many downstream consumers — carry the qualification in every caption,
figure legend and table header that uses them. Renaming is the safer of the
two, because a caption can be dropped when a figure is reused and a column name
travels with the data.

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
  supply, *provided the comparison names the credential*

**Not safe to say without the missing data:**

- "midwifery access" or "midwife supply" unqualified
- that a county has no midwives
- anything about home birth or community birth
- state-to-state comparisons of *total* midwifery workforce, because the
  invisible share differs by state in a way we have not measured

---

## One sentence for the manuscript

If nothing else from this document survives, this should:

> This analysis includes only midwives certified by the American Midwifery
> Certification Board (CNM and CM). Certified Professional Midwives and
> state-licensed direct-entry midwives are not represented, so midwifery supply
> is understated to a degree that varies by state with the prevalence of
> non-AMCB credentials.
