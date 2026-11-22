# Technical Appendix: OIG Remake Phase 2 — Candidate-Set Cardinality & Source-Intersection Analysis

**Repository**: `midwifery`
**Primary script**: [`oig_phase2_candidate_set_and_intersection_analysis.R`](../oig_phase2_candidate_set_and_intersection_analysis.R)
**Library**: [`R/lib/oig_phase2_candidate_set.R`](../R/lib/oig_phase2_candidate_set.R) (pure, unit-tested set-arithmetic helpers)
**Tests**: [`tests/test_oig_phase2_candidate_set_analysis.R`](../tests/test_oig_phase2_candidate_set_analysis.R)
**Outputs**: [`artifacts/oig_remake/oig_phase2_candidate_cardinality_by_tier.csv`](../artifacts/oig_remake/oig_phase2_candidate_cardinality_by_tier.csv), [`artifacts/oig_remake/oig_phase2_source_intersections_summary.csv`](../artifacts/oig_remake/oig_phase2_source_intersections_summary.csv), [`artifacts/oig_remake/oig_phase2_1789_reassessment.csv`](../artifacts/oig_remake/oig_phase2_1789_reassessment.csv) (all aggregate, each with a `.provenance.json` sidecar); `qa/oig_phase2_candidate_cardinality_per_clinician.csv` (person-level, gitignored)
**Model**: HHS OIG, *Improvements Are Needed To Ensure Provider Enumeration and Medicare Enrollment Data Are Accurate, Complete, and Consistent*, OEI-07-09-00440, May 2013 — "Nurse-Midwifery Remake" implementation specification, Sections 4-5 ("Analysis 1 — Candidate-location cardinality" and "Analysis 2 — Source intersection and unique-location identification")
**Investigation date**: 2026-11-10
**Status**: Phase 2 of 7 complete (Phase 1 reconciliation confirmed separately). Phases 3 (source-dependence audit), 4 (agreement-opportunity/null-model analysis) and 5 (historical verification) are explicitly out of scope here — see §4 below.

## 1. What this is, and what it builds on

The OIG remake specification builds on a "completed six-priority audit" of the 2019 Medicare
PECOS nurse-midwifery cohort (`remake_oig_07_09_00440_midwifery.R`,
`artifacts/oig_remake/*.csv`). Phase 1 reconciliation confirmed that audit reproduces the
spec's cited numbers: 5,897 enrolled, 5,643 linked (95.69%), the 595/1,015/3,523/510/254
specificity-tier split, 168,917 clinician-ZIP5 pairs, and — the spec's own stated single most
important analysis — **1,789 clinicians with a ZIP5 "shared across PECOS, NPPES, and Physician
Compare,"** of whom 573 also carry a hospital-CCN affiliation.

Phase 2 asks the question the spec poses directly: **how many of those 1,789 represent a truly
unique ZIP5 assignment, versus merely cross-source geographic concordance somewhere inside a
long candidate list?**

## 2. The bug this phase fixes

Reading the existing audit script (`remake_oig_07_09_00440_midwifery.R:2260-2339`):

1. **The "PECOS candidate ZIP set" was a tier-priority pick**, not a union:
   `eff_zip_set <- ifelse(has_direct, direct_zip5_set, group_zip5_set)`. For the 8 clinicians
   (confirmed by direct query during this work) who have *both* a direct individual-enrollment
   address and one or more group-reassignment addresses, this discarded every group ZIP
   whenever a direct ZIP existed. 7 of those 8 clinicians have exactly one direct ZIP alongside
   many more distinct group ZIPs (6 to 108) — they were being reported as "single-ZIP, Tier 1"
   when their true PECOS candidate set is 3-108 ZIP5s wide.
2. **The existing "1,789" count is a boolean any-overlap test**, not an intersection:
   `all3_zip5_corroborated <- pecos_matches_pc_zip5 & nppes_matches_pc_zip5` (line 2339), where
   `pecos_matches_pc_zip5` is true if *any* ZIP5 in PECOS's (possibly dozens-long) candidate set
   appears *anywhere* in Physician Compare's ZIP5 set, independently of whether `nppes_matches_
   pc_zip5` is driven by the *same* ZIP5. This is exactly the "chance agreement from a large
   billing-group address list" risk the specification exists to catch.

Phase 2 replaces both: `union_zip5_sets()` builds the true candidate set `P_i`, and
`classify_intersection_cardinality()` computes the actual intersection and classifies its
cardinality (both functions in `R/lib/oig_phase2_candidate_set.R`, unit-tested).

## 3. Section 4.4 validation — reproducing the existing totals, and why two don't match flatly

The spec's own §4.4 instruction is to reproduce 5,897 / 5,643 / 595 / 168,917 and "explain any
discrepancy before proceeding." Running the fixed script:

| check | expected | observed | matches |
|---|---|---|---|
| enrolled clinicians | 5,897 | 5,897 | yes |
| linked clinicians | 5,643 | 5,643 | yes |
| Tier 1 + Tier 2 (by tier label) | 595 | 595 | yes |
| group-reassignment-only distinct (NPI, ZIP5) pairs | 168,917 | 168,917 | yes |

All four reproduce exactly, **once compared against what each figure actually measures**:
"595" is Tier 1 + Tier 2 membership by tier label (tier *assignment* logic is unchanged by the
union fix — only the reported candidate-ZIP5 count for Tier 1 members changes), and "168,917"
was confirmed, by direct computation, to be the distinct-pairs count from **group-reassignment
rows only** — it never included any direct-enrollment address at all.

The union-based `P_i` then produces two new, deliberately broader metrics that are **not**
expected to equal the old ones:

| new metric | value | why it differs |
|---|---|---|
| single-ZIP5 clinicians (union-based) | 585 | 10 lower than 595 — the union correctly reclassifies the 7 of 8 both-direct-and-group clinicians (see §2) who have more candidate ZIPs than their single direct address showed |
| distinct (NPI, ZIP5) pairs (union-based) | 168,941 | 24 higher than 168,917 — from direct-address ZIP5s (18 direct-only clinicians, plus a handful of new pairs among the 8 both-direct-and-group clinicians) that the group-only baseline never counted |

**`main.ppef_addr_2019` has no street-level field** (confirmed via `DESCRIBE`: only `enrlmt_id`,
`city_name`, `zip_cd`, `state_cd`/`state_cdstr`). Spec §4.2's "distinct candidate locations using
full normalized street addresses when those fields are available" is reported as `NA` for every
clinician — not fabricated — since ZIP5/city/state is the finest PECOS granularity this source
provides.

## 4. Section 5.4 — the 1,789 reassessment, and why the three-way intersection alone is misleading

**NPPES contributes at most one ZIP5 per clinician per year** (confirmed: 257,869 rows = 257,869
distinct NPIs for `snapshot_year == "2019"`). This means the three-way intersection
`P_i ∩ N_i ∩ C_i` is **structurally empty-or-singleton** — the "two" / "three-to-five" /
"more-than-five" buckets in spec §5.2 can never be reached there, no matter how large PECOS's or
Physician Compare's own candidate sets are. Taken at face value, the three-way result looks like
total success:

| three-way intersection bucket | n (of 1,789) | % |
|---|---|---|
| exactly one | 1,780 | 99.5% |
| no common ZIP5 | 9 | 0.5% |

That 99.5% figure is real but structurally guaranteed to be high whenever a match exists at
all — it answers "does the one NPPES ZIP5 happen to also be in both PECOS's and Physician
Compare's sets," not "how much has the candidate location actually been narrowed." The honest
test of the specification's real concern — chance agreement from a large billing-group address
list — is the **pairwise PECOS-vs-Physician-Compare intersection**, since both of those sources
are genuinely multi-valued (Physician Compare alone: ~30% of NPIs have >1 distinct ZIP5 across
the 2019-06/2019-12 vintages; PECOS's Tier 4 median is 23 ZIP5s). Restricting to the same 1,789
clinicians:

| pairwise PECOS vs. Physician Compare bucket | n (of 1,789) | % |
|---|---|---|
| exactly one ZIP5 shared | 1,213 | 67.8% |
| two ZIP5s shared | 459 | 25.7% |
| three to five ZIP5s shared | 114 | 6.4% |
| more than five ZIP5s shared | 3 | 0.2% |

**Headline finding**: of the 1,789 clinicians the existing audit reports as "three-source
corroborated," only **1,213 (67.8%) are uniquely geographically resolved** — PECOS and Physician
Compare agree on exactly one ZIP5. The remaining **576 (32.2%) share multiple ZIP5s between
PECOS and Physician Compare**, consistent with the two sources' candidate lists simply
overlapping somewhere inside a large billing-group address list rather than pinpointing one
shared site. The original 1,789 is reported in the output strictly as a **cross-source geographic
concordance** result; only the 1,213 are reportable as "uniquely geographically resolved," per
the specification's own instruction in §5.4.

Two spec §5.4 sub-bullets are deferred, not fabricated — reported as `NA` with a pointer in
every output row:
- Whether Physician Compare's ZIP claim is itself derived from PECOS (`pc_derived_from_pecos`) —
  belongs to Phase 3, the source-dependence audit.
- Whether a uniquely-resolved ZIP5 corresponds to an independently verified historical clinical
  site (`independently_supported_site`) — belongs to Phase 5, historical verification.

## 5. Section 5.5 — four endpoints, never conflated

Per the specification, "verified practice site" is never used for ZIP-only evidence. Four
separate columns are carried in every person-level row:

- `unique_zip5_identified` — computed now (the three-way `exactly_one` bucket).
- `unique_street_address_identified` — `NA`; no street-level PECOS field exists (§3).
- `unique_facility_identified` — `NA`; deferred to Phase 3 (CCN/facility linkage).
- `independently_verified_clinician_facility_association` — `NA`; deferred to Phase 5.

## 6. What stays out of scope for this pass

Per the user's explicit scoping decision, Phase 2 is pure set-arithmetic (spec §4-§5 only).
Deferred to their respective phases, per the specification's own execution order (§15):
- Source-dependence classification (Class I/II/III, spec §3.3/§6) — Phase 3.
- Billing-group-size-adjusted expected agreement and the permutation null-model test — Phase 4.
- Historical practice-location verification sampling and adjudication — Phase 5.

No general-purpose function was added to `mysteryroster`. All 58 of its exported functions were
checked during planning; none duplicate this phase's set-cardinality-bucket or candidate-set
logic, but the new logic stays local to `midwifery` for now because the `mysteryroster` package
checkout was mid-flight in a concurrent session at the time this work started. Promoting
`union_zip5_sets()` / `classify_intersection_cardinality()` / `classify_sequential_transition()`
to `mysteryroster` is a reasonable follow-up once that settles.

The small ZIP/state normalizers (`norm_pecos_bigint_zip5`, `norm_str_zip5`) are duplicated from
`remake_oig_07_09_00440_midwifery.R:94-119` rather than sourced from it, for the same
concurrency reason — that script was being actively edited elsewhere while this work ran.
De-duplicate both copies into a shared `R/lib/oig_zip_normalizers.R` once that settles.
