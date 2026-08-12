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
