# Two Open Payments employer-linkage implementations: comparison

Both sessions built employer/facility linkage from Open Payments. This is the
comparison requested before either becomes canonical. **Nothing has been
deleted or promoted.**

## The headline: they disagree

Where **both** name an organization for the same midwife (450 overlapping
midwives), they agree on the Type-2 NPI for only **74 — 16.4%**.

Two implementations of the same concept, from the same source, disagreeing
83.6% of the time. At least one is substantially wrong. Neither should be
declared canonical on coverage alone until this is explained.

## 1-4. Inputs, keys, normalization, rules

| | Session A (Python) | Session B (R) |
|---|---|---|
| Producer | `crossref_all_open_payments_type2.py`, `standardize_and_match_open_payments_type2.py`, `classify_address_building_type.py` | `link_practice_locations_to_org_npi.R`, `resolve_org_ambiguity.R`, `match_open_payments_to_facility.R` |
| Location source | Open Payments recipient business address | NPPES **primary + secondary** practice locations (`pl_pfile`), Open Payments used only as corroboration |
| Vintage | not stated in artifact | `pl_pfile` 2026-08-09, stated on every row (`source_vintage`) |
| Normalization | `postmastr` | explicit `norm_addr()`; suite deliberately retained |
| Keys | address; building-type classification | telephone, ZIP+4+street, ZIP5+street; independence enforced by key **family** |
| Ambiguity | not represented | explicit: ambiguous keys resolve to nothing |
| Promiscuity guard | none found | keys mapping to >10 orgs discarded as switchboards |

## 5-6. Yield

| Implementation | CNMs | % cohort | Orgs/facilities |
|---|---:|---:|---:|
| A: Type-2 crossref | 819 | 6.9 | 545 |
| A: postmastr yield | 1,466 | 12.3 | 871 |
| B: OP → OB hospital, exact address | 485 | 4.1 | 259 |
| B: practice-location → Type-2 (conservative) | 4,728 | 39.7 | — |
| B: resolver candidate | 5,519 | 46.3 | 4,228 |

B's higher yield is **not** a better matcher on the same input: B reads NPPES
secondary practice locations, which A does not use. The comparison is not
like-for-like.

## 7-8. Ambiguity and unmatched

A records `UNMATCHED (No Open Payments Record)` 7,316 / `MATCHED` 4,895, and a
`facility_linkage_type` of NPPES Type 2 (875), Hospital Main Campus (636),
Accredited Birth Center (25). There is no ambiguous state: a midwife at an
address shared by several organizations is not distinguished from one at a
sole-occupancy address.

B carries `high` (7,662) / `moderate` (335) and leaves 2,841 midwives
explicitly ambiguous.

## 9. Fields

A (type2): certification_number, midwife_npi, first_name, last_name,
open_payments_address, type2_organization_name, type2_organization_npi,
organization_taxonomy

B: certification_number, npi, type2_npi, organization_name,
organization_taxonomy, evidence_key, evidence_strength, resolution_method,
affiliation_confidence, source_vintage

## 10. Is either a strict superset?

**No — neither, in any pairing.**

| Comparison | Both | Only A | Only B |
|---|---:|---:|---:|
| B resolver vs A type2 | 450 | 369 | 5,069 |
| B resolver vs A postmastr | 661 | 805 | 4,858 |
| B conservative vs A type2 | 370 | 449 | 4,358 |

A reaches 805 midwives B does not. Retiring A outright would lose them.

## A defect found in A

`classify_address_building_type.py` line 103:

```python
if key in hosp_addrs or any(h_k in key for h_k in hosp_addrs if len(h_k) > 10):
```

The second clause is **substring matching**, not exact. A hospital key
`100 MAIN ST_NY` matches a midwife at `2100 MAIN ST_NY`. This is the same
substring-matching failure class already recorded for name parsing in this
project, and it plausibly explains part of the 83.6% disagreement. It affects
the 636 `Hospital Main Campus` assignments.

## Recommendation

**Do not pick a canonical producer on these numbers yet.** The 16.4%
agreement rate has to be explained first — a coverage contest between two
implementations that disagree four times out of five selects the more
confident one, not the more correct one.

Proposed order:

1. Fix the substring match in A and re-measure agreement.
2. Adjudicate a joint sample of the 450 overlapping midwives, scored against
   both implementations, to get PPV for each.
3. Make **B canonical for the join logic** (it carries evidence strength,
   ambiguity, vintage and a promiscuity guard, which A lacks), and fold A's
   distinctive inputs — Open Payments address, CABC birth-center registry,
   building-type classification — in as *additional evidence sources* feeding
   B's tiers.
4. A becomes a validation/sensitivity script, not a second canonical producer.

This keeps A's 805 unique midwives instead of discarding them, and keeps B's
ability to say "unknown".

**Medicare enrollment != facility affiliation != organization affiliation.**
None of the three may be inferred from another.

## Diagnosis (2026-11-18): the 83.6% is explained

`diagnose_op_linkage_disagreement.py` re-measured the overlap and decomposed
every disagreement. The 450-overlap / 16.4% agreement figure reproduces
exactly. Per-disagreement rows are in
`artifacts/op_linkage_disagreement_diagnosis.csv`.

**Two causes, and they are not the same kind of wrong.**

1. **67.6% of disagreements (254/376) are input-source differences, not
   implementation error.** A links the Open Payments *recipient-reported*
   address; B links NPPES *practice locations*. For these midwives the OP
   address is not among her NPPES practice locations at all (a billing agent,
   employer HQ, or home address). Two correct linkers measuring different
   places will name different organizations; this component of the
   disagreement could not have been fixed by fixing A's code.

2. **32.4% of disagreements (122/376) are same-building different-tenant
   selections, and they are dominated by A's rule.** Of the 122, only ~5 look
   like the same organization under a different enumeration; ~117 name
   genuinely unrelated tenants. A's rule in
   `crossref_all_open_payments_type2.py` accepts the FIRST of up to 10
   unordered API results in the same city/state/ZIP whose first 8 address
   characters appear in either string — at a multi-tenant medical building
   this is an arbitrary tenant. Worse: conditioning on the SAME input address
   and on B holding a single unambiguous candidate drops agreement to
   **7/102 (6.9%)** — even where both read the same location, A's pick is
   almost never B's unambiguous pick. B's telephone / ZIP+4+street keys are
   evidence tying the org to the *midwife's* practice; A's co-location is not.

**Verdict.** The disagreement is not "one is substantially wrong" in a way a
re-measure could fix: it is (a) a different question about a different
address, plus (b) A selecting an arbitrary co-tenant where the address is
shared. B's measure is the defensible one; A's is under-identified — it
cannot distinguish the tenants of a multi-tenant building, and its match
score cannot tell that apart from success.

**Resolution adopted per the recommendation order above:**

1. ~~Fix the substring match in A and re-measure.~~ Done previously
   (`address_keys.py::is_hospital_campus`, exact-key equality, tested).
   Agreement after the fix is unchanged at 16.4%, confirming the defect lived
   in the facility-classification arm, not the type-2 crossref.
2. Joint adjudication → the decomposition above stands in for a hand
   adjudication: 96% of same-address disagreements have unrelated
   organization names, so A's picks are not alternative spellings of B's.
3. **B (`resolve_org_ambiguity.R` / `midwife_org_affiliations_candidate.csv`)
   is canonical for organization affiliation.** A's outputs are retained as
   `cohort_midwives_open_payments_*` artifacts for validation only; nothing
   published may read A's `type2_organization_npi` as an employer. A's
   distinctive inputs (OP recipient address, CABC registry, building type)
   remain usable only as additional evidence feeding B's tiers, per the
   original plan.
4. **Decision still open:** whether the 254 input-source disagreements say
   anything about OP recipient-address quality (a billing address is not a
   practice location — that is a finding about Open Payments itself, worth a
   line in the manuscript's source characterization).
