# Technical Appendix: National Nurse-Midwifery Education Completeness, IPEDS Denominator Audits, and Institutional Data Loss Diagnostics

**Document Identifier**: `docs/TECHNICAL_APPENDIX_MIDWIFERY_EDUCATION_AUDIT.md`

**Status**: Formal Methodology & Empirical Specification

**Repository**: `mufflyt/midwifery`

**Date**: September 2026

---

## Executive Summary

This Technical Appendix establishes the formal methodology, data specifications, and empirical diagnostics for quantifying nurse-midwifery training institution completeness across the United States.

Traditional clinician directories—including CMS Doctors & Clinicians (DAC),
NPPES, PECOS enrollment files and commercial provider directories—do not
provide a complete nursing-education history. DAC's field is a medical-school
administrative value, many CNMs carry `OTHER` or blank, and a clinician's
primary specialty can be a non-midwifery taxonomy. These fields are useful
observations, but none is a national roster of nurse-midwifery graduates.

To measure these structural limitations, the audit builds an independent
completion denominator from the **National Center for Education Statistics
(NCES) Integrated Postsecondary Education Data System (IPEDS)** Completions
Survey across 12 major ACME-accredited nurse-midwifery institutions. IPEDS is a
program-level count, not a person-level roster; commencement programs and
institutional reports provide the separate person-level discovery layer.

---

## 1. NCES IPEDS Denominator Methodology & Award Level Classification

### 1.1 IPEDS Program Classification (CIP Codes)
The primary federal Classification of Instructional Programs (CIP) code for nurse-midwifery education is:
- **`CIP 51.3807`**: *Nurse Midwife/Nursing Midwifery* — A program that prepares registered nurses to independently provide comprehensive prenatal, intrapartum, postpartum, and gynecological care.

Nearby nursing CIPs are retained only as diagnostics. They cannot be added to
the midwifery denominator because they mix midwifery and non-midwifery awards.

### 1.2 IPEDS Award Level Disaggregation (`AWLEVEL`)
IPEDS completions are disaggregated into three explicit degree levels per NCES specifications:
- **`AWLEVEL = 07`**: Master's degree (MSN).
- **`AWLEVEL = 18`**: Doctor's degree - professional practice (DNP).
- **`AWLEVEL = 08`**: Post-Master's certificate (PGC).

---

## 2. Target Institution Specifications & IPEDS UNITID Registry

The completeness audit spans 12 longstanding, ACME-accredited nurse-midwifery programs. Every institution is queried using its NCES IPEDS UNITID:

| Institution Name | IPEDS UNITID | Primary Degree Track | Secondary / Dual CIP Audited |
|:---|:---:|:---:|:---:|
| **Frontier Nursing University** | `156727` | MSN (CNEP) / PGC | `51.3807` |
| **Georgetown University** | `131496` | MSN / DNP | `51.3807`, `51.3822` (NM/WHNP) |
| **Vanderbilt University** | `221999` | MSN | `51.3807`, `51.3805` (FNP/NM) |
| **University of Cincinnati** | `201885` | MSN | `51.3807` |
| **University of Michigan-Ann Arbor** | `170976` | MSN | `51.3807` |
| **Columbia University in the City of NY** | `190150` | DNP | `51.3807`, `51.3818` |
| **Oregon Health & Science University** | `209490` | DNP | `51.3807`, `51.3818` |
| **Emory University** | `139658` | MSN | `51.3807`, `51.3805` |
| **University of Pennsylvania** | `215062` | MSN | `51.3807`, `51.3818` |
| **University of Minnesota-Twin Cities** | `174066` | DNP | `51.3807`, `51.3818` |
| **SUNY Downstate Health Sciences Univ.** | `196255` | MSN | `51.3807` |
| **University of Alabama at Birmingham** | `100663` | MSN | `51.3807` |

> [!IMPORTANT]
> **UnitID Governance**: SUNY Downstate Health Sciences University (`196255`) is strictly isolated from SUNY Upstate Medical University (`196307`) to prevent institutional cross-contamination in New York State provider matching.

---

## 3. What IPEDS can answer

The reproducible acquisition covers award years 2015–2024. NCES had not
released `C2025_A` when the audit ran, so 2025 is unavailable rather than zero.
The revised annual file is preferred when present, and every raw archive hash is
recorded in the provenance sidecar.

Seven institutions report `51.3807` in all ten years: Emory, Frontier, OHSU,
SUNY Downstate, Cincinnati, Penn and Vanderbilt. Their tracked total is 3,756
awards, with master's and post-master's certificates kept separate. Five
institutions—UAB, Georgetown, Michigan, Minnesota and Columbia—report no
`51.3807` awards in the window while reporting thousands under general nursing
`51.3801`. IPEDS therefore cannot supply a midwifery-specific denominator for
those five schools; the general-nursing total must not be substituted.

Generated outputs:

- `artifacts/ipeds/ipeds_midwifery_completions_2015_2024_<timestamp>.csv`
- `artifacts/ipeds/ipeds_midwifery_by_award_level_<timestamp>.csv`
- `artifacts/ipeds/ipeds_cip_coverage_by_institution_<timestamp>.csv`

These outputs remain local until every emitted file carries its own complete
provenance sidecar. The acquisition script and raw-input hash contract are the
tracked reproducibility surface.

No person-level recovery percentage is published until a commencement roster
contains only observed names with source-document evidence.

---

## 4. Raw institutional alias inventory

Local generated artifact: `artifacts/11_schools_raw_alias_inventory.csv`.
It is intentionally gitignored because it contains person-level working data;
the filename predates the addition of UAB and is retained for compatibility.

To prevent data loss from string variance, candidate matching evaluates all historical institutional aliases across DAC, Physician Compare (2013–2025), NPPES, State BONs, and Trilliant:

```
[Georgetown University]
├── Georgetown University
├── Georgetown University School of Nursing
├── Georgetown University School of Nursing & Health Studies
├── Berkley School of Nursing
└── GEORGETOWN UNIVERSITY SCHOOL OF MEDICINE

[Vanderbilt University]
├── Vanderbilt University
├── Vanderbilt University School of Nursing
├── VUSN
└── VANDERBILT UNIVERSITY SCHOOL OF MEDICINE

[Frontier Nursing University]
├── Frontier Nursing University
├── Frontier School of Midwifery and Family Nursing
├── Frontier School of Midwifery
├── Frontier Graduate School of Midwifery
└── Frontier Nursing Service
```

---

## 5. Person-level candidate protocol

Any future candidate table must use the following schema:

`amcb_id | npi | person_name | institution | degree | graduation_year | evidence_source | evidence_url_or_file | evidence_strength | existing_degree | proposed_degree | match_reason`

> [!CAUTION]
> **Non-Destructive Governance Rule**: Discovery scripts MUST NOT overwrite or mutate canonical AMCB linkage tables (`artifacts/amcb_npi_linkage_FROZEN.csv`) or existing degree assignments in place. All candidate matches are logged as proposed updates pending formal review.

---

## 6. Verification and repository integrity

Relevant repository gates are:
```bash
Rscript tests/ci_artifact_contracts.R  # PASS (0 failures)
Rscript tests/ci_hygiene.R             # PASS (0 failures)
```

## 7. Commencement acquisition and local OCR

Institutional programs arrive in three forms: text-bearing PDFs, Issuu page
images, and archived web copies. The acquisition scripts keep those raw inputs
outside the tracked analytical artifacts:

- local, gitignored institution-specific parsers read text-bearing Vanderbilt
  and Georgetown programs; they are exploratory until their provenance and
  privacy contracts are suitable for promotion;
- `harvest_issuu_commencement.py` downloads Frontier page renders and invokes
  the macOS Vision helper in [`scripts/ocr_local.swift`](../scripts/ocr_local.swift).

Build the OCR helper on macOS with:

```bash
swiftc scripts/ocr_local.swift -o ocr_local
```

The compiled binary, downloaded PDFs, page images and OCR text live in
gitignored local scratch space. Parsed names are not tracked until each row has
an observed source document and the repository's leak/provenance gates accept
the artifact. Placeholder names and estimated annual cohorts are inadmissible.

## 8. Interpretation limits

- IPEDS counts awards, not unique people, and a person can receive more than
  one award or appear under a generic DNP CIP.
- A commencement listing proves that a named person was presented in a program;
  it does not by itself prove AMCB certification, NPI identity, or later practice.
- CMS school strings are administrative values routed through a medical-school
  reference system, not a complete nursing-school registry.
- Apparent recovery percentages depend on the selected years and award levels;
  they are diagnostics of source completeness, not estimates of workforce
  participation.
