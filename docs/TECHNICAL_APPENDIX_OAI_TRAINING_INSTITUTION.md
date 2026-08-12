# Technical Appendix: Recovering Midwifery Training Institution from Open Repositories

**Repository**: `midwifery`
**Harvest date**: 2026-08-10 / 2026-08-11
**Discovery**: [`discover_acme_repositories.py`](../discover_acme_repositories.py)
**Harvest**: [`harvest_dnp_theses.py`](../harvest_dnp_theses.py)
**Linkage**: [`link_theses_to_amcb.R`](../link_theses_to_amcb.R)
**Outputs**: `artifacts/acme_dnp_authors.csv`, `artifacts/amcb_education_history.csv`,
`artifacts/acme_repository_registry.csv`, `artifacts/acme_institution_audit.csv`,
`artifacts/oai_source_concentration.csv`

---

## 1. Problem

The CMS Doctors and Clinicians file carries a midwifery school for **14.3%** of
the cohort, and the AMCB roster publishes none. Training institution is
therefore missing for most certificants.

A student-authored DNP project, capstone or thesis is deposited in the
degree-granting university's repository, so the institution is **structural** —
determined by which repository holds the record, not parsed from a free-text
affiliation. That property is what makes open repositories worth harvesting and
distinguishes them from bibliographic databases, where affiliation is prose and
may reflect employment rather than training.

## 2. Sampling frame

ACME's accredited-program directory (retrieved 2026-08-10) defines the universe:
50 programs. Repositories are discovered from that frame rather than from the
open internet:

```
ACME program -> university -> institutional repository -> DNP/ETD collection -> authors
```

Two protocols are required. **OAI-PMH** (`Identify`, `ListSets`, `ListRecords`,
paged by `resumptionToken`, unqualified Dublin Core) covers bepress Digital
Commons and DSpace. **CONTENTdm** (`dmGetCollectionList`, `dmQuery`) covers
Frontier Nursing University, the largest CNM program in the United States, which
runs neither of the dominant platforms. Protocol heterogeneity is not an
implementation detail: a harvester supporting only OAI-PMH misses the single most
productive source entirely.

## 3. Collection targeting

Sweeping a repository and filtering by keyword is ineffective — large
repositories hold hundreds of thousands of records of which midwifery degree
works are a vanishing fraction. Collections are therefore classified by name:

1. **Midwifery-specific** (`midwif`, `nurse-midwifery`) — membership is
   sufficient evidence; no keyword filter is applied to records.
2. **Nursing degree work** (nursing *and* thesis/dissertation/ETD/DNP/capstone) —
   harvested, then filtered on record text.
3. Neither — not harvested.

Specialty keywords are **corroborating fields, never inclusion requirements**.
Seattle University's generic "Doctor of Nursing Practice Projects" set holds 209
authors of whom only 7 mention midwifery in metadata, yet 24 match the AMCB
roster: requiring the word discards 97% of the collection and 19 of the 24
matches.

## 4. Linkage

Direction is **AMCB roster → repository authors**, not the reverse: both
universes are bounded, which is a far better record-linkage problem than
searching the literature for midwives.

Names are parsed with `humaniformat` on **both** sides after credential and
title tokens are stripped, then compared as **token sets** — identity rests on a
shared full given-name token, not on position. Initials are excluded, since
"W." is compatible with every W. `"Williams, W. Jon"` and `"Jon W Williams"`
match on `JON`; a positional rule scores them as different people.

**Evidence tiers** (`training_evidence_class`):

| tier | rule |
|---|---|
| 1 | institution or collection is midwifery-specific; membership is the evidence |
| 2 | generic collection **and** (first-given-name match on a roster-unique name, **or** midwifery text present) |
| 3 | generic collection, name match only — candidate, not data |
| 4 | several certificants match one author string — unresolvable |

Precision is estimated by a **permutation control**: given-name tokens are
shuffled against surnames and the match repeated, so surviving matches are name
collisions. Reported per institution, because collision risk scales with
collection breadth — 7% at Frontier (all authors are nurse-midwifery students)
against 54–84% at schools whose DNP collections span every nursing specialty.

**Geography is deliberately not used as a corroborator.** State agreement bought
precision by discarding anyone who trained in one state and practises in
another — 89% of usable matches — which is irrelevant to where a person went to
school. It was replaced by name rarity.

## 5. The variable that matters: two, not one

`midwifery_program` and `later_doctoral_institution` are **separate variables**.
Conflating them is the largest conceptual trap in this source.

Of 724 usable links, **43% are degrees earned after certification** — the person
was already a practising midwife when the project was written, median gap
**7 years**. Frontier alone contributes 280 such rows. Recording those as
"trained at Frontier" would be false.

Composition differs completely by institution, and the gap distribution
diagnoses program type:

| institution | median gap | interpretation |
|---|---:|---|
| Bethel University | 0 yr | entry-level MS; certification and thesis are the same event |
| Seattle University | 0 yr | entry-level DNP |
| Frontier Nursing University | 4 yr (p90 19) | post-professional DNP; practising CNMs returning for a doctorate |

A single temporal window fitted on one type destroys the other: Seattle's
−1..+3 window drops 308 of Frontier's 555 matches. The window is therefore a
**reported field**, never a gate.

## 6. Results

| | |
|---|---:|
| ACME programs in frame | 50 |
| repositories resolved | 34 |
| with nursing/DNP collections | 28 |
| author-records harvested | 35,038 |
| institutions represented | 25 |
| certificants matched (any tier) | 876 |
| usable (tier 1–2) | 724 |
| **`midwifery_program` assigned** | **266 (1.2% of 22,309)** |
| `later_doctoral_institution` | 321 |

`midwifery_program` by institution: Bethel 126, Frontier 108, Seattle 24,
Buffalo 3, South Carolina 2, Yale 2, UNLV 1.

**Concentration is the dominant limitation.** Bethel and Frontier contribute
234 of 266 (88%). Yield is not proportional to effort: Marquette produced 11,483
records for 7 certificants while Frontier produced 1,986 for 520, because
Frontier's repository *is* a midwifery school's output.

## 7. Ascertainment defects found by audit

Each of these produced **false-negative institution coverage** — apparent
absence of evidence that was actually a harvesting failure. They are recorded
because negative findings from this source cannot be interpreted without them.

| defect | consequence |
|---|---|
| `thesis` did not match "Thes**es**" | Bethel's "Nurse-Midwifery Theses and Projects" (154 records, tier-1 evidence) discarded entirely |
| `doctoral` did not match "**Doctor of** Nursing Practice" | Seattle (409 records), New Mexico, South Carolina, UNLV and Yale lost their DNP collections; Seattle fell from 24 matches to 1 |
| set vocabulary required "nursing" | midwifery-**named** collections invisible — Jefferson's three midwifery sets match AMCB at 6 of 8 authors, the highest hit rate in the corpus |
| `ListSets` never paged | 100 of Ohio State's 3,052 sets seen; its "Doctor of Nursing Practice Final Document Projects" sits past page 30. Eight institutions written off on that evidence |
| `\bMr\b` matched inside "Mróz" | credential stripper returned a surname of "OZ"; `ó` is not an ASCII word character, so the boundary assertion succeeded inside the name |
| discovery was destructive | a concurrent probe timing out demoted verified Ohio State to `not_found` between two runs of the same command |

Three further linkage defects: ambiguity was computed per *project* rather than
per *author string*, so genuine multi-author projects were flagged unresolvable;
a shared **middle** name was treated as identification (`"Casey, Lauren Marie"`
matched `"Annette Marie Casey"` on MARIE); and `\b` is not a word boundary in
POSIX ERE, which silently disabled several R-side patterns.

## 8. Structural ceilings

Some institutions cannot yield training evidence from their own repository, and
this is a property of the institution rather than a fixable miss:

- **Hospital-affiliated and certificate-only programs.** Baystate Medical
  Center is midwifery-only, harvested 1,165 records, and yielded zero. Its
  repository is a hospital system's — newsletters, poster symposia, nursing
  reports. Its degree is conferred by a partner (Jefferson's Midwifery Institute
  or UMass), so its students are invisible in its own repository. Eighteen AMCB
  names appear there **unfiltered**, but as clinicians employed at Baystate;
  admitting them would silently redefine the variable as "worked at".
- **MS-completion pathways** produce no deposited thesis.
- **16 ACME programs** have no findable repository, including Vanderbilt,
  Georgetown, Rutgers, Colorado, Illinois-Chicago and Cincinnati.

## 9. Sources evaluated and rejected

**PubMed author search.** `"Last F"[Author]` returned at least one record for
50% of sampled midwives — and 42% when given a **deliberately incorrect** first
initial. The full-author-name field improved this only to 13% versus 8%. The
query identifies surnames, not people, and was rejected.

**Commencement programs** were attempted as a higher-grade source (a name under
a `Nurse-Midwifery` heading is a structural assignment, with no timing
heuristic). Extraction works — East Carolina 18 graduates, Penn 28 — but
crawl-based discovery failed: 20 PDFs across 10 institutions, roughly half not
graduate lists (campus maps, application forms, yard signs), no year before
2024, and **both known-good PDFs were missed**. The method requires
site-restricted search rather than URL-pattern crawling; the harvester is
retained at [`harvest_commencement_programs.py`](../harvest_commencement_programs.py).

## 10. Recommended use

Treat repository evidence as **supplemental ascertainment**, not a
population-representative sample:

1. filling missing `midwifery_program` where nothing else exists;
2. corroborating other training-source linkages;
3. describing repository-based ascertainment itself.

Do **not** compute an institution distribution from it. `midwifery_program`
covers 1.2% of the roster and 88% of that is two schools.
