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
| **Tier 2: Geographic Candidate Hospital** | Midwife and delivery hospital share municipality and state ([`ob_hospitals_geocoded.csv`](file:///Users/tylermuffly/midwifery/artifacts/ob_hospitals_geocoded.csv)) | **Low** | **High Coverage** | **Candidate Co-Location / Sensitivity**: Spatial candidate co-location pool |
| **Negative Control** | Direct clinician NPI to hospital organization NPI equality (`npi == hospital_npi`) | **N/A** | **Near Zero** (0 matches) | **Negative Control**: Confirms Type 1 Individual vs Type 2 Organization NPI separation |

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

## 5. Historical 11,093 Audit Provenance & Preservation

The historical 11,093 40-state audit snapshot files have been preserved in:
- Directory: [`audit_legacy_hospital_linkage_11093_20260913/`](file:///Users/tylermuffly/midwifery/audit_legacy_hospital_linkage_11093_20260913/)
- Sidecar Manifest: [`audit_legacy_hospital_linkage_11093_20260913/manifest.json`](file:///Users/tylermuffly/midwifery/audit_legacy_hospital_linkage_11093_20260913/manifest.json)
