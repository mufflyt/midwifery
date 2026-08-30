# Technical Appendix: What the Linkage Gap Is, and What the Rurality Estimate Can Claim

**Repository**: `midwifery`
**Primary scripts**: [`analyze_linkage_selection_bias.R`](../analyze_linkage_selection_bias.R), [`analyze_linkage_coverage_floor.R`](../analyze_linkage_coverage_floor.R)
**Artifacts**: `artifacts/linkage_selection_bounds.csv`, `artifacts/linkage_coverage_floor.csv`
**Enforcing gates**: scientific law L12 ([`tests/ci_science_laws.R`](../tests/ci_science_laws.R)), protected results ([`tests/ci_manuscript_numbers.R`](../tests/ci_manuscript_numbers.R))
**Investigation date**: 2026-08-29
**Status**: every number below is generated from a committed artifact and reproduced by the gates named above. Nothing here is typed.

---

## 1. Why this exists

The study links 22,309 AMCB certification records to the national provider
registry and reports geography for those that link. Two thirds link. The paper
originally treated the remaining third as a limitation of the matching and the
reported geography as a property of the workforce.

Neither survived examination. The metropolitan share had three different values
in circulation, none of them wrong in isolation; and a large part of the
unlinked third was never a matching failure at all.

This appendix records what each number means, which population it describes, and
what it may be used to claim.

## 2. One quantity had three values

| value | where | denominator |
|---|---|---|
| 86.5% | manuscript | 13,277 / 15,347 — the **retained subgroup**, including 486 members with no assignable county |
| 89.34% | `composition_rucc_cat.csv` | 13,277 / 14,861 |
| 89.8% | `linkage_selection_bounds.csv` | a different cohort, under a different rurality assignment |

None was fabricated. Each was computed correctly over a different denominator,
and every existing scientific law checked one artifact against itself, so none
could see the three together.

Two distinct errors produced 86.5%. It placed the 486 certificants with **no
assignable county** into the denominator of a *metropolitan share*, which
treats "we could not tell" as "not metropolitan" — the one thing the data does
not say. And 15,347 is the retained subgroup, while the sentence reporting it
said "the analytic cohort", which is 16,892.

The frame is now the analytic cohort throughout: **14,861 of 16,892** members
carry an assignable county, **13,277 of those (89.3%)** are metropolitan, and
**2,031** have none. 86.5% is retained in the stats catalog as
`cohort.metro_pct_retained_with_unknown` so that a reader reconciling against an
earlier draft can find where it went.

**Law L12** now checks the artifacts against each other and against the value
the manuscript renders, so this class of divergence fails the build rather than
reaching a reviewer.

## 3. The bounds did not bound the published estimate

The first version of the selection analysis rebuilt rurality from `county_best`
— the *geocoded* county — and defined the cohort as `npi_match_status ==
"matched"`. The published composition does neither:
[`R/07-cohort-composition.R`](../R/07-cohort-composition.R) derives rurality
from the practice ZIP through the Census ZCTA-county crosswalk, deliberately, so
that it is observable regardless of geocoding success.

The two populations differed by 160 people. The interval was arithmetic about a
population the manuscript never reports.

The analysis now assigns rurality with the published helpers, and refuses to
write unless it reproduces `composition_rucc_cat.csv` cell for cell.

## 4. What the bounds assume, in increasing order

| | assumption | metropolitan share, roster-wide |
|---|---|---|
| observed | none; describes the cohort only | 89.3% |
| **reported bound** | **none** | **64.9% – 92.2%** |
| wider bound | none, but discards observed evidence (§5) | 59.5% – 92.9% |
| ACTIVE-restricted | the question is about practising midwives | 69.4% – 92.2% |
| IPW | missingness is explained by certification status | 89.1% |

The IPW figure is reported as a sensitivity and never as a correction. Status
plainly does not explain all of the missingness; if it did, the bounds would not
be needed.

**The width is not a target, it is an identity.** Worst-case bounds have a
closed form — `100 * (1 - f)` for every category, whatever the observed
distribution. A narrower interval is not a tighter analysis; it is an assumption
someone declined to state. L12's fourth clause enforces exactly this and cannot
be satisfied by accident.

## 5. The most informative number is not a bound

Rurality is missing because a practice ZIP failed to resolve — **not** because a
certificant failed to enter the cohort. Those are different events, and
conflating them discards evidence.

**1,358 of the 5,417 non-cohort certificants carry a resolving ZIP.** They are
**87.7% metropolitan**, against the cohort's 89.3% — 1.6 points *below*, not
above.

This is the only direct evidence available on the *direction* of the selection,
and it points the same way as the persistence bias: if the certificants who
could not be placed resemble those who could, the cohort slightly overstates how
metropolitan the workforce is.

Reporting the wider 59.5–92.9% interval would mean buying five points of
apparent caution by ignoring 1,358 people who can in fact be located. The
reported bound keeps them.

**Tipping point.** For the roster-wide metropolitan share to fall to 75%, the
7,448 certificants with no assignable county would have to be **46.4%**
metropolitan — a departure of **43.0 points** from what was observed. The
qualitative conclusion survives a departure that large; that is what makes it
reportable despite the width.

## 6. Part of the unlinked third was never a linkage failure

NPPES began enumerating providers in 2006. A certificant who qualified in 1995
and lapsed in 2003 never held an NPI. No name matching recovers a record that
was never created.

Certification era and certification status vary independently, so the claim is
testable. If the shortfall were a matching failure, certifying before the
registry existed would depress linkage for everyone who did so.

| ACTIVE certificants | n | ascertained |
|---|---|---|
| certified before 2006 | 4,173 | **84.4%** |
| certified 2006 or later | 11,112 | **84.7%** |

Three tenths of a point. **Certifying before the registry existed costs a
practising midwife essentially nothing.**

The roster-wide era difference — 66.5% against 84.3% — is therefore era
confounded with having left practice, not an era effect on matching. The
shortfall concentrates where both conditions hold:

| pre-2006 certificants | n | ascertained |
|---|---|---|
| DECEASED | 481 | 33.7% |
| LAPSED | 4,707 | 55.4% |
| RETIRED | 1,256 | 60.0% |
| ACTIVE | 4,173 | 84.4% |

Of records for which no candidate was found at all, **1,606** qualified before
enumeration opened against **502** after.

This changes what the study may claim, not merely how complete it is. A matching
shortfall is a limitation of method: repairable in principle, direction unknown.
A registry-coverage boundary cannot be repaired from these data at all, and it
falls almost entirely on people who had already left the workforce — which is
the population a workforce estimate is not about.

`NPPES_START` is the registry's own opening year, not a quantile of this roster.
A data-driven cut would be circular, since what is being tested is whether the
registry's start date explains the gap.

## 7. Two selection rates, and they answer different questions

| status | cohort resolution | ascertainment |
|---|---|---|
| ACTIVE | 78.4% | 84.6% |
| LAPSED | 39.6% | 57.0% |
| RETIRED | 46.1% | 60.6% |
| DECEASED | 18.8% | 35.5% |

**Cohort resolution** is the share resolving to a provider record carrying
midwifery taxonomy — what admits a person to the analytic cohort.
**Ascertainment** is the share found in the registry at all, including those
whose only match carries nursing taxonomy.

The gap between them is entirely the cross-taxonomy rule. A certified
nurse-midwife must hold registered-nurse licensure and may have enumerated under
either; a nursing-only match is *found* but is not promoted into the midwifery
cohort.

Ascertainment answers whether the registry knows the person exists. Cohort
resolution answers whether this analysis is about them. §6 is stated on
ascertainment, because a question about what the registry ever recorded must not
be answered with a number that also encodes a cohort-membership rule.

Both are now named in the manuscript and both are registered protected results,
so neither can be typed into prose or silently substituted for the other.

## 8. What was tried and did not work

**A former-name crosswalk from the 19 historical NPPES snapshots.** The
reasoning was sound: NPPES overwrites legal names on change, so a maiden name
survives only in a snapshot taken before it. Building it recovered 50,633
aliases across 46,557 NPIs, 32,776 of them surname changes — and 85% of the
historical names are absent from `nppes_candidates.csv`.

It adds nothing, because both linkage paths already block against all 19
snapshots:

- [`match_amcb_to_npi.R:227`](../match_amcb_to_npi.R) — *"one row per (NPI, name spelling) so every historical surname is matchable, not just the current one"*
- [`match_nppes.R:253-260`](../match_nppes.R) — appends panel name-rows not already present in the candidate file, and counts the same surname-history statistic

The 85% figure was measured against `nppes_candidates.csv` as a file. That file
is not the candidate universe; the pipeline appends the historical rows to it at
runtime. **The measurement compared the input to itself.**

Recorded because the idea is a natural one to have twice, and the code already
answering it is not obvious from outside.

## 9. Reproducing this

```
Rscript analyze_linkage_selection_bias.R     # -> artifacts/linkage_selection_bounds.csv
Rscript analyze_linkage_coverage_floor.R     # -> artifacts/linkage_coverage_floor.csv
Rscript tests/ci_science_laws.R              # L12 and the eleven other laws
Rscript tests/ci_manuscript_numbers.R        # protected results: nothing typed
```

Both scripts read `artifacts/amcb_npi_linkage_FROZEN.csv`, which is person-level
and gitignored; they run where the pipeline has been run, not on a bare
checkout. Both are declared FROZEN consumers in
[`rebuild_frozen_dependents.R`](../rebuild_frozen_dependents.R), so a rebuild
cannot leave them holding a previous cohort. The artifacts they write are
aggregate and carry provenance sidecars naming their inputs.
