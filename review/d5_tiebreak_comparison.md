# D5 — Open Payments linkage: pipeline and tie-break comparison

Companion to `docs/OPEN_PAYMENTS_LINKAGE_COMPARISON.md` (the original
side-by-side) and `artifacts/op_linkage_disagreement_diagnosis.csv` (the
per-disagreement ledger, person-level, untracked). This file records the
factorial decomposition and the tie-break analysis required by the spec.

## What "83.6% disagreement" means

Unit of comparison: **midwives for whom BOTH implementations name an
organization** (the 450-midwife overlap). Numerator: midwives whose two
implementations name *different* Type-2 NPIs (376). Denominator: 450.
376/450 = **83.6% disagreement; 16.4% agreement (74/450)**.

It is NOT a record-level or row-level disagreement rate, and NOT a
coverage difference — coverage differences are reported separately in the
comparison doc's section 10 (only-A 369 / only-B 5,069 vs the B resolver).

## The two pipelines

| | A (Python) | B (R, canonical) |
|---|---|---|
| Producers | `crossref_all_open_payments_type2.py`, `standardize_and_match_open_payments_type2.py`, `crossref_open_payments_to_type2_npi.py` | `link_practice_locations_to_org_npi.R`, `resolve_org_ambiguity.R`, `match_open_payments_to_facility.R`, `build_organization_affiliation_resolver.R` |
| Location input | Open Payments recipient-reported address | NPPES primary + secondary practice locations (`pl_pfile`, vintage-stamped per row); OP address used only as corroboration |
| Candidate generation | NPPES Type-2 org search by address prefix (first 8 chars) within same city/state/ZIP, ≤10 unordered API results | telephone, ZIP+4+street, ZIP5+street key families; independence enforced by key family |
| Tie-break | **first of unordered API results** — no determinism guarantee, no ambiguity state | explicit ambiguity: ambiguous keys resolve to nothing; promiscuity guard discards keys mapping to >10 orgs (switchboards) |
| Ambiguity representation | none — a multi-tenant address pick is indistinguishable from a sole-occupancy pick | explicit: `high`/`moderate` confidence, 2,841 midwives left explicitly ambiguous |
| Output | `cohort_midwives_open_payments_type2_organizations{,_full}.csv` | `midwife_org_affiliations_candidate.csv` → `organization_affiliation_resolved.csv` |

## Factorial decomposition of the 83.6%

| Factor | Effect | Evidence |
|---|---|---|
| A. Same input, different algorithm | dominant residual cause | conditioning on SAME input address AND B unambiguous: agreement **7/102 = 6.9%** — A's pick is almost never the defensible one even where both read the same place |
| B. Different input sources, same algorithm class | largest single component | 254/376 (67.6%) disagreements have `op_addr_is_nppes_practice_addr = False` — the OP billing address is not among her NPPES practice locations at all |
| C. Same candidates, different tie-break | subsumed by A | where inputs coincide, A's unordered-first-pick vs B's evidence-keyed pick is exactly the tie-break difference |
| D. Same keys, different normalization | ruled out | A's normalization is `postmastr`; B's is explicit `norm_addr()`. The 83.6% reproduces under the diagnosis pipeline which normalizes both sides identically for comparison; name-vs-name agreement was separately shown not to be a normalization artifact in the D6 analysis (43.1% name-match vs 43.4% PAC-id) |
| E. Different source vintages | not a factor | both arms read the same OP release and NPPES pfile cut; B stamps `source_vintage` per row |

## Tie-break fixtures (spec 4.5) — behavior on deliberately ambiguous inputs

| Fixture | A behavior | B behavior |
|---|---|---|
| Two orgs at same address | picks first unordered API result — arbitrary tenant, recorded as success | both candidates retained; pair marked ambiguous unless a key family singles one out |
| Same name, different NPIs | n/a (address-keyed) | taxonomy-exclusion + key-family evidence required; unresolved stays unresolved |
| Exact NPI vs stronger fuzzy-name | n/a | NPPES Type-2 identity is an identifier, not a name score — no fuzzy promotion path exists |
| Former name | n/a | `nppes_name_changed_since_match` flag carried on the frozen linkage, not re-scored |
| Repeated payments over years | collapsed to one address per midwife upstream | `first_evidence`/`last_evidence` spans carried per pair |
| Missing identifiers / partial addresses | falls through to prefix match on whatever exists | missing key components simply do not fire that key family; no fallback to weaker evidence |
| Input-file ordering | **API result order is not a data property** — the same midwife can resolve to a different tenant across runs | deterministic: sorted keys, explicit ambiguity, `stopifnot`-style partition checks in tests |

The critical property: **an unresolved tie must not become a confident
match because a sort order changed.** A violates this by construction (its
"match" is positional in an unordered API response); B satisfies it by
making ambiguity a first-class output.

## Canonical implementation (spec 4.6) — ruling of record

**B is canonical** for organization affiliation
(`resolve_org_ambiguity.R` / `midwife_org_affiliations_candidate.csv`,
resolved through `build_organization_affiliation_resolver.R`). A's outputs
are validation-only; nothing published may read A's
`type2_organization_npi` as an employer. A's distinctive inputs (OP
recipient address, CABC registry, building-type classification) remain
usable only as additional evidence feeding B's tiers — which is exactly how
`open_payments_org` enters the resolver: as one arm whose pairs land in the
named weak class `open_payments_only` unless corroborated by another arm's
normalized-name agreement.

Enforcement added in this PR: `crossref_open_payments_to_type2_npi.py`
(the remaining unmarked A producer) now carries the same
VALIDATION-ONLY header as its siblings, and
`analyze_open_payments_clinical_depth.R` documents that the
`op_profile_match` column it carries is A-arm validation data used only as
a presence flag (`has_op_profile`), never as an employer identity.

## Downstream scientific effects (spec 4.7)

See `review/d5_downstream_impact.csv`. Headline: no published estimate
reads A's employer pick; the resolver's `open_payments_only` class is a
named weak-evidence bucket whose counts shift if A's arm is ever dropped —
that sensitivity is documented rather than silently normalized.

## Open items (owner-level, not engineering)

1. Whether the 254 input-source disagreements are written up as an Open
   Payments recipient-address-quality finding (a billing address is not a
   practice location) — a manuscript decision.
2. Whether `open_payments_only`-class pairs should carry an explicit
   "tenant-ambiguous" caveat wherever the affiliation table is published.
