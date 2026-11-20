# Abbreviations in the state-source audit

Companion to [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md)
and [`VIGNETTE_STATE_SOURCE_AUDIT_2026-11-04.md`](VIGNETTE_STATE_SOURCE_AUDIT_2026-11-04.md).

Every abbreviation below is one those two documents, their tables, or the
audit figures actually use. Each is spelled out at its first appearance in
each document; this file is the single place to look it up afterwards, and the
place a figure caption can point to when the plot has no room to expand it.

Abbreviations are **not** expanded inside code identifiers, file paths, column
names, or schema fields. `npi`, `nppes_state`, `ccn_1`, `artifacts/state_
source_audit_coverage.csv` are machine-readable names; renaming them for
manuscript style would break the join keys this audit is built on.

## Sources and identifiers

| Abbreviation | Expansion | What it is here |
|---|---|---|
| AMCB | American Midwifery Certification Board | Certifies certified nurse-midwives; its public roster is this project's cohort spine, keyed by certification number |
| BON | Board of Nursing | A state licensing board. Eight were harvested; six publish a state |
| CCN | CMS Certification Number | Medicare's facility identifier, used to attach a midwife to a hospital and so to that hospital's state |
| CMS | Centers for Medicare & Medicaid Services | Publisher of NPPES, DAC, PECOS, Open Payments, Facility Affiliation and NDH |
| CNM | Certified Nurse-Midwife | The credential this cohort holds |
| DAC | Doctors and Clinicians | CMS's clinician directory, formerly Physician Compare. Both names appear because the historical vintages carry the old one |
| HHS | U.S. Department of Health and Human Services | CMS's and OIG's parent department |
| NBER | National Bureau of Economic Research | Mirrors the 2013-2016 Physician Compare vintages CMS no longer serves |
| NDH | National Directory of Healthcare Providers | CMS's FHIR-published provider directory; a single current snapshot, no archived history |
| NPI | National Provider Identifier | The ten-digit identifier every source is joined on. **The join key, never evidence of a state** |
| NPPES | National Plan and Provider Enumeration System | The registry behind the NPI, and this audit's reference source — the one every other source is compared against |
| OIG | Office of Inspector General | The HHS office whose 2011 study (report OEI-07-09-00440) is the external benchmark in §4 of the vignette |
| PECOS | Provider Enrollment, Chain, and Ownership System | Medicare's enrollment system; its revalidation and reassignment releases supply enrollment addresses |
| T-MSIS | Transformed Medicaid Statistical Information System | The federal Medicaid data system; its enrolment file records every state a midwife is enrolled in, not one |

## Technical and regulatory terms

| Abbreviation | Expansion | Note |
|---|---|---|
| API | application programming interface | How CMS's metastore and download endpoints are queried |
| CI | confidence interval | Wilson intervals, on the §3 agreement table |
| FHIR | Fast Healthcare Interoperability Resources | The HL7 standard NDH publishes in |
| GPO | group purchasing organization | One of the two kinds of entity that report an Open Payments transaction |
| HCPCS | Healthcare Common Procedure Coding System | Procedure codes, in the Medicaid billing appendix |
| HPSA | Health Professional Shortage Area | A federal shortage designation |
| NDC | National Drug Code | Drug identifier, in the Medicaid billing appendix |
| PY | program year | Open Payments' own term for the year a payment is attributed to. **PY2021** is the first year certified nurse-midwives were reportable |
| SHA-256 | Secure Hash Algorithm, 256-bit | The digest every provenance sidecar records for each input |
| SSN | Social Security number | Named only to say this project holds none |
| SUPPORT Act | Substance Use-Disorder Prevention that Promotes Opioid Recovery and Treatment for Patients and Communities Act | The 2018 law whose covered-recipient expansion made certified nurse-midwives Open-Payments-reportable from PY2021 |
| ZIP | Zone Improvement Plan | As in ZIP Code. `ZIP5` means the five-digit code without the +4 extension |

## Six kinds of address, which are not interchangeable

The audit's whole finding rests on this distinction, so these terms are used
strictly and never as synonyms for "where a midwife is".

| Term | What the record actually asserts |
|---|---|
| **Practice address** | Where care is delivered. NPPES's practice location, DAC's practice address |
| **Mailing address** | Where the provider receives post. NPPES carries this separately; it is often a home or a billing office |
| **Enrollment address** | The address on file with a programme, from PECOS revalidation or a state Medicaid enrolment record. An administrative fact about a programme, not a place of work |
| **Billing location** | Where a claim says the service was billed from. Can be a corporate office hundreds of miles from the patient |
| **Facility affiliation** | A link to a facility via its CCN. Gives the facility's state, which is evidence about the facility, and only indirectly about the midwife |
| **Reported professional location** | A self-reported address in a commercial directory (Healthgrades, Doximity), with no attestation and usually no date |

Two sources can disagree about a midwife's state while both being correct,
because they are answering different questions from this list. That is the
audit's central result, not a defect in the data.

## Two Medicaid relations, also not interchangeable

| Term | Question it answers |
|---|---|
| **Exact single-state equality** | Is this source's one state the same as NPPES's one state? |
| **Multistate set membership** | Is NPPES's state *among* the states this midwife is enrolled in? |
| **Location agreement** | Do two sources place the midwife in the same state? |
| **Enrollment overlap** | Do two programmes both have her enrolled, anywhere? |

A Medicaid enrolment record legitimately carries several states. Reducing it
to one and testing equality is the error §4 of the appendix documents; the
published figures use set membership.
