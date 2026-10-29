# Technical Appendix: Medicaid Procedure-Billing Activity, HCPCS and NDC

## 1. Research question

Of the canonical AMCB midwife cohort and the two valid intrapartum-care
OB-GYN comparators (Generalist and MFM; see
`load_obstetric_providers.R`'s documented exclusion of REI/GO/FPMRS/MIGS/CFP/PAG
as non-intrapartum subspecialties), who actually **billed** Medicaid for a pap
test, urodynamics, IUD insertion/removal, or a vaginal delivery, using HHS's
public Medicaid claims extracts? And, the question this whole exercise was
really in service of: **can this data tell us how many deliveries a midwife
did for Medicaid patients?**

Short answer to the second question, established in Sections 6-7 below: **no,
not reliably, for almost anyone.** This is a structural property of the public
extract, not a bug in the join.

## 2. The cohort

Built by `analyze_medicaid_procedure_billing_ob_midwife.R`, three sources:

| Source | Filter | n |
|---|---|---|
| `artifacts/amcb_npi_linkage_FROZEN.csv` | `canonical_active_primary()` (the project's own canonical cohort function, `R/lib/cohort_definitions.R`) | 12,170 |
| ABOG canonical roster (`~/isochrones/.../canonical_abog_npi_LATEST.csv`) | `subspecialty == "Generalist"`, non-NA NPI, minus any NPI present in the subspecialist cohort (subspecialist-cohort evidence wins over the canonical label, same rule `load_obstetric_providers.R::load_generalists()` uses) | 41,486 |
| ABOG subspecialist cohort (`step_2.5_final_cohort.rds`) | `subspecialty_normalized == "MFM"`, non-NA NPI | 2,610 |

**Deliberately NOT geocoded.** `load_generalists()` joins the ABOG roster
against three geocode sources and keeps only providers with usable
coordinates (56.4% of generalists) — a floor built for the travel-time
analysis. That join is irrelevant to a billing-activity question and would
silently drop ~44% of real NPIs for no reason, so this analysis reads the
ABOG roster directly instead.

**4 NPIs excluded as ambiguous**, present in both the midwife and
ob_gyn_generalist cohorts:

| NPI | Midwife name | Generalist name |
|---|---|---|
| 1497065312 | Mary Burke | Mary Catherine Burke |
| 1639615073 | Rebecca Rivera | Rebecca Rivera |
| 1851304935 | Kathryn Charron Hoyt | Kathryn Hoyt |
| 1962780445 | Lori Fitzpatrick | Lori Wendricks House |

The first three are plausibly genuine dual-credentialed individuals (CNM
practicing as an ABOG-certified generalist, or vice versa). The fourth has
mismatched surnames and is more likely a probabilistic-match error in one of
the two independent linkage pipelines (AMCB-to-NPPES vs. ABOG-to-NPPES) —
not resolved here; written out separately
(`artifacts/medicaid_procedure_billing_dual_group_npi_excluded.csv`) rather
than guessed into either group.

Combined cohort after exclusion: **56,258 distinct NPIs** (12,166 midwife /
41,482 ob_gyn_generalist / 2,610 ob_gyn_mfm).

## 3. Data sources

### 3.1 Medicaid Provider Spending by HCPCS

`download_medicaid_provider_spending.py` → `medicaid_provider_spending_verified.duckdb`,
table `spending`, **238,015,729 rows**. Schema: `BILLING_PROVIDER_NPI_NUM,
SERVICING_PROVIDER_NPI_NUM, HCPCS_CODE, CLAIM_FROM_MONTH, TOTAL_PATIENTS,
TOTAL_CLAIM_LINES, TOTAL_PAID`. Covers outpatient + professional claim lines
with a populated HCPCS code, Jan 2018 - Dec 2024, FFS + managed care + CHIP,
all states/territories. Released by HHS's "DOGE" team, Feb 2026, the first
public provider-level Medicaid claims-volume release (previously required a
ResDAC T-MSIS data use agreement).

**Cell suppression (the finding that matters most for Section 6):** per the
downloader's own docstring, rows with fewer than 12 claim lines **and**
fewer than 12 beneficiaries, for a given NPI/HCPCS/month cell, are not
published.

### 3.2 Medicaid Provider Spending by NDC

`download_medicaid_provider_spending_ndc.py` → `medicaid_provider_spending_ndc_verified.duckdb`,
table `spending_ndc`, **21,515,000 rows**. Schema: `BILLING_PROVIDER_NPI_NUM,
PRESCRIBING_PROVIDER_NPI_NUM, NATIONAL_DRUG_CODE, CLAIM_FROM_MONTH,
TOTAL_UNIQUE_BENEFICIARIES, TOTAL_CLAIM_LINES, TOTAL_PAID`. Same cell-
suppression rule, same release cadence (both datasets show "Updated Jul 24,
2026" on the platform). Version-date `2026-07-24` discovered directly
against the live Azure Blob endpoint (HEAD request, 200 OK, 321,153,465
bytes), not guessed from the HCPCS sibling's Feb-2026 date, which is a
different release with its own schedule.

`NATIONAL_DRUG_CODE = 88888888888` appears in sample rows — a placeholder
for an unreported/non-specific NDC, worth excluding before any drug-specific
analysis (not yet built; this appendix covers presence-only NDC coverage).

### 3.3 Data-quality caveats carried from upstream

- **Nov-Dec 2024 figures decline sharply** relative to prior months, across
  the whole HCPCS dataset — incomplete state submissions (per Milliman's
  published analysis of this release), not a real activity drop.
- **`TOTAL_PAID` contains at least one implausible value** — a single
  NPI/HCPCS/month row exceeding $7 trillion was observed during exploration.
  This is a known data-quality issue in the raw HHS release. `TOTAL_PAID` is
  carried in the output for completeness; `TOTAL_CLAIM_LINES` /
  `TOTAL_PATIENTS` are the trustworthy activity signals.

## 4. HCPCS codes used

Verified 2026-10-26 against current code descriptions (not assumed from
training-data memory):

| Category | Codes | Note |
|---|---|---|
| `pap_test` | Q0091, G0101 | Collection/screening codes, billed by the exam-performing clinician. 88141-88175 (cytopathology interpretation) deliberately excluded — typically billed by a lab/pathologist, not the collecting clinician. |
| `urodynamics` | 51725, 51726, 51727, 51728, 51729, 51736, 51741, 51784, 51785, 51797, 51798 | 51727-51729/51784-51785 (complex studies) are more associated with FPMRS subspecialists than general OB-GYN or midwifery. |
| `iud` | 58300 (insertion), 58301 (removal) | Device-supply J-codes (J7296-J7301) not included — procedure codes only. |
| `vaginal_delivery` | 59400, 59409, 59410, 59610, 59612, 59614 | All six include an actual delivery (global, delivery-only, delivery+postpartum; VBAC variants included). Antepartum-only code deliberately excluded. |

## 5. Results

`artifacts/medicaid_procedure_billing_by_npi.csv` (225,032 rows, person x
procedure grid) and `artifacts/medicaid_procedure_billing_summary.csv` (12
rows), matched on `SERVICING_PROVIDER_NPI_NUM`:

| provider_group | procedure_category | n_cohort | n_billed | pct_billed |
|---|---|---|---|---|
| midwife | iud | 12,166 | 22 | 0.2% |
| ob_gyn_generalist | iud | 41,482 | 224 | 0.5% |
| ob_gyn_mfm | iud | 2,610 | 0 | 0% |
| midwife | pap_test | 12,166 | 145 | 1.2% |
| ob_gyn_generalist | pap_test | 41,482 | 968 | 2.3% |
| ob_gyn_mfm | pap_test | 2,610 | 5 | 0.2% |
| midwife | urodynamics | 12,166 | 0 | 0% |
| ob_gyn_generalist | urodynamics | 41,482 | 100 | 0.2% |
| ob_gyn_mfm | urodynamics | 2,610 | 3 | 0.1% |
| midwife | vaginal_delivery | 12,166 | 366 | 3.0% |
| ob_gyn_generalist | vaginal_delivery | 41,482 | 2,973 | 7.2% |
| ob_gyn_mfm | vaginal_delivery | 2,610 | 109 | 4.2% |

NDC presence (any drug, any month, `PRESCRIBING_PROVIDER_NPI_NUM`):

| provider_group | n_cohort | n_present | pct |
|---|---|---|---|
| midwife | 12,166 | 718 | 5.9% |
| ob_gyn_generalist | 41,482 | 3,627 | 8.7% |
| ob_gyn_mfm | 2,610 | 105 | 4.0% |

## 6. Servicing vs. billing NPI: billing captures *less*, not more

Direct comparison, vaginal-delivery codes:

| provider_group | servicing match | billing match | either |
|---|---|---|---|
| midwife | 366 | 36 | 367 |
| ob_gyn_generalist | 2,973 | 386 | 2,978 |
| ob_gyn_mfm | 109 | 2 | 109 |

Billing-provider NPI is usually the organization/group number, not the
individual clinician, so matching on it alone captures roughly a tenth of
what servicing-provider captures. Combining both adds almost nothing (+1,
+5, +0) — servicing-provider was already the right field, and the low
absolute counts in Section 5 are not a wrong-field artifact.

## 7. What this does and does not establish

**Does not establish: how many deliveries, pap tests, IUDs, or urodynamics
studies any individual provider performed for Medicaid patients.** Three
compounding reasons:

1. **Cell suppression is monthly, and clinical volume is lumpy.** A provider
   doing a genuinely solid Medicaid caseload — e.g. 30-40 vaginal deliveries
   a year — is still only doing 2-4 in any given month, never crossing the
   12-claim-line/12-beneficiary threshold. A provider would need to sustain
   12+ of a single procedure in every single reported month to show up
   reliably. Almost no individual clinician's practice looks like that.
2. **Delivery billing is frequently not attributed to the individual
   clinician at all** — global OB packages and facility/inpatient billing
   route the relevant claim line through a group or facility NPI rather than
   the attending clinician's own NPI as servicing provider (Section 6 rules
   out billing-provider as a fix; it is strictly worse).
3. **National denominator sanity check.** Across the *entire* 238M-row
   dataset — all US Medicaid, all providers, 2018-2024 — only 3,442 distinct
   NPIs nationally ever appear as servicing provider for code 59409, and
   1,242 for 59400. That ceiling is a property of the data, not of this
   cohort or this join.

**Does establish:** a high-precision, low-recall positive signal. A provider
who DOES appear has a real, documented claim-line record meeting the
suppression threshold. Absence is close to uninformative — it does not mean
"did not perform the procedure," it means "did not cross a monthly
per-NPI publication threshold," which most real, active clinicians will not
cross for most procedures, most months.

## 8. What would actually answer the delivery-count question

None of these are free or self-serve, unlike the extracts used here:

- **T-MSIS Research Identifiable Files (RIF)**, via a ResDAC data use
  agreement — the real, non-suppressed, claim-line-level microdata.
  Months-long approval process.
- **State vital records (birth certificates)** — most states record
  attendant type (MD/DO/CNM) and payment source (Medicaid/private) per
  birth, the clinically correct data for this question, but public-use
  natality files (CDC WONDER) strip individual provider identity for
  privacy. Provider-NPI-level access requires a restricted-access request to
  a specific state's vital records office, typically for an approved
  research use.
- **CDC WONDER natality** — Medicaid-paid delivery counts by attendant type,
  state, county. Real signal, but aggregate; never tied to an individual
  NPI.

## 9. Reproducing

```r
# Both source datasets already downloaded and verified; NOT re-run here.
# download_medicaid_provider_spending.py          -> medicaid_provider_spending_verified.duckdb
# download_medicaid_provider_spending_ndc.py      -> medicaid_provider_spending_ndc_verified.duckdb
Rscript analyze_medicaid_procedure_billing_ob_midwife.R
```

## 10. Author / date

Tyler Muffly, MD + Claude Code. 2026-10-26.
