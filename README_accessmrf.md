# AccessMRF → provider ↔ billing-entity graph

Extracts clinician-to-billing-entity relationships from Transparency in
Coverage (TiC) machine-readable files, via the [accessmrf.com](https://www.accessmrf.com)
index of US commercial payers.

**What this is:** a national **provider → billing/contracting entity graph**.
**What this is not:** a measure of insurance access, network participation,
employment, or ownership. See [Two projects](#two-projects).

---

## Quick start

```sh
# The archive root is REQUIRED. There is no default (see Configuration).
export MIDWIFERY_MRF_ROOT="/Volumes/<volume>/midwifery/accessmrf"

python3 accessmrf_config.py                    # verify root is writable
Rscript  accessmrf_01_colorado_cohort.R        # cohort
Rscript  accessmrf_02_payer_market.R           # market denominator
python3  accessmrf_03_pull_provider_refs.py --slug <slug> \
         --payer-group "<name>" --stem-pattern '^CO_'
python3  accessmrf_06_build_relationships.py --reparse --payer-dir <slug>
```

## Pipeline

| Step | Script | Does |
|---|---|---|
| — | `accessmrf_config.py` | Archive root, fail-closed; resource guards |
| 1 | `accessmrf_01_colorado_cohort.R` | Target cohort (406 Colorado CNMs) |
| 2 | `accessmrf_02_payer_market.R` | Market denominator from CMS MLR |
| 3 | `accessmrf_03_pull_provider_refs.py` | Acquire + stream-parse provider blocks |
| 4 | `accessmrf_04_saturation.R` | Per-payer saturation table |
| 5 | `accessmrf_05_duplication_audit.py` | File/URL/stem duplication, metadata only |
| 6 | `accessmrf_06_build_relationships.py` | Deduplicated relationship tables (Parquet) |
| 7 | `accessmrf_07_uhc_sample.py` | Stratified sample of a large payer |
| 8 | `accessmrf_08_permutation_curve.py` | Order-independent saturation curve |

Tests: `tests/test_accessmrf_month_labelling.py`.

Method and interpretation details:
[`docs/TECHNICAL_APPENDIX_ACCESSMRF.md`](docs/TECHNICAL_APPENDIX_ACCESSMRF.md).

## Two projects

**Project A — clinician NPI ↔ billing/contracting entity.** Viable now. Needs
no market-completeness assumption. The unit of evidence is *this NPI appears in
this payer's MRF provider groups tied to this billing identifier*.

**Project B — commercial insurance access.** Experimental and currently
blocked on semantics. The endpoint is `CNM observed in payer MRF provider
groups`. Absence is **not** evidence of non-participation. A Kaiser file named
`KFHP_CO-COMMERCIAL` contains providers from every Kaiser region, so file-level
geography does not imply provider geography.

## Output schema

```
fact_relationship   npi | billing_id_type_raw | billing_id_value_raw | payer_group
                    | network_name | source_month | billing_id_class
                    | nppes_entity_type | billing_npi_is_member
                    | provider_group_member_count_min/_max | classification_reason
dim_tin             billing_id_type_raw | billing_id_value_raw | business_name
dim_file            source_file_id | file_stem | payer_group | bytes | sha256 | shape
```

Partitioned `parquet/payer=<slug>/`. Raw payloads live under `raw/`, never in git.

### Billing identifier classification

TiC allows `tin.type` to be `ein` **or** `npi`, and payers differ completely.
NPPES **Entity Type Code** is the authority; member count is evidence only.

```
raw type = ein                                     → ein
raw type = npi, NPPES Entity Type 2                → organization_npi
raw type = npi, Type 1, billing NPI = sole member  → self_billing_individual
raw type = npi, Type 1, anything else              → ambiguous_individual_npi_anchor
raw type = npi, unresolvable in NPPES              → unresolved_npi
```

A billing identifier says who **bills**. It does not establish employment,
ownership, independent practice, or health-system affiliation.

## Results to date (Colorado pilot, 2026-09)

| | Kaiser | Anthem | Cigna |
|---|---:|---:|---:|
| raw occurrences | 2,512,500 | 126,302,680 | 63,613 |
| distinct stored rows | 2,392,207 | 7,438,568 | 61,603 |
| unique npi-identifier pairs | 808,979 | 165,250 | 40,691 |
| duplication factor (pairs) | 3.1× | **764.3×** | 1.6× |
| distinct NPIs | 445,370 | 58,925 | 32,683 |
| distinct EINs | 22,264 | **0** | 5,343 |
| distinct organization NPIs | 7,576 | 7,261 | 4 |
| Parquet | 11.68 MB | 9.52 MB | 0.45 MB |

**128.9M raw occurrences → 1,014,920 unique pairs in 21.65 MB.** One extractor,
no payer-specific hacks, three structurally different payers.

Marginal discovery flattens sharply *within* a payer: Anthem's 17th file added
11M occurrences and **3** new relationships; Cigna's 2nd added 21,745
occurrences and **46**.

## Configuration

`MIDWIFERY_MRF_ROOT` is **required — there is no default**. macOS appends a
suffix when a volume mounts more than once (`/Volumes/X` → `X 1` → `X 2`), so a
hardcoded path silently goes stale and writes to a dead mount point. This cost
one run 3h27m of CPU against a path it could no longer write to.

`mrf_root()` fails closed if unset or unwritable, and never falls back to the
internal disk. `verify_root_alive()` re-checks between work units so a mid-run
remount fails in seconds.

Guards: `MAX_ROWS_PER_FILE`, `MAX_TEMP_BYTES`, `MIN_FREE_BYTES` (checked before
writing).

## Known limitations

- **The API exposes only the current month.** `?month=`, `?selectedMonth=`,
  `?date=` and `?fileDate=` all return HTTP 200 with the current month.
  Filtering is client-side on each file's observed `fileDate`; requesting an
  unavailable month yields zero files and an error, never mislabelled data.
  Locked by `tests/test_accessmrf_month_labelling.py`.
- **State targeting is per-payer.** Kaiser `KFHP_CO-COMMERCIAL`, Anthem
  `CO_CBPLMED0000`, Cigna `..._colorado-cpop_...`. No shared convention; UHC
  has no state token at all. A loose regex matched `TOBACCO-CO-INC`.
- **`network_name` and `business_name` exist only in the `provider_references`
  shape.** Payers using inline `provider_groups` have neither, so
  `payer_count_for_npi` is the robust participation measure and
  `network_count_for_npi` needs a completeness flag.
- **Panel depth starts 2025-03.** Retrospective consolidation claims are not
  supportable; prospective `first_seen`/`last_seen` tracking is.
- **`business_name` is not reliably a provider organisation** — some values are
  payers (`DENTAQUEST CO`, `CARESOURCE GEORGIA`), likely delegated networks.

## Retractions

See `artifacts/accessmrf/README.md`. Chiefly: the **"90.5% of TINs have a
single NPI"** figure is retracted — an artifact of conflating `tin.type=npi`
self-billing identifiers with EINs before `tin_type` was recorded. Do not cite
it.

## Data handling

Raw MRF payloads, NPPES and MLR archives live under `MIDWIFERY_MRF_ROOT`,
gitignored, sha256-recorded in manifests. Only scripts, small artifacts and
documentation belong in the repository.
