# Technical Appendix: Transparency in Coverage Provider–Billing Relationships

**Status:** pilot method and evidentiary specification

**Date:** September 2026

**Implementation:** [`accessmrf_01_colorado_cohort.R`](../accessmrf_01_colorado_cohort.R) through [`accessmrf_08_permutation_curve.py`](../accessmrf_08_permutation_curve.py)

## 1. Purpose and estimand

The Transparency in Coverage (TiC) work has two deliberately separate projects.

Project A constructs an observed graph between clinician NPIs and the billing
identifiers that appear with them in payer machine-readable-file provider
groups. Its evidentiary unit is narrow: *NPI X appeared in payer Y's file,
linked to billing identifier Z in source month M.* This supports descriptive
relationship mapping without assuming that the payer sample is complete.

Project B asks whether a clinician is commercially accessible through a payer.
That interpretation is not currently identified. Appearance does not prove
employment, ownership, accepting-new-patient status, or even plan-specific
participation; nonappearance is not evidence of exclusion. Market-share
coverage is therefore context, not an inferential denominator.

## 2. Cohort and geography

The Colorado pilot begins with 406 active-primary Colorado certificants from
the canonical AMCB-to-NPI linkage. Geography comes from NPPES, not TiC. A TiC
provider group contains identifiers but no clinician address, and state tokens
in filenames describe plan products inconsistently. For example, a Kaiser file
labelled Colorado contains clinicians from several Kaiser regions. No script
assigns a provider to a state from an MRF filename.

The payer-market table is built before acquisition from the CMS Medical Loss
Ratio Public Use File. It records attempted and successfully parsed market
share separately. A failed acquisition cannot count as observed coverage.

## 3. Acquisition and storage controls

`MIDWIFERY_MRF_ROOT` is required and has no default. The archive root must
exist and be writable; the pipeline never falls back to an internal disk.
Between work units it rechecks the mount and enforces row, temporary-byte and
free-space limits. Raw payloads and reference archives live outside Git. Each
file manifest records source identity, observed source month, byte size and
SHA-256 digest.

The extractor handles both TiC layouts:

- top-level `provider_references`, which may include network and business names;
- inline `provider_groups` nested under negotiated rates, which do not carry
  those names.

Only provider-group structures are retained. Negotiated prices are outside the
scope of this pipeline. Large UHC files are sampled with HTTP range requests
that end after the provider-reference block rather than downloading the rate
body.

## 4. Relationship grain and deduplication

The first pilot wrote one row per occurrence and produced a 59 GB intermediate.
The replacement extractor deduplicates during parsing and normalizes repeated
metadata. The durable model is:

```text
fact_relationship
  npi | billing_id_type_raw | billing_id_value_raw | payer_group
  | network_name | source_month | billing_id_class
  | nppes_entity_type | billing_npi_is_member
  | provider_group_member_count_min | provider_group_member_count_max
  | classification_reason

dim_tin
  billing_id_type_raw | billing_id_value_raw | business_name

dim_file
  source_file_id | file_stem | payer_group | bytes | sha256 | shape
```

Parquet output is partitioned by payer. Counts of observations, distinct stored
rows, unique NPI–identifier pairs and distinct NPIs remain separate so source
duplication is visible rather than silently interpreted as evidence strength.

## 5. Billing-identifier classification

TiC permits `tin.type` to be either `ein` or `npi`. NPPES Entity Type Code is
the authority when the raw type is `npi`; provider-group size is supporting
evidence only.

| Raw identifier | Evidence | Classification |
|---|---|---|
| `ein` | schema value | `ein` |
| `npi` | NPPES Entity Type 2 | `organization_npi` |
| `npi` | Type 1 and sole group member | `self_billing_individual` |
| `npi` | Type 1 and any other pattern | `ambiguous_individual_npi_anchor` |
| `npi` | absent/unresolvable in NPPES | `unresolved_npi` |

A billing relationship does not establish employment, ownership, independent
practice, or health-system affiliation. `business_name` is also not a reliable
organization label: delegated-network and payer names occur in that field.

## 6. Pilot results

Three structurally different payers produced 128.9 million raw occurrences but
1,014,920 unique NPI–identifier pairs in 21.65 MB of Parquet. Duplication varied
sharply: 3.1× for Kaiser, 764.3× for Anthem and 1.6× for Cigna. Within-payer
marginal discovery flattened in the observed samples, but that does not prove
the national or market-wide graph is saturated.

UHC saturation is evaluated under repeated random file permutations. Reporting
the median and 5th–95th percentile cumulative discovery at fixed checkpoints
prevents one convenient file ordering from determining the apparent curve.

## 7. Retractions and limitations

The statement that “90.5% of TINs have a single NPI” is retracted. The original
four-file pilot collapsed `tin.type=npi` self-billing identifiers with EINs,
making the organization-size distribution invalid. Superseded artifacts remain
under [`artifacts/accessmrf/`](../artifacts/accessmrf/README.md) only to document
how the defect was found; they must not be cited as organization results.

Additional limits:

- the AccessMRF API exposes only the current month; requested months are
  validated against each file's observed `fileDate`;
- state targeting is payer-specific and cannot be inferred with one regex;
- network counts are incomplete for inline provider-group files;
- prospective first/last observation begins in March 2025 and does not support
  retrospective consolidation claims;
- Project B remains experimental until the meaning of provider appearance is
  validated independently.

## 8. Reproduction and checks

Run the pipeline in the numbered order documented in
[`README_accessmrf.md`](../README_accessmrf.md). Month-labelling behavior is
locked by [`tests/test_accessmrf_month_labelling.py`](../tests/test_accessmrf_month_labelling.py).
Raw archives, NPPES inputs and MLR inputs are reacquired outside Git; tracked
manifests and provenance sidecars identify the exact inputs used.
