# Technical Appendix: CMS National Provider Directory (NDH) Lookup

**Status:** complete. Both pipelines have run full-cohort and agree: the
per-NPI live-gateway harvest and the bulk-export cross-check independently
found the identical 16,361/16,775 (97.5%) figure (s6, s7.4).

**Date:** October 2026

**Implementation:**
[`harvest_cms_national_provider_directory.py`](../harvest_cms_national_provider_directory.py)
(per-NPI, live gateway),
[`download_cms_ndh_bulk.py`](../download_cms_ndh_bulk.py) +
[`clean_cms_ndh_bulk.py`](../clean_cms_ndh_bulk.py) (bulk release)

## 1. Purpose and estimand

CMS runs a public, read-only, no-auth, CORS-enabled FHIR R4 gateway at
`https://directory.cms.gov/fhir` — the National Directory of Healthcare
Providers and Services (NDH). Its `CapabilityStatement` describes it as a
gateway that blends NPPES/PECOS enrollment data with payer-reported network
data (an undocumented `base-ext-cms_aligned_with_data_network` extension
flags this); it is not itself one of the individual Medicare
Advantage/Medicaid/CHIP payer Plan-Net endpoints the CMS Interoperability rule
requires each payer to publish separately.

This was evaluated as a substitute starting point for a planned five-payer
integration (UHC, Humana, Elevance, Centene, Aetna) after a live test showed
one NPI query against this single gateway returning richer data than a
specialty-filtered query against UHC's own public endpoint alone. The
estimand is narrow and corroborating, same as every other Tier F source in
this project: *this NPI's NDH record carries these addresses, this
taxonomy/credential, and this accepting-new-patients signal, as of this
retrieval.* It is not a measure of insurance network participation (that
remains AccessMRF's job, see
[`TECHNICAL_APPENDIX_ACCESSMRF.md`](TECHNICAL_APPENDIX_ACCESSMRF.md)) and it
is not a replacement for the AMCB-to-NPPES identity linkage.

## 2. Why this gateway over the five payers

CMS's Interoperability and Patient Access rule (CMS-9115-F) has required a
Da Vinci PDex Plan-Net FHIR Provider Directory API per payer since January
2021, but there is no CMS-maintained master list of those per-payer endpoint
base URLs yet — centralized publication is only proposed (CMS-4208-F2,
effective October 2026). Confirming each payer's endpoint by hand turned up:

| Payer | Base URL found | Status |
|---|---|---|
| UnitedHealthcare | `https://flex.optum.com/fhirpublic/R4/` | confirmed live |
| Centene | `https://iopc-pd.api.centene.com/iopc/pd/fhir/providerdirectory` | confirmed live |
| Elevance/Anthem | `https://totalview.healthos.elevancehealth.com/resources/unregistered/api/v1/fhir/cms_mandate/` | base only; `/metadata` returned 403, likely needs a plan-specific path segment |
| Humana | `developers.humana.com` | JS-rendered portal; exact base URL not extracted |
| Aetna/CVS | `apif1.aetna.com/fhir/v1/providerdirectory` (sandbox) | production no-auth endpoint unconfirmed |

Against UHC's confirmed endpoint, `PractitionerRole?specialty=340000000X`
(an incorrect guess at the CNM taxonomy code) returned zero results — not a
data-completeness problem, a wrong code. The correct NUCC code is
`367A00000X` ("Advanced Practice Midwife"), confirmed below.

A single query against `directory.cms.gov/fhir` by NPI returned, for a known
cohort member (NPI `1629453816`, Hawa Al-Hassan, CNM2738): 15 work addresses
and 7 phone numbers across NJ, state license numbers for both NJ and WA, a
Medicare-enrollment flag, an HHS exclusion-list flag, and 9 `PractitionerRole`
entries each carrying `acceptingPatients: "newpt"` ("accepting new and
existing patients") against a distinct organization. Given one gateway
already returns this without per-payer endpoint discovery, the five-payer
table above is kept only as a fallback/cross-check if NDH coverage turns out
to have gaps, not as the primary integration.

## 3. Mechanism, traced through one NPI

Example: NPI `1003009010`, a Milwaukee CNM in the cohort.

1. **Input.** The script reads `artifacts/amcb_npi_linkage_FROZEN.csv`, keeps
   rows where `cohort_member == TRUE` and `npi` is non-empty (16,775 as of
   this cohort vintage), and dedupes to a sorted NPI list.
2. **Two requests per NPI:**
   ```
   https://directory.cms.gov/fhir/Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|1003009010
   https://directory.cms.gov/fhir/PractitionerRole?practitioner=Practitioner-1003009010
   ```
   The first returns the person (name, addresses, qualifications). The
   second returns one entry per organization/location affiliation — four for
   this NPI.
3. **The raw bundle cache IS the resume checkpoint.** Both bundles are
   written verbatim to
   `artifacts/cms_ndh_raw/1003009010.{practitioner,practitionerrole}.json`
   before anything is parsed. `harvest_one()` checks whether both files
   already exist and skips the network call entirely if so — there is no
   separate checkpoint file.
4. **Parsing flattens one bundle into one row.** From the raw qualification
   array:
   ```json
   {"code":{"coding":[{"system":"http://nucc.org/provider-taxonomy","code":"367A00000X","display":"Advanced Practice Midwife"}]}}
   {"identifier":[{"value":"3276-033"}], ...state license, issuer Organization-State-WI...}
   {"code":{"text":"APNP"}}
   ```
   `parse_practitioner()` walks the list once: any
   `nucc.org/provider-taxonomy` coding joins into `ndh_taxonomies`; any
   `issuer` pointing at `Organization-State-<ST>` becomes an
   `ndh_state_licenses` entry (`"WI:3276-033"`); any `FaCeT-credentialCS`
   coding becomes `ndh_credential`. Addresses and phones get the same
   flatten-and-join treatment into `ndh_addresses` / `ndh_phones`.
5. **Roles drive the appointment-availability flag.** `parse_roles()` scans
   the role entries for the `base-ext-newpatients` extension with coding
   code `newpt`, collecting which organization references carry it.
   `ndh_accepting_new_patients` and `ndh_n_orgs_accepting` come from this
   scan.
6. **Output.** One row per NPI in `artifacts/cms_ndh_midwives.csv`, plus a
   single `.provenance.json` sidecar recording the endpoint, cohort file
   SHA-256, retrieval timestamp, and found/accepting counts for the whole
   run — not per row, matching how this project's other harvesters record
   provenance (`tools/provenance.py`).

## 4. Resume correctness

The first draft of the flatten-to-CSV step called `harvest_one()` for every
cohort NPI unconditionally, so a bounded test run (e.g. 5 NPIs) silently
triggered network fetches for the other ~16,770 during its own "rebuild the
CSV" pass — defeating the bound entirely. Caught live, mid-run, by a test
that took far longer than its requested batch size implied. Fixed by giving
`harvest_one()` an `allow_fetch` flag: the harvest loop fetches, the
CSV-flatten pass only reads what is already cached
(`allow_fetch=False`) and returns `None` for anything not yet on disk. A
bounded batch now produces a CSV covering exactly what has been harvested so
far; a later run extends it. No separate merge step is needed because the
flatten pass always re-derives the CSV from the cache directory.

## 5. Known data-quality caveats

- **`ndh_credential` is not authoritative for "is this person a CNM."** It
  is whatever `FaCeT-credentialCS` coding happens to appear last in the
  qualification list — sometimes `RN`, sometimes `CNM`, for midwives who
  hold both. `ndh_taxonomies` (NUCC code `367A00000X`) is the reliable
  midwife signal; `ndh_credential` is informational only and is not used in
  any matching or filtering logic.
- **`cms_aligned_with_data_network` is undocumented in the public
  CapabilityStatement.** It is treated here as a hint that payer network
  data is blended in, not a guarantee of which payers or how current.
- **`ndh_hhs_exclusion_list` must never be used — verified, not assumed.**
  153 of 16,775 cohort NPIs carry this flag. Checked against the real LEIE
  (downloaded fresh from `oig.hhs.gov/exclusions/downloadables/UPDATED.csv`,
  84,093 records, by exact NPI match): only **10 (6.5%)** actually appear in
  the current public exclusion list. The other **143 (93.5%) are false
  positives** against the authoritative source. The 10 that do match look
  genuine (real `EXCLTYPE`/`EXCLDATE`, specialty "NURSE/NURSES AIDE") but
  even one of those shows a last-name mismatch against NDH (LEIE: "Fletcher,
  Christine"; NDH: "Cates, Christine A", same NPI `1366694564`) — plausibly a
  maiden/married name difference rather than a data error, but a reason to
  check name history before treating any of the 10 as settled. This field is
  not a lower bound the way `ndh_accepting_new_patients` is — a lower bound
  assumes false positives are rare; at 93.5% they are the norm. Not wired
  into Table 1 or anything else, and no other NDH field's absence-handling
  was changed because of this finding — it is specific to this one
  extension.

  **The 143 false positives, investigated further (checked, not left as an
  unexplained number):**
  - 10 share an exact full name with a genuine LEIE entry, but that entry
    carries no NPI (`NPI=0`) and is a common name (Denise Smith, Kimberly
    Hill, Mary Malone, Eva Garcia, Shannon Johnson, among others) —
    read as a coincidental collision with a different real person, not this
    cohort member, since there is no NPI to confirm identity either way.
  - 0 of the remaining 133 appear in any of OIG's monthly reinstatement
    supplements from 01-2025 through 09-2026 (`.../downloadables/<YYYY>/<ym>rein.csv`),
    ruling out "recently reinstated, NDH has not caught up" within that
    21-month window.
  - 43 of those 133 do not share even a last name with anyone in the full
    84,093-row LEIE — no LEIE connection of any kind, coincidental or
    otherwise.

  **Conclusion: the dominant cause is undetermined from public data.** Not
  stale reinstatement, and for a large share not even a name collision. The
  remaining candidates — a different, non-public CMS exclusion source (e.g.
  the Medicare Preclusion List, which CMS does not publish the way OIG
  publishes LEIE) or an internal NDH pipeline defect — are not
  independently checkable with what is publicly available. Stated as a
  limit of this investigation, not resolved further than the evidence
  supports.
- **`ndh_n_addresses` is a group's full location roster, not a personal
  practice-site count.** Traced directly for NPI `1801382510` (23 addresses,
  no corruption, name internally consistent): her 6 `PractitionerRole`
  entries resolve to 6 organizations, three of which are all
  "PERMANENTE MEDICAL GROUP INC" sub-entities carrying 10, 14, and 15
  locations *each* on a single role. `PractitionerRole.location` is the
  employing/credentialing organization's entire location list, not the
  subset that individual actually staffs — a clinician affiliated with a
  handful of large multi-site groups (Kaiser Permanente in this case; it was
  also the single largest employer in this project's own worksite
  affiliation data, see the main README) can accumulate dozens of addresses
  this way with zero data-quality issue. This is why 1,010 of 15,941
  national-sweep rows have >10 addresses while only 2 are confirmed defects
  (s8) — the two are not the same population.
- **Absence from NDH is not evidence of anything** — same caveat this
  project applies to every Tier F source. An NPI not found in NDH is simply
  not found; it is not evidence of inactive status.
- **The bulk export and the live gateway code the same facts under different
  FHIR system URIs.** Confirmed by inspection, not assumption — see s7.3.
  `parse_practitioner()` accepts both; anything reading raw bulk NDJSON some
  other way needs to as well, or it will silently find nothing.

## 6. First full-cohort run

A bounded 5-NPI test (on top of 139 NPIs already cached from an earlier
interrupted run) found 140/144 (97%) of cohort NPIs present in NDH, 94/144
with at least one organization affiliation flagged
`acceptingPatients: newpt`. The full run against all 16,775 cohort NPIs
completed 2026-10-23, 12:06:42–16:23:32 (4h17m at
`CMS_NDH_DELAY=0.25`s between requests, zero errors):
**16,361/16,775 (97.5%) found in NDH, 9,760 with at least one organization
accepting new patients.** Output: `artifacts/cms_ndh_midwives.csv`
(16,775 rows) + matching `.provenance.json`.

The 16,361-found figure is identical to the bulk-export cross-check's
independent count (s7.4) — two different acquisition methods against the
same underlying CMS snapshot landing on the same number, which is the
strongest evidence available that neither pipeline has a systematic bug in
how it resolves "is this NPI present in NDH."

## 7. Bulk NDJSON downloads

### 7.1 What they are

`https://directory.cms.gov/downloads` publishes the entire NDH as a periodic
export: one newline-delimited JSON file per FHIR resource type,
Zstandard-compressed, refreshed on CMS's own schedule (this release:
generated `2026-10-14`, the same vintage as the live gateway's
`meta.lastUpdated` stamps seen in section 3 — the two sources describe the
same underlying snapshot, not two different datasets). Per `manifest.json`:

| File | Compressed | Original |
|---|---|---|
| `01-Organization.ndjson.zst` | 288,093,973 B | 3,865,427,956 B |
| `02-Location.ndjson.zst` | 206,550,534 B | 1,508,867,656 B |
| `03-Endpoint.ndjson.zst` | 48,969,170 B | 931,313,793 B |
| `04-HealthcareService.ndjson.zst` | 1,177,469 B | 20,386,250 B |
| `05-InsurancePlan.ndjson.zst` | 324,067 B | 2,690,629 B |
| `06-Practitioner.ndjson.zst` | 869,137,712 B | 16,929,993,481 B |
| `07-PractitionerRole.ndjson.zst` | 901,023,239 B | 11,013,187,007 B |
| `08-OrganizationAffiliation.ndjson.zst` | 18,334,328 B | 241,623,864 B |

**No authentication required, and it is scriptable.** `GET
https://directory.cms.gov/downloads/<file>` 302-redirects to a freshly
presigned S3 URL on every request — verified live with a plain
`curl -sL`, no cookies or browser session. A script can therefore treat
`directory.cms.gov/downloads/<file>` as a stable URL and just follow the
redirect; no token management of its own is needed.

**Caveat on the manifest's own claims:** the downloads page states the
manifest "describes release contents, checksums, and schema versions." The
actual `manifest.json` carries only `compressed_bytes`, `original_bytes`,
`compression_ratio_pct` per file plus `generated_at` and totals — no
checksums and no schema version field were present in the fetched file.
Documented here rather than repeated uncritically.

**Why this project uses them at all, not just the live gateway.**
`06-Practitioner.ndjson.zst` + `07-PractitionerRole.ndjson.zst` contain the
full national dataset the per-NPI harvester queries one NPI at a time
(16,775 NPIs × 2 requests, ~4–5 hours). A bulk download + local filter does
the same job in under three minutes of processing once downloaded (s7.4),
and — unlike the per-NPI approach, which can only confirm or enrich NPIs
already in the AMCB-to-NPPES linkage — a filter over the *full*
`Practitioner` file surfaces NDH-registered CNMs this project's linkage has
not matched to an AMCB certificant at all. The two methods are kept as
independent cross-checks of each other (same discipline as the WA BON
script, s3 of this appendix's commit history): the per-NPI run already in
flight was not interrupted for this, since discarding real progress for no
benefit on that pass would be pure waste.

### 7.2 How this project uses them — the two-script pipeline

Internal disk had only 20 GB free when this was built; the two relevant
files alone decompress to ~28 GB. The pipeline therefore never writes
decompressed NDJSON to disk at all:

1. **`download_cms_ndh_bulk.py`** — fetches the manifest fresh, downloads
   each `.zst` to a temp `.part` path under `$CMS_NDH_BULK_ROOT` (required,
   no default, same fail-closed discipline as `accessmrf_config.py` — a
   stale `/Volumes/<name>` path after a remount must error, not silently
   write into whatever now occupies that mountpoint), verifies byte size
   against the manifest *and* runs `zstd -t` (frame integrity — the
   strongest check available, since the manifest carries no checksum per
   s7.1), then atomically renames into place. Resumable: anything already
   on disk that still matches size+integrity is skipped.
2. **`clean_cms_ndh_bulk.py`** — streams each verified `.zst` through
   `zstd -dc` directly into a line-by-line JSON parser; the decompressed
   NDJSON exists only as pipe output, never as a file. Two passes over the
   two files (Practitioner, then PractitionerRole — PractitionerRole
   entries reference a Practitioner id, so the set worth keeping role data
   for is only known after Practitioner has been fully scanned), reusing
   `parse_practitioner()`/`parse_roles()` from the per-NPI harvester so the
   FHIR-to-row flattening logic exists in exactly one place. Produces two
   CSVs — `artifacts/cms_ndh_bulk_cohort.csv` (this project's 16,775 cohort
   NPIs, same schema as the per-NPI harvester's output, for cross-checking
   it) and `artifacts/cms_ndh_bulk_national_cnm.csv` (every NDH practitioner
   nationally carrying the CNM taxonomy, cohort member or not) — each with
   its own `.provenance.json` recording the source files' SHA-256 and the
   release's `generated_at`.

### 7.3 A schema gotcha the first run caught: system URIs differ by source

The first real run of `clean_cms_ndh_bulk.py` scanned all 7,481,907
`Practitioner` lines and matched **zero** — including NPI `1003009010`, the
same Milwaukee CNM demonstrated live in section 3, confirmed present in this
exact file by direct `zstd -dc | grep`. The cause: the bulk export codes the
same facts under **different FHIR system URIs** than the live gateway uses
for identical data.

| Field | Live gateway (`directory.cms.gov/fhir`) | Bulk export (`06-Practitioner.ndjson.zst`) |
|---|---|---|
| NPI identifier system | `http://hl7.org/fhir/sid/us-npi` | `http://terminology.hl7.org/NamingSystem/npi` |
| Taxonomy coding system | `http://nucc.org/provider-taxonomy` | `http://hl7.org/fhir/us/ndh/ValueSet/HealthcareIndividualTaxonomyVS` |
| Credential coding system | `http://hl7.org/fhir/us/ndh/CodeSystem/FaCeT-credentialCS` | same (confirmed matching — not every field differs) |

Fixed by accepting both URIs in `extract_npi()`/`has_midwife_taxonomy()`
(`clean_cms_ndh_bulk.py`) and in `parse_practitioner()`'s taxonomy check
(`harvest_cms_national_provider_directory.py`, shared by both scripts) —
additive `in (...)` checks, so the already-complete per-NPI harvest output
(sourced only from the live gateway) is unaffected by this fix.

### 7.4 Results

Re-run after the fix, against all 16,775 cohort NPIs plus the full national
`Practitioner` file (7,481,907 lines) and `PractitionerRole` file
(11,218,772 lines), end-to-end in under 2.5 minutes:

- **16,361 / 16,775 (97.5%)** of cohort NPIs found in the bulk Practitioner
  file — consistent with the per-NPI harvester's own ~97% hit rate on its
  bounded test (section 6), as it should be: same underlying snapshot.
- **15,941** practitioners nationally carry the CNM taxonomy (`367A00000X`),
  cohort member or not.
- Of those, **12,704 are also cohort members** — leaving **3,237** NDH-tagged
  CNMs nationally that are *not* in this project's AMCB-to-NPPES cohort.
  These are not claimed as "midwives AMCB missed" without further work: NDH
  taxonomy tagging is payer/PECOS-sourced and may include CMs, retired or
  inactive NPIs, or taxonomy mis-tags the same way NPPES itself does — but
  the list is now a concrete, inspectable set for that question rather than
  a hypothetical.

**Related references:**
- [Health Tech Ecosystem Data Release Specifications](https://github.com/CMS-Enterprise/HTE_data_release_specifications)
  (CC0-1.0; file-naming and release-content conventions; data-inclusion
  questions go to `npd@cms.hhs.gov` or the Health Technology Ecosystem Slack)
- [CMS Health Tech Ecosystem Interoperability Framework](https://www.cms.gov/health-technology-ecosystem/interoperability-framework)
- [FHIR US NDH Implementation Guide — resource relationships](https://build.fhir.org/ig/HL7/fhir-us-ndh/en/resourceRelationship.html)
  (the resource graph the downloads page's interactive diagram reproduces)

## 8. A single-NPI defect in CMS's own export, caught by the national discovery file

A user cross-checked NPI `1417904962` against the live NPPES registry and
found it belongs to Monica Amona Martin, MD (Internal Medicine), not the
"AMONA MONICA CLUELULETE NATANA" name this project's `cms_ndh_bulk_national_cnm.csv`
showed, with 153 addresses attached. Traced in full:

- **Not in the cohort.** `grep` confirms this NPI is absent from
  `artifacts/amcb_npi_linkage_FROZEN.csv` and from
  `artifacts/cms_ndh_bulk_cohort.csv`. It surfaced only in the discovery-only
  national-sweep file, which (as of this writing) no other script reads — zero
  impact on any published Table 1, map, or rurality figure.
- **The defect is CMS's, confirmed by inspecting the raw NDJSON line directly**
  (`grep '"id": "Practitioner-1417904962"'` against `06-Practitioner.ndjson.zst`),
  not a join or name-match bug in this project's code: `parse_practitioner()`
  takes one FHIR resource and flattens it verbatim, performing no cross-NPI
  joins. The single resource CMS published contains five `name` entries — four
  correctly say "MARTIN", matching both the live registry and
  `DAC_NationalDownloadableFile.csv` (36 real multi-state telehealth/hospitalist
  enrollment rows, same correct name) — and one garbled entry, first in the
  array, which `parse_practitioner()`'s `names[0]` picked as primary. The
  garbled form appears nowhere in DAC or the live registry: it is exclusive to
  this one NDH record.
- **The spurious midwife tag has a specific, traceable cause.** Her
  `qualification` array includes an entry coding taxonomy `367A00000X`
  ("Advanced Practice Midwife") whose `issuer` is `Organization-State-MA` and
  whose `identifier` is her real Massachusetts *medical* license (281810, type
  `MD`) — a taxonomy/license-type mismatch inside CMS's NDH build, not
  something recoverable from the data alone.
- **153 addresses is a real NDH figure, amplified from a real pattern.** DAC
  independently shows 36 enrollment rows for this same NPI (Telehlth=Y,
  multiple national hospitalist-staffing organizations with 69–72 members
  each) — she is a legitimately broad telehealth hospitalist. NDH's 153 is
  well beyond that, but the underlying shape (one physician, many
  staffing-company-mediated facilities) is not fabricated from nothing.
- **Scale of the issue, measured, not assumed:** of 15,941 national-sweep
  rows, 1,010 have >10 addresses, 30 have >25, 2 have >50, and exactly **1**
  (this NPI) exceeds 100. Of the 16,361 real cohort rows, 1,046 have >10, 35
  have >25, 1 has >50, and **none** exceed 100 — the cohort's own worst case
  (52 addresses, a real CRNA) is a third of this NPI's count.

**No correction was made to any record** — there was nothing to correct in
this project's own data, since the NPI was never part of the cohort.
[`tests/test_cms_ndh_address_count_sanity.py`](../tests/test_cms_ndh_address_count_sanity.py)
now fails loudly (by design) whenever `cms_ndh_bulk_national_cnm.csv` or
`cms_ndh_bulk_cohort.csv` contains a row over 100 addresses, naming the NPI,
so this class of CMS-side defect cannot flow silently into a future merge
with the cohort.

## 9. A second, independently-verified source: CMS PECOS Medicare revocation

Section 5 above documents that the NDH `hhs_in_exclusion_list` flag was only
verifiable against the real public HHS-OIG LEIE for 10 of 153 flagged NPIs
(6.5%) — the rest have no traceable connection to the public exclusion list
by NPI. CMS's separate "Revoked Medicare Providers and Suppliers" file
(opendata.hhs.gov, PECOS re-enrollment bars, snapshot updated 2026-03-02) is
a different kind of evidence: it is CMS's own administrative-action record,
NPI-keyed, naming a specific revocation reason and a specific reinstatement
date — not a name-matched list with an unclear denominator.

**Built by [`match_cms_pecos_revocations.R`](../match_cms_pecos_revocations.R)**
against `artifacts/cms_pecos_revoked_providers_cohort.csv`, checked over the
same 16,775-NPI analytic cohort `cms_ndh_midwives.csv` covers (`cohort_member
== TRUE`), loaded into the project's DuckDB warehouse by
[`load_cms_pecos_revocations_to_duckdb.R`](../load_cms_pecos_revocations_to_duckdb.R)
from the raw CMS file (7,547 rows, 6,451 distinct NPIs; not itself tracked —
only the cohort-scoped, name-free derivative is).

**Result: exactly 1 of 16,775 cohort NPIs matches** — NPI `1366580714`, Sue
Schlegelmilch (UT), PROVIDER_TYPE_DESC "CERTIFIED NURSE MIDWIFE (CNM)" (a
genuine CNM match, not a business entity or a different discipline),
revoked 2020-04-14 for noncompliance/failure-to-report (424.535(A)(1) and
(A)(9)), re-enrollment barred through 2026-08-07.

**This is the same NPI the CMS NDH exclusion flag already named** — one of
the 10/153 independently confirmed against the real LEIE in section 5. Two
separately-sourced, separately-built federal administrative records agreeing
on the same person is exactly the kind of corroboration that distinguishes a
real finding from the NDH flag's 93.5% noise rate; `artifacts/
federal_adverse_action_flags.csv`'s `federal_adverse_action_source` column for
this NPI now reads both sources, built by
[`build_federal_adverse_action_flags.R`](../build_federal_adverse_action_flags.R)
via `R/federal_adverse_action_exclusions.R::build_federal_adverse_action_flags()`,
which already dedupes by NPI and concatenates sources rather than requiring a
single list to own every exclusion.

**Net effect on the published cohort: zero.** Her roster `status` is
`LAPSED`, not `ACTIVE`, so `canonical_active_primary()` already excludes her
from the analytic cohort for an unrelated reason — the federal
adverse-action exclusion step in `make_cohort_exclusion_flow_figure.R` only
evaluates NPIs that are both `ACTIVE` and `primary_midwifery`-linked, and she
is outside that population regardless of either flag. Every count in
`docs/figures/cohort_exclusion_flow_counts.csv` is unchanged by this source
(12,170 matched, 77 excluded for federal adverse action, 12,093 surviving —
identical to before PECOS was added). The cross-check is retained because it
corroborates one existing flag and establishes the DuckDB table and matching
script for any future, higher-yield use, not because it changes today's
published numbers.

## 10. A third source, by name rather than NPI: the FDA Debarment List (Drug Product Applications)

Both sources above are NPI-keyed: CMS publishes them with the same
identifier this project already joins on everywhere else. FDA's debarment
list is not — it carries no NPI, no license number, no identifier of any
kind other than a name — so this source is a name match, which carries a
different failure mode than a join: a common name can collide, in either
direction (one FDA name with several candidate cohort NPIs, or two
same-named people in either file). The matching script treats any such
collision as unresolved, not a match; see below.

**Where to find the current file.** FDA republishes this list in place, so
the direct download URL changes (it is served from `fda.gov/media/<numeric
id>`, and that id is reassigned on each republish — do not reuse an old
direct link). To get the current file:

1. Open FDA's debarment list page:
   `https://www.fda.gov/inspections-compliance-enforcement-and-criminal-investigations/compliance-actions-and-activities/fda-debarment-list-drug-product-applications`
2. Under "Debarments (Drug Applications)," follow the **Single Page Data
   Format** link — an `.xlsx` export of the same table shown on the page.
3. Save it and point `FDA_DEBARMENT_XLSX` at it, or leave it at
   [`load_fda_debarment_to_duckdb.R`](../load_fda_debarment_to_duckdb.R)'s
   default path (`~/Downloads/fda_debarment_drug_applications.xlsx`).

This snapshot — "Data Format-Drug Applications (Oct 2, 2026).xlsx," 158
rows, downloaded 2026-10-26 — lists only individuals; the page's FIRMS
section reported "None as of this date." Columns: last name, first & middle
names (one combined field), effective date, term of debarment, and the
Federal Register citation. The file is **not clean**: effective dates are a
mix of Excel date serials and typed strings like `01/04/2021` in the same
column, and at least one row carries a malformed year (`10/5/20111`) —
FDA's own data-entry defect, not a parsing bug here. The loader keeps every
date field as the raw text FDA published rather than guessing a single
format and silently reformatting or dropping what doesn't parse.

**Built by [`match_fda_debarment.R`](../match_fda_debarment.R)** against
`artifacts/fda_debarment_match_cohort.csv`, checked over the same
16,775-NPI analytic cohort the other two sources cover (`cohort_member ==
TRUE`), loaded into the DuckDB warehouse by
[`load_fda_debarment_to_duckdb.R`](../load_fda_debarment_to_duckdb.R). Last
and first names on both sides are normalized with the same function that
built `amcb_npi_linkage_FROZEN.csv`'s own `normalized_last_name`/
`normalized_first_name` columns — `mysterynpi::blank_na(x, fold_hyphens =
TRUE)` — so the two sides are not two independently-invented normalizers
quietly disagreeing. The FDA file's combined "First & Middle Names" field is
compared on its first token only (no splitter exists for this format the
way `amcb_split_first()` exists for AMCB's own data), which costs a match
only for someone FDA published under a middle name alone.

A name key is flagged `fda_debarred = TRUE` **only** when it is a singleton
on both sides — exactly one FDA debarment row and exactly one cohort NPI
share that last+first key. Any collision is reported as `AMBIGUOUS` and left
unflagged; `NONE` means no FDA row shares that name at all. This is stricter
than the state-board-of-nursing scripts' VERIFIED/AMBIGUOUS/UNMATCHED
convention (`harvest_live_*_bon_from_tracked_roster.py`): there, a missed
tie only loses a credential fact, but here a wrongly-applied flag would mean
excluding the wrong person of the same name from the published cohort — the
higher bar is deliberate.

**Result: exactly 1 of 16,775 cohort NPIs matches** — NPI `1891824926`,
cohort name "Lisa Jo Sharp" (`status` `LAPSED`), against FDA's "Sharp, Lisa
Jean," permanently debarred effective 2012-08-23 (77 FR 56647). The middle
name differs (Jo vs. Jean) and is not part of the match key, so **this is a
name match only, not a confirmed identity match** — the same caveat this
project already attaches to the CMS NDH flag in section 5, and worded the
same way in `federal_adverse_action_flags.csv`'s `federal_adverse_action_
source` column ("FDA debarment, drug product applications (name match,
unverified, see appendix)").

**Net effect on the published cohort: zero**, for the same reason as the
PECOS source in section 9 — her roster `status` is `LAPSED`, not `ACTIVE`,
so she is outside the `ACTIVE` + `primary_midwifery`-linked population the
federal adverse-action exclusion step in `make_cohort_exclusion_flow_
figure.R` evaluates, regardless of this flag. Every count in `docs/figures/
cohort_exclusion_flow_counts.csv` is unchanged (12,170 matched, 77 excluded
for federal adverse action, 12,093 surviving — identical to before FDA was
added).

**DEA is not wired in.** Unlike CMS and FDA, DEA does not publish a bulk
file of revoked or surrendered registrants — only a single-registrant
verification lookup. There is no dataset to download or match against, so
this is not a gap to close later; it is the entire public surface DEA
offers.
