# Technical Appendix: The Candidate Pool, and What Name Linkage Cannot Reach

**Repository**: `midwifery`
**Primary code**: [`build_midwife_panel.R`](../build_midwife_panel.R) (`panel_tax_predicate()`)
**Primary artifact**: `midwife_panel.csv` — 443,623 NPIs (gitignored, person-level)
**Sensitivity artifact**: `midwife_panel_wide.csv` — 845,255 NPIs (gitignored, person-level)
**Investigation date**: 2026-08-30
**Decision**: the wide pool is a **sensitivity artifact**. It is not the primary panel.

---

## 1. The pool is the ceiling

Every strategy in the linkage — exact name, first initial, edit distance,
surname component — searches the same candidate pool. No rule can find a
certificant the pool does not contain. So before asking how well the name
comparison works, it is worth asking what it is allowed to see, because a
certificant outside the pool is not a hard match. She is an impossible one, and
she is indistinguishable in every artifact from a person who does not exist.

This appendix measures that boundary. The short answer: it is real, it is
smaller than it looks, and moving it costs more than it recovers.

## 2. How the narrow pool drifted from its own reasoning

The panel admits nursing taxonomies for a stated reason, in
[`build_midwife_panel.R`](../build_midwife_panel.R):

> A CNM must hold RN licensure, so enumerating under a nursing or women's
> health taxonomy instead of a midwifery one is a registration choice, not a
> different profession.

That argument does not stop at any particular specialty, but the code did. The
enumerated list is ten codes:

| family | in the pool | exist |
|---|---|---|
| Midwifery (`367A00000X`, `176B00000X`) | 2 | 2 |
| Nurse Practitioner (`363L*`) | 4 | ~14 |
| Registered Nurse (`163W*`) | 2 | ~30 |
| Clinical Nurse Specialist (`364S*`) | 1 | ~10 |
| CRNA (`367500000X`) | 1 | 1 |

Family NP (`363LF0000X`) and Maternal Newborn RN (`163WM0102X`) are both
absent. A CNM whose only enumeration is under either is outside the candidate
universe by every route.

**The rule is now a prefix family, not a hand-list**, shared by both readers via
`panel_tax_predicate()`. The classic and reshaped release formats previously
built their own `IN (...)` clauses; widening one and not the other would have
made the pool's composition depend on which format a given year shipped in — a
difference that looks exactly like a real change in the workforce.

## 3. The two pools

`PANEL_TAX_SCOPE` selects the scope, and **the scope is in the filename**. A
wide panel sitting at `midwife_panel.csv` would be picked up silently by
`match_amcb_to_npi.R` and change the published cohort; that is now impossible.

| | narrow (default) | wide (sensitivity) |
|---|---|---|
| rule | 10 enumerated codes | `363L*`, `163W*`, `364S*` + midwifery + CRNA |
| distinct NPIs | 443,623 | **845,255** (1.91×) |
| identity rows | 479,617 | 918,151 |
| panel rows | — | 7,875,954 |
| NPIs under >1 surname | — | 64,839 |
| file | `midwife_panel.csv` | `midwife_panel_wide_scoped.csv` (750 MB) |

On the 2025 snapshot alone: 7,043,608 individual providers, of whom 418,964
match the narrow rule and 825,515 the wide one.

## 4. What widening actually buys — and costs

Both columns below count exact first-and-last-name pool membership, computed the
same way, **before** the middle-name comparison and evidence-class resolution
run. They are upper bounds and they are comparable to each other; neither is a
post-resolution count.

**Recoverable**, of the 2,108 rows currently reported as "no candidate":

| | n |
|---|---|
| gain an exact first+last candidate in the **narrow** pool | 82 |
| gain one in the **wide** pool | **240** |
| …candidate is unique | 231 |
| …any candidate carries midwifery taxonomy | 62 |
| **unique *and* midwifery — the strongest recoverable set** | **60** |

**Cost**, over the 15,965 rows already resolved:

| | n |
|---|---|
| gain ≥1 new exact-name rival | 2,137 |
| **were unique, now not unique** | **982** |

Roughly **four resolved records put at risk for every one recovered**, and only
60 of the recoveries are cleanly resolvable to a midwife.

### 4a. The same question, answered after the veto and the resolver run

The bounds above count pool membership. Running the shipped rules over the same
two pools — `amcb_middle_agreement()`, the conflict veto, and best-class
resolution — gives the outcome rather than the bound:

| of the 2,108 "no candidate" rows | narrow | wide |
|---|---|---|
| resolve **uniquely** at the exact-name tier | 17 | **163** |
| …of which the candidate carries midwifery taxonomy | — | **15** |
| gain candidates but tie | — | 1 |

| of the 16,961 rows resolved in the control | n |
|---|---|
| unique in the narrow pool, **tied** in the wide pool | **528** |
| unique in both | 15,249 |

**163 recovered against 528 lost, and only 15 of the recoveries are midwifery.**
The bounds overstated both sides, as expected, and the direction is unchanged:
roughly three resolved records become ambiguous for every one recovered, and
roughly thirty-five for every midwifery-taxonomy recovery.

This measurement covers the exact-name tier, classes 1 and 2. That is exact for
the recovery count — a record with a unique class-1/2 candidate resolves there
regardless of what classes 3 to 5 hold — and a **lower bound** on the cost,
because it cannot see rows pushed into ties by new class-3 rivals alone. Class 3
is surname plus first initial and is the noisiest stratum in the pipeline, so
the true cost is higher than 528, not lower.

## 5. The hypothesis this refutes

The investigation began from a reasonable and, as it turns out, wrong idea: that
taxonomy truncation was a large hidden reservoir, and that some substantial part
of the 2,108 were real midwives enumerated under an excluded code.

The evidence says otherwise. **1,282 of the 2,108 have their exact surname
already present in the narrow pool** and still produce no candidate, and 63 have
neither name anywhere in it. Widening to twice the NPIs converts 240 of them —
11% — into rows with an exact-name candidate. The remainder are not hiding under
Family NP. They are people whose name, as AMCB spells it, does not appear beside
a matching given name anywhere in the nursing and midwifery registry.

That is a finding about the sources, not a defect to tune away.

## 6. Why the wide pool is a sensitivity artifact and not the primary

Three reasons, in order of weight.

**It would cost more midwives than it finds.** Measured after the veto and the
resolver (§4a): 528 resolved records become ties against 163 recoveries, only 15
of them midwifery. That is not a trade this cohort should take silently, and 528
is a lower bound.

**It dilutes the evidence tiers.** The pool already carries 21× more nursing
NPIs than midwifery ones, which is why taxonomy sets the evidence tier rather
than deciding identity. Doubling the nursing side widens class 3 — exact surname
plus first initial — which already generates 76% of all candidate pairs and
1,487 of the 3,044 ties. Most of what widening adds is noise in the stratum that
is already noisiest.

**The primary panel defines a frozen cohort.** `midwife_panel.csv` determines
the primary midwifery tier in a published cohort. Changing it is a scientific
decision that needs its own registered comparison, not a side effect of an
exploratory rebuild.

The wide panel is kept because the ceiling question is legitimate and recurring,
and because a measured bound is worth more than a repeated hypothesis.

## 7. Reproducing this

```
PANEL_TAX_SCOPE=narrow Rscript build_midwife_panel.R   # midwife_panel.csv (default)
PANEL_TAX_SCOPE=wide   Rscript build_midwife_panel.R   # midwife_panel_wide.csv

MIDWIFE_PANEL=midwife_panel_wide.csv \
MATCH_OUT=artifacts/amcb_npi_linkage_WIDEPOOL.csv \
  Rscript match_amcb_to_npi.R                          # the sensitivity linkage
```

Both builds are resumable per snapshot and take roughly 45 minutes over 19
snapshots on an external drive. The reader settings are load-bearing and
documented in the script: `sample_size` must stay small — `sample_size = -1`
forces a full multi-GB scan that fails outright on every release from 2018
onward — and the encoding probe is per file, because releases up to 2017 are
latin-1 and those from 2018 are UTF-8.

## 8. What this does not settle

**The full wide-pool linkage does not run on this hardware.** It was attempted
twice. It reads the panel, passes its own configuration checks, builds all
949,542 identity rows, and is then killed during candidate generation with no R
error — the signature of the operating system reclaiming memory, not of a
failure the script can report. The machine has 8 GB of RAM and had already
logged 4.1 million pageouts; the narrow arm peaks near 4 GB and the candidate
joins scale worse than linearly in pool size. §4a exists because of this: it
answers the same question with a targeted pass that touches only identity rows
whose name a certificant actually carries.

The cost figure is therefore a lower bound rather than a total, for the reason
given in §4a. Closing that gap needs either a machine with substantially more
memory or a chunked candidate-generation path in `match_amcb_to_npi.R`, and
neither is worth building for a sensitivity arm already 3:1 against.

Two boundaries remain outside this measurement entirely:

- **The panel window.** Snapshots run 2007–2025. 1,174 certificants certified in
  2025–2026 and 519 of them are unresolved, at no-candidate rates of 10.2% and
  35.6% against 2.7% for 2024. Those are not linkage failures and no pool change
  reaches them. See
  [`TECHNICAL_APPENDIX_RECORD_LINKAGE.md`](TECHNICAL_APPENDIX_RECORD_LINKAGE.md).
- **Ties.** 3,044 records tie on name evidence and 1,196 of them have no
  midwifery candidate at all. Breaking those needs an identifier neither source
  publishes — a licence number, a date of birth, or a practice address on the
  AMCB side — not a larger pool. A larger pool makes them worse.
