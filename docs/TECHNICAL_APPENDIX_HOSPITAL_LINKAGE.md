# Technical Appendix: 3-Tier Hospital Linkage Architecture & Empirical Validation Framework

## 1. Executive Summary

This appendix details the technical design, empirical validation metrics, and data pipeline architecture for linking certified nurse-midwives (CNMs) and certified midwives (CMs) to hospital CMS Certification Numbers (CCNs).

The architecture establishes a 3-tier linkage hierarchy:
1. **Tier 1 (Primary Analysis — High Specificity)**: CMS Doctors and Clinicians (DAC) facility affiliations linking individual clinician NPIs directly to facility CCNs.
2. **Tier 2 (Sensitivity Analysis — Spatial Candidate Pool)**: Municipal co-location candidate pairing midwives and delivery hospitals sharing the same city and state.
3. **Negative Control (Structural Validation)**: Direct Type 1 Individual CNM NPI to Type 2 Hospital Organization NPI equality check (`npi == hospital_npi`).

---

## 2. Decoupled Data Model Architecture

Hospital price transparency (HPT) availability is treated as a **secondary hospital attribute**, not an eligibility filter for defining clinician-hospital relationships:

```
Midwife NPI ──> CMS Facility Affiliation ──> Delivery Hospital CCN ──> [has_hpt_crosswalk = TRUE/FALSE]
```

This decoupled design ensures that hospital privilege/affiliation analysis remains un-biased by price transparency data availability across hospitals.

---

## 3. 3-Tier Hospital Linkage Architecture

| Linkage Tier | Data Source & Mechanism | Specificity | Coverage / Role | Methodological Function |
|---|---|---|---|---|
| **Tier 1: CMS-Confirmed Facility Affiliation** | Individual Clinician NPI linked to CMS-reported facility affiliation CCN (`Facility_Affiliation_2026-06.csv`) | **High** | **High Specificity** | **Primary Analysis**: Confirmed clinician-facility affiliations |
| **Tier 2: Geographic Candidate Hospital** | Midwife and delivery hospital share municipality and state ([`ob_hospitals_geocoded.csv`](../artifacts/ob_hospitals_geocoded.csv)) | **Low** | **High Coverage** | **Candidate Co-Location / Sensitivity**: Spatial candidate co-location pool |
| **Negative Control** | Cohort NPI equality against each hospital identifier space, run by [`validate_hospital_linkage_controls.R`](../validate_hospital_linkage_controls.R) into [`hospital_linkage_negative_controls.csv`](../artifacts/hospital_linkage_negative_controls.csv) | **N/A** | **Zero collisions** (NC1, NC2) | **Negative Control**: Confirms Type 1 Individual vs Type 2 Organization NPI separation |

### 3.1 The negative control, as run

Until 2026-09-18 this row asserted `npi == hospital_npi`, "Near Zero (0 matches)",
and cited `ob_hospitals_geocoded.csv` beside it. **That artifact has no NPI column
of any kind** — its hospital identifier is `prvdr_num`, the CCN — so the control
could not be evaluated from the source named next to it, and the `0` was an
assertion rather than a result ([#232](https://github.com/mufflyt/midwifery/issues/232)).

The claim is almost certainly true: CMS Type 1 (individual) and Type 2
(organization) NPIs are disjoint by construction. That is precisely why it
mattered — this is the one check in the table whose job is to fail loudly if the
two identifier spaces were ever conflated, and as written it would not have.

It is now three controls, one per identifier space actually joined on, emitted
into a tracked artifact on each run:

| control | question | source | evaluated over | collisions | status |
|---|---|---|---:|---:|---|
| **NC1** | does any cohort NPI appear as a hospital CCN? | `ob_hospitals_geocoded.csv$prvdr_num` | 2,784 CCNs | **0** | PASS |
| **NC2** | does any cohort NPI appear as an affiliation CCN? | `dac_facility_affiliations.csv$ccn` | 902 CCNs | **0** | PASS |
| **NC3** | does any cohort Type 1 NPI appear as a hospital Type 2 **organization** NPI? | `$HPT_PRICES/reference` (NPI↔CCN crosswalk + CMS hospital enrolments) | — | — | **SKIPPED** |

All against the 12,171 ACTIVE primary-linked NPIs. NC3 is the control as
originally stated, pointed at the two sources in this project that do carry
hospital organization NPIs; they live on an external volume that is not in any
checkout, so it reports SKIPPED with the file it could not read. **A skip is not
a pass** — the artifact records the row count each control was evaluated over, so
a control that saw nothing cannot be read as a control that found nothing. The
script exits non-zero on any FAIL.

---

## 4. Empirical Validation Framework & Metrics

Evaluated using the Tier 1 subset as a **high-specificity reference standard**:

- **Geographic Candidate Recall / Sensitivity**: **50.59%** ($\frac{903 \text{ recovered}}{1,785 \text{ Tier 1 affiliations}}$). City/state co-location recovers approximately half of CMS-observed facility affiliations.
- **CMS-Observed Fraction of Geographic Candidate Pairs**: **32.39%** ($\frac{903 \text{ confirmed pairs}}{2,788 \text{ candidate pairs generated for Tier 1 midwives}}$).
- **Municipal Concentration Stratification**:
  - *Single-Hospital Municipalities*: **46.72%** (834 of 1,785) of affiliations occur in single-hospital towns; geographic candidate recall rises to **59.11%**.
  - *Multi-Hospital Municipalities*: **32.72%** (584 of 1,785) of affiliations occur in multi-hospital cities.
  - *Cross-City / Regional Affiliations*: **367 of 1,785 CMS-observed facility affiliations (20.56%)** occur in hospitals located outside the midwife's primary NPPES practice city.

---

## 4.1 The denominator these metrics rest on is stale

`artifacts/dac_hospital_affiliation_summary.csv` records `cohort_n = 12,129`.
Running its producer's own cohort definition
(`extract_dac_facility_affiliations.R:74-79` — `status == "ACTIVE"`,
`linkage_tier == "primary_midwifery"`, distinct `certification_number`, non-empty
NPI) against freeze `1a7bd6a8` gives **12,171**, and so does every variant of
those filters that was tried: reordering the dedup against the NPI filter,
reading the NPI as character or as a double, `cohort_member`, `match_status ==
"primary"`. **Nothing reproduces 12,129 from the current freeze**, so the
artifact was built against a different linkage file — and it has no provenance
sidecar, so nothing records which.

Everything downstream of it rests on that denominator: `with_hospital = 1,676`,
`hospitals_linked = 908`, `any_birth_friendly = 1,555`, `multi_hospital = 230`.
The producer now writes through `write_with_provenance()` and **asserts its own
`cohort_n` against `canonical_active_primary()`**, so the next run either lands
on the canonical count or stops and says by how much it missed. Re-running it
needs `FACILITY_AFFILIATION_FILE` and the Medicare DuckDB warehouse, neither of
which is on the machine this was written on
([#231](https://github.com/mufflyt/midwifery/issues/231)).

The §4 metrics above are computed over the 1,785 Tier 1 affiliations and
reproduce exactly; they do not use `cohort_n`. It is the summary artifact's own
counts that are pending a rebuild.

---

## 5. Historical 11,093 Audit Provenance & Preservation

The historical 11,093 40-state audit snapshot files have been preserved in:
- Directory: [`audit_legacy_hospital_linkage_11093_20260913/`](../audit_legacy_hospital_linkage_11093_20260913/)
- Sidecar Manifest: [`audit_legacy_hospital_linkage_11093_20260913/manifest.json`](../audit_legacy_hospital_linkage_11093_20260913/manifest.json)
