# Co-author brief — Bree Thumm, 2026-08-14

Prepared for a working discussion. Everything here is either a decision that
needs clinical judgement, or a limitation that will need a sentence in the
manuscript whether or not we like the number.

Nothing in this document asks for agreement with a method. It asks the
questions the code cannot settle, and states the numbers each one turns on.

---

## 1. What the dataset is, in three numbers

| | |
|---|---|
| **22,309** | certificants in the AMCB directory. Reconciles to AMCB's own totals |
| **65.7%** | link to an NPI with midwifery taxonomy confirmed. **This is the inferential ceiling** |
| **~99%** | of whatever links gets a county. Geographic completeness is *not* the limitation |

The linked subset is **not a random sample**: 82.3% of ACTIVE certificants link
versus 19.6% of DECEASED. Any statement about "midwives" is a statement about
the linked, mostly-active subset, and the manuscript needs to say so once,
early, in those words.

---

## 2. Questions that need your clinical judgement

These are drafted as D10–D13 in
[`DECISIONS_CONTRACT.md`](DECISIONS_CONTRACT.md) and are **open** — no ruling
has been made.

### D10 — May we report organisation/employer affiliation at all?

Coverage is 39.7%. Two independent implementations of the resolver agree on
**16.4%** of cases. Per-rule positive predictive value is **0.84** (multi-key)
and **0.96** (cross-source); both fall below the threshold we set, and
`artifacts/org_resolution_ppv.csv` ships with `meets_threshold = FALSE` in
every row.

The clinical question underneath the statistics: **how wrong is a wrong
employer?** Naming the wrong hospital for a named midwife is a different kind
of error from a missing cell, and you are better placed than the code to say
whether a 16% agreement rate is a footnote or a reason to drop the layer.

### D11 — Do the three birth-activity states survive into published tables?

`R/15-build-birth-activity.R` (now documented in
[`METHODS_birth_activity.md`](METHODS_birth_activity.md)) classifies each
midwife as:

| state | meaning |
|---|---|
| `observed_birth_attendant` | births observed in the claims/certificate data |
| `no_observed_births` | none observed **and** ascertainment declared adequate for her state-year-source |
| `birth_activity_unobserved` | none observed and ascertainment **not** established |

The third is not "she attended no births". Collapsing it into the second is the
same error that published 651 counties as having no obstetric care, and it
would be undetectable in the output. **Does a three-level activity variable
survive peer review, or does the manuscript need a binary?** If binary, which
way does `unobserved` go, and what does the table footnote say?

### D12 — Is 74% state-board coverage reportable, given it is non-random by state?

9,037 midwives verified across 20 state boards. The 20 are the states that
publish bulk data or belong to the Nursys compact — an availability sample, not
a design. Same shape as the ACTIVE/DECEASED bias above: usable with a stated
limitation, misleading without one.

### D13 — Table 1's `Language` row understates by construction

The row reads "At least this many speak a language other than English: **367
(3.1%)**", with 11,441 "not listed". Healthgrades lists languages
inconsistently, so absence is not evidence of English-only — the variable is a
**floor**, not a rate.

Does a floor belong in Table 1 at all? It is honest and it is nearly useless,
and a reader who skims will read 3.1% as a prevalence.

---

## 3. Two gaps in Table 1 — found, explained, and closed

Both are resolved as of 2026-08-14; recorded here because they change numbers
you may have already seen.

**112 midwives share a Healthgrades profile URL** with another certificant, so
no profile can be attributed to either. They were excluded from every
Healthgrades-derived row. The exclusion is correct. Two things about it were
not:

- it was documented only in a code comment and a commit message saying **14**.
  The figure grew to 112 as the crawl completed and nothing user-facing was
  updated
- the "Accepts new patients", "Offers telehealth" and "Language" blocks
  therefore summed to **11,808**, not 11,920, with no row explaining it

**38 midwives have an overseas-military or US-territory address**, for which no
ACOG district exists. The code comment beside the block said these were
"reported on their own line rather than inside Unknown" — they were not. A
`filter()` removed them before the block was built, so the block summed to
**11,882** and the 38 were invisible.

**Ruling applied (D14): denominators match, and remainders are shown.** Every
one of the 23 blocks now sums to 11,920, each remainder carries its own named
row, and percentages still use the attributable denominator — the new rows are
counts, never rates. `tests/ci_artifact_contracts.R` enforces it with no
exemptions, so the table cannot silently stop reconciling again.

What this means for you: **Table 1 has two new rows per Healthgrades block and
one in the ACOG block.** No percentage changed. If you have a draft with the old
table, the numbers you cited are still correct — the table simply now accounts
for everyone.

## 4. Limitations already settled, for your awareness

Nine estimand decisions (D1–D9) were ratified 2026-08-10 and are recorded with
their evidence, options considered, and ruling in `DECISIONS_CONTRACT.md`. The
ones most likely to come up:

- **General fertility rate** carries a validity bound only, no reliability
  filter. Small counties produce extreme rates — De Baca County NM shows 483
  births per 1,000 women 15–44 on 145 women. Any superlative or ranking must
  exclude small denominators.
- **Suppressed CDC WONDER cells are never zero.** Three separate defects made
  them zero in published output and all three are fixed and now guarded.
- **Training institution** is recovered from university repositories and covers
  **1.2%** of the cohort, 88% of it from two schools. Use it to corroborate,
  never to describe where midwives train.
- **Age is imputed** against a model calibrated on verified DOBs (R² = 0.550,
  RSE = 7.71 years). Every age carries a provenance flag; see
  `TECHNICAL_APPENDIX_AGE_IMPUTATION.md`.

---

## 5. Housekeeping for a co-author

- `CITATION.cff` now lists you as an author. **It needs your ORCID and the
  affiliation you want to use** — both are marked `TODO` rather than guessed.
- Authorship order and contribution statement are not recorded anywhere yet.
- The repository is private and MIT-licensed for the code. The AMCB roster and
  scraped profile content are not ours to license, and the README says so.

---

## 6. One thing that is not a science question

Person-level files — names, certification numbers and NPIs for all 22,309
certificants — were committed early in the project. They are now untracked and
gitignored, but **they remain in git history and in every existing clone**.
Removing them going forward is done; unpublishing them is not, and would
require rewriting history.

Worth a decision before the work is shared more widely, and worth knowing that
it is a decision rather than an oversight.
