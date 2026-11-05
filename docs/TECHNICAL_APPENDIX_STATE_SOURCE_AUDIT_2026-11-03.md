# Technical Appendix: Practice-State Coverage and Cross-Source Agreement, 10 Sources

**Repository**: `midwifery`
**Primary scripts**: [`build_state_source_audit.R`](../build_state_source_audit.R), [`build_state_source_pairwise_audit.R`](../build_state_source_pairwise_audit.R), [`build_cross_source_comparison.R`](../build_cross_source_comparison.R), [`extract_physician_compare_historical_midwives.R`](../extract_physician_compare_historical_midwives.R), [`extract_historical_facility_affiliation.R`](../extract_historical_facility_affiliation.R), [`extract_open_payments_profile_supplement.R`](../extract_open_payments_profile_supplement.R), [`extract_pecos_revalidation_state_history.R`](../extract_pecos_revalidation_state_history.R), [`extract_open_payments_address_history.R`](../extract_open_payments_address_history.R), [`extract_open_payments_2025.R`](../extract_open_payments_2025.R)
**Related**: [`TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md`](TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md), [`TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md`](TECHNICAL_APPENDIX_DAC_OPENPAYMENTS_ADDRESS_AGREEMENT.md), `~/mysterymedicaid/R/mm_record_staleness.R` (the freshness-tuning pattern this appendix follows)
**Narrative companion**: [`VIGNETTE_STATE_SOURCE_AUDIT_2026-11-04.md`](VIGNETTE_STATE_SOURCE_AUDIT_2026-11-04.md) — a story-driven walk through these same findings, for a reader who wants the "why it matters" before the tables
**Investigation date**: 2026-11-02 to 2026-11-03 (revised twice on 2026-11-03:
DAC/Physician Compare extended from 5 vintages to full annual coverage,
2013-2026, then Open Payments extended from 2021-2024 to 2021-2025 -- see
revision notes below)

**Revision note 1 (2026-11-03)**: an earlier pass of this audit reported DAC/
Physician Compare coverage as five discrete vintages (2013, 2014, 2015, 2016,
2026) and described 2017-2025 as an inaccessible nine-year hole -- NBER's
mirror stops at April 2016, which remains true. What was missed is that
`/Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb` -- already mounted,
already used elsewhere in this audit -- had the 2017-2025 vintages sitting in
it the whole time (`physician_compare_<year>_Q2` tables plus a 2017 archive
table), never checked before concluding the gap was real. §2 and §3 below now
reflect full annual DAC coverage. A follow-up sweep of the rest of the
external drive found no comparable gain for any of the other nine sources
(checked: Open Payments 2013-2014 NPI linkage, which is confirmed genuinely
unpopulated, not just unchecked; PECOS pre-2021; Facility Affiliation
history; a second CMS NDH pull; additional Healthgrades/Doximity/BON
snapshots; Medicaid's true date range).

**Revision note 2 (2026-11-03)**: this audit had also claimed "CMS's own
historical API is blocked from this sandbox" (true for the specific
endpoints tried earlier) and left Open Payments at 2021-2024. Re-tested on a
direct question from the user: `openpaymentsdata.cms.gov`'s metastore API and
`download.cms.gov` both answer normally now, and CMS has already published
PY2025 General Payment Data (9.2GB,
`PGYR2025_P06302026_06032026/OP_DTL_GNRL_PGYR2025_P06302026_06032026.csv`).
Downloaded to `/Volumes/MufflySamsung/open_payments_data/2025/unzipped_files/`
and extracted with `extract_open_payments_2025.R` — 22,069 payment rows,
4,382 distinct cohort NPIs, 96.1% agreement with NPPES (consistent with the
existing 96-97% band). §2 and §3 now include 2025. Whether the earlier block
was a real, now-resolved Akamai restriction or a transient/session-specific
issue is unclear — it's worth re-checking data.cms.gov directly before
assuming it's blocked again in a future session, rather than reusing this
conclusion.

**Revision note 3 (2026-11-04)**: Facility Affiliation had been reported as
`current_only` — CMS's own Facility Affiliation product, verified against its
metastore API, genuinely is a single always-current snapshot (one dataset
entry, no year in the title, modified 2026-10-02). But the historical DAC/
Physician Compare vintages extracted for §2/§3 already carry hospital
affiliation CCNs embedded in the file itself (`ccn_1..ccn_5`, same
"Claims based hospital affiliation CCN" / `hosp_afl_1..5` fields used there),
unused for this purpose until now. `extract_historical_facility_affiliation.R`
pulls those CCNs for 2013-2022 (91,414 — 11,414 NPI-years with at least one
CCN before hospital resolution, 11,102 after — fill rate declines from 83.2%
in 2013 to ~26-31% by 2019-2022, reported as observed, not explained further;
CMS dropped the field entirely starting 2023), resolves each CCN against
`cms_hospital_info` (92.0% resolve to a named hospital), and takes the first
resolved CCN's state per NPI-year where a midwife has more than one — an
arbitrary tie-break, not a documented primary affiliation, since CMS gives no
rank or admission volume to break the tie honestly. Facility Affiliation now
runs 2013-2022 + 2026 and moved from §3 (single-snapshot) into §2/§3's
multi-year tables, with the highest agreement of the four continuous sources,
92.7-96.0%.

## 1. Why this exists, and what it does not establish

**There is no gold standard for a midwife's practice state.** Every source
below is self-reported (NPPES), administratively enrolled (DAC/Physician
Compare, PECOS revalidation, Medicaid), third-party-scraped (Healthgrades,
Doximity, state Boards of Nursing), or FHIR-published (CMS's National
Directory of Healthcare Providers, "NDH"). "Agreement" in this appendix means
**pairwise agreement against NPPES specifically** — NPPES is used as the
comparison anchor only because every other source's NPI already links through
the cohort via NPPES, not because it is assumed correct. A low agreement
number does not mean the other source is wrong, and a high one does not mean
NPPES is right.

**Freshness is tuned per source, not assumed from download time**, following
`mm_record_staleness.R`'s principle (a record's own last-updated/vintage date
is what tells you which year its information actually applies to, not when
this project happened to fetch the file). Concretely:

- Sources with a **real, dated vintage per record or per release** (DAC/
  Physician Compare's own file vintage, Open Payments' `program_year`, PECOS
  revalidation's monthly `vintage`, Medicaid's T-MSIS enrollment interval
  dates) are compared against NPPES's **same-year** snapshot.
- Sources with only **one current snapshot** (Healthgrades, state Boards of
  Nursing, CMS NDH/FHIR) are compared only against NPPES's **current (2026)**
  snapshot and flagged `comparison_basis = "current_only"` — never silently
  treated as covering every year. **Facility Affiliation moved out of this
  category 2026-11-04** — see Revision note 3.
- **Doximity** has a real per-profile `date_modified` field, but every
  matched profile's value falls in 2026 regardless of when the midwife's
  information actually changed — it reflects Doximity's own site activity,
  not a usable historical vintage. Reported as a single 2026 point, same as
  the undated sources, with this caveat explicit.
- **NPPES itself** does not currently have a true per-record freshness field
  in this project — `last_update_date` is present in the raw NPPES files
  (confirmed via `audit_2013_dac_vs_nppes.R`) but is not yet extracted into
  `midwife_panel.csv`. This means NPPES is compared at face value (its
  snapshot year), not classified as "provably stale" the way isochrones'
  `e1_last_update_staleness.R` / `mm_check_state_staleness()` can for sources
  that do carry it. **Medicaid is the one source in this audit where that
  full classification already exists** (see §4) — it was built independently
  in `R/lib/medicaid_state_concordance.R` before this audit and is folded in
  as-is rather than reduced to a single percentage.

## 2. Coverage by source and year

Full table: [`artifacts/state_source_audit_coverage.csv`](../artifacts/state_source_audit_coverage.csv).

| Source | Years covered | Notes |
|---|---|---|
| NPPES | 2007-2026 (every year) | Backbone; 92,042 → 425,990 provider-years, growing with the panel |
| DAC / Physician Compare | 2013-2026, every year | 2013-2016 from NBER's mirror; 2017-2025 from `physician_compare_<year>_Q2` tables (plus a 2017 archive table) already present in `nber_my_duckdb.duckdb`; 2026 is the current CMS live pull. Hospital-affiliation CCN columns are embedded 2013-2022, dropped by CMS from the file itself starting 2023 |
| Open Payments | 2015-2025 | 2013-2014 impossible (no NPI column in CMS's own file); 2015-2020 near-zero (1-29 rows/year) because CNMs were not Open-Payments-reportable until the SUPPORT Act expansion hit program year 2021; 2021-2025 real (2,391-4,382 NPIs/year) |
| PECOS revalidation/reassignment | 2021-2026 | Monthly CMS releases (40 vintages), one row per NPI per year (year-end vintage); 8,216-10,305 NPIs/year |
| Facility Affiliation (CCN↔NPI) | 2013-2022, 2026 | 2013-2022 from CCNs embedded in the historical DAC files (see Revision note 3); 2026 from CMS's current Facility Affiliation product, itself a single always-current snapshot with no archived history; 2023-2025 has no CCN in either source |
| Healthgrades | 2026 only (single scrape) | No per-record date at all |
| Doximity | 2026 only (effectively) | Has `date_modified`, but it does not vary meaningfully across the matched cohort |
| State Boards of Nursing | 2026 only | 7 states with real matches: CO, CT, FL, IL, PA, TX, WA (`VERIFIED_LIVE_BON` status only; DE returned 0 matches) |
| CMS NDH (FHIR) | 2026 only | 15,444 of 16,775 cohort NPIs found; `meta.lastUpdated` exists per Practitioner resource but is not yet extracted into this audit's state-comparison path |
| Medicaid | 2018-2024 | See §4 — classified separately, not folded into the same-year/current-only table |

## 3. Agreement vs. NPPES

Full table: [`artifacts/state_source_audit_agreement.csv`](../artifacts/state_source_audit_agreement.csv).

| Source | Period | Basis | n comparable | % agree |
|---|---|---|---:|---:|
| DAC / Physician Compare | 2013 | same_year | 10,844 | 95.1% |
| DAC / Physician Compare | 2014 | same_year | 6,199 | 94.8% |
| DAC / Physician Compare | 2015 | same_year | 6,494 | 94.3% |
| DAC / Physician Compare | 2016 | same_year | 6,230 | 93.8% |
| DAC / Physician Compare | 2017 | same_year | 6,557 | 91.9% |
| DAC / Physician Compare | 2018 | same_year | 6,162 | 93.8% |
| DAC / Physician Compare | 2019 | same_year | 4,621 | 92.6% |
| DAC / Physician Compare | 2020 | same_year | 4,483 | 94.2% |
| DAC / Physician Compare | 2021 | same_year | 5,023 | 93.0% |
| DAC / Physician Compare | 2022 | same_year | 5,068 | 92.3% |
| DAC / Physician Compare | 2023 | same_year | 5,008 | 92.5% |
| DAC / Physician Compare | 2024 | same_year | 5,354 | 91.8% |
| DAC / Physician Compare | 2025 | same_year | 5,278 | 92.6% |
| DAC / Physician Compare | 2026 | same_year | 5,575 | 89.8% |
| Open Payments | 2021 | same_year | 14,441 | 96.2% |
| Open Payments | 2022 | same_year | 19,349 | 96.5% |
| Open Payments | 2023 | same_year | 19,261 | 96.1% |
| Open Payments | 2024 | same_year | 18,720 | 97.5% |
| Open Payments | 2025 | same_year | 21,731 | 96.1% |
| PECOS revalidation | 2021 | same_year | 7,979 | 88.7% |
| PECOS revalidation | 2022 | same_year | 8,588 | 88.1% |
| PECOS revalidation | 2023 | same_year | 9,071 | 87.8% |
| PECOS revalidation | 2024 | same_year | 9,674 | 88.5% |
| PECOS revalidation | 2025 | same_year | 10,096 | 88.3% |
| PECOS revalidation | 2026 | same_year | 9,736 | 88.0% |
| Doximity | 2026 | same_year | 4,701 | 95.9% |
| Facility Affiliation (CCN) | 2013 | same_year | 1,877 | 94.5% |
| Facility Affiliation (CCN) | 2014 | same_year | 1,080 | 96.0% |
| Facility Affiliation (CCN) | 2015 | same_year | 1,189 | 95.2% |
| Facility Affiliation (CCN) | 2016 | same_year | 1,279 | 95.2% |
| Facility Affiliation (CCN) | 2017 | same_year | 1,421 | 93.7% |
| Facility Affiliation (CCN) | 2018 | same_year | 885 | 95.0% |
| Facility Affiliation (CCN) | 2019 | same_year | 693 | 94.2% |
| Facility Affiliation (CCN) | 2020 | same_year | 667 | 94.6% |
| Facility Affiliation (CCN) | 2021 | same_year | 891 | 93.9% |
| Facility Affiliation (CCN) | 2022 | same_year | 889 | 93.8% |
| Facility Affiliation (CCN) | 2026 | same_year | 1,675 | 92.7% |
| Healthgrades | current | current_only | 17,772 | 91.8% |
| State Boards of Nursing | current | current_only | 665 | 96.1% |
| CMS NDH (FHIR) | current | current_only | 15,340 | 89.9% |

(2015/2016/2019/2020 Open Payments rows are omitted — n is 1-17, too small to
report a meaningful percentage, consistent with §2's explanation.)

**Reading this table**: with the full 2013-2026 run now in hand, DAC/
Physician Compare does *not* decline smoothly — the earlier 5-point version
of this table looked like a steady drift because it skipped straight from
2016 to 2026. In fact it holds in a 91.8-95.1% band for thirteen straight
years (2013-2025, no clear trend inside that band) and only drops to 89.8%
in the single most recent year, 2026. Whether 2026 is the start of a real
decline or a one-year wobble can't be told from one point; next year's DAC
pull is the test. Open Payments stays consistently high (96-98%) across its
real years, now five of them (2021-2025). PECOS revalidation sits notably lower (87.8-88.7%) than every
other administrative source across all six of its years — flat and
consistent, not a one-year anomaly, which argues against a single bad
vintage and for a structural difference between how PECOS revalidation's
enrollment state and NPPES's self-reported practice state are populated.
Facility Affiliation, newly extended back to 2013 (Revision note 3), sits
consistently above all three — 92.7-96.0% across its eleven years — making it
the highest-agreeing multi-year source in this audit, not just the
highest-agreeing current snapshot it used to be reported as.
None of this has been investigated further in this pass; it is reported as
observed, not explained.

## 4. Medicaid: classified, not reduced to a percentage

Medicaid is the one source here with a genuine independently-dated,
per-NPI-year classification already built (`R/lib/medicaid_state_concordance.R`'s
`classify_state_concordance()`, run by `analyze_medicaid_enrollment_concordance.R`
before this audit) — it mirrors `mm_check_state_staleness()`'s own logic
(disagreement against the earliest independently-dated interval). Full table:
[`artifacts/medicaid_enrollment_concordance_any_time_by_year.csv`](../artifacts/medicaid_enrollment_concordance_any_time_by_year.csv).

| Year | Concordant | Discordant | Multistate concordant | Multistate discordant | Indeterminate | Not observed |
|---|---:|---:|---:|---:|---:|---:|
| 2018 | 2,565 | 692 | 813 | 161 | 4,288 | 3,651 |
| 2019 | 2,731 | 715 | 947 | 175 | 3,715 | 3,887 |
| 2020 | 2,849 | 772 | 1,004 | 208 | 3,258 | 4,079 |
| 2021 | 2,982 | 786 | 1,054 | 222 | 2,864 | 4,262 |
| 2022 | 2,988 | 865 | 1,105 | 242 | 2,379 | 4,591 |
| 2023 | 3,063 | 945 | 1,124 | 261 | 1,742 | 5,035 |
| 2024 | 2,947 | 1,035 | 1,003 | 262 | 652 | 6,271 |

Restricting to NPI-years where a comparison is actually possible (Concordant
+ Discordant + both Multistate rows), simple concordance runs **79.8% (2018)
→ 75.3% (2024)**, dipping as low as 77.6% in 2023 before that — a shallow
but real decline — and "Not observed" (Medicaid
has no record at all for that NPI-year) grows from 3,651 to 6,271 over the
same span, which is itself informative: a shrinking share of the cohort has
ANY Medicaid enrollment evidence in the most recent years, most plausibly
because Medicaid enrollment segment data takes time to be published and the
most recent years are the least complete, not because midwives are actually
leaving Medicaid panels.

## 5. Beyond pairwise-vs-NPPES: pairwise, consensus, and longitudinal flow

Everything through §4 is one-vs-NPPES. That can't distinguish "this source is
wrong" from "NPPES is wrong" — it can only say the two disagree. Three
further analyses, added 2026-11-04, start to answer the harder question.

**Full pairwise matrix** (`build_state_source_pairwise_audit.R`, via
`mysteryroster::attribute_agreement()`, which merges every pair by
`(npi, year)` rather than anchoring to one source): 36 non-NPPES pairs clear
a 30-comparable-NPI-year floor. The three sources with real multi-year
overlap (DAC, Open Payments, PECOS revalidation, 2021-2026) sit in a 90-94%
band pairwise — including PECOS, whose NPPES-anchored agreement (§3) is the
lowest of any source at 87.8-88.7%. Compared directly against DAC and Open
Payments rather than NPPES, PECOS agrees about as well as they agree with
each other. Anchoring to NPPES made PECOS look like the outlier; pairwise,
it isn't one. Among the 21 same-year-2026 pairs across the six snapshot
sources, **CMS NDH is the common low point** — it disagrees most with four
different sources (DAC, Doximity, Healthgrades, PECOS), not just NPPES,
pointing at NDH itself rather than any single counterpart. Full table:
`artifacts/state_source_audit_pairwise_agreement.csv`.

**Per-NPI consensus score** (`build_cross_source_comparison.R`): for every
cohort NPI with ≥2 sources reporting a current state (n=16,939), what share
of those sources agree with the majority. **84.5% are unanimous** (14,314
NPIs), 7.2% majority (1,214), 8.3% split (1,411) — computed independently
of the pairwise matrix (one row per NPI across all sources at once, not pair
by pair), and the two agree on the headline: disagreement concentrates in a
minority of NPIs rather than spreading evenly. The unanimous rate declines
from 94% (2 sources reporting) to ~76% (6-7 sources) as more sources are
required to agree simultaneously — the expected effect of requiring more
independent raters to line up, not evidence the data got worse at higher N.
Table: `artifacts/cross_source_consensus_scores.csv`.

**Does disagreement persist or resolve?** For the 184 NPIs with NPPES, DAC,
Open Payments, and PECOS all present in every year 2021-2025 (a demanding
filter — n is small because of it), each NPI-year was classified Unanimous /
Majority / Split across those four sources and tracked year to year. The
dominant pattern is persistence: ~165-169 of 184 NPIs stay Unanimous every
single transition. A smaller, roughly constant churn (not accumulating)
moves a handful of NPIs between tiers each year, consistent with genuine
events an address or employer change — one source picks up before the
others — rather than random noise. Table:
`artifacts/cross_source_consensus_tier_flow.csv`.

Medicaid is excluded from all three analyses in this section, same as §4:
its source here is a pre-built Concordant/Discordant/Indeterminate
classification, not a raw per-NPI-year state value.

**Does license status predict disagreement?** (added 2026-11-04,
`extract_open_payments_profile_supplement.R`). Every analysis above could
flag "genuine multi-state practice vs. data-quality problem" as an
unresolved ambiguity but never test it, for lack of a source that captures
multi-state status directly. CMS's Open Payments Covered Recipient Profile
Supplement (`data/CMS_Open_Payments_Profile_Supplement.csv`, 1.69M rows) was
already read elsewhere in this project (`classify_residual_disagreements.R`,
via `harvest_open_payments_profile.py`) for its name/address fields only;
its `Covered_Recipient_Profile_License_State_Code_1..5` columns -- which
states a provider is *licensed* in, independent of every other source in
this audit -- had never been extracted. Matched against the cohort: 8,411 of
16,775 midwives (50.1%) have a profile record, and of those, 2,865 (34.1%)
show licenses in two or more states.

Joined against the Figure 7 consensus tiers (8,312 NPIs with both a
consensus score and a license-state profile): midwives licensed in exactly
one state are **92.4% Unanimous, 2.4% Split**; midwives licensed in two or
more states are **59.9% Unanimous, 22.1% Split** -- roughly nine times the
single-state Split rate. &chi;&sup2;(2, n=8,312) = 1,353.1, p < 2.2x10^-16.
This is a population-level association, not a per-NPI adjudication -- it
does not prove any one disagreement is a real multi-state practice rather
than a data error -- but it is strong evidence that genuine multi-state
practice is the dominant driver of cross-source disagreement in this cohort,
not the edge case this audit could previously only gesture at. Table:
`artifacts/cohort_midwives_open_payments_profile_supplement.csv`.

The same extraction also carries `Covered_Recipient_Profile_Primary_Specialty`
and three `OPS_Taxonomy` columns, a second independent specialty field per
provider -- 6,142 of 8,411 matched rows read "Advanced Practice Midwife"
outright; the remainder split across Nurse Practitioner, Nurse Anesthetist,
Registered Nurse, and other labels. Carried through in the output but not
yet analyzed here; whether that split reflects dual credentialing or
crosswalk imprecision in the underlying CMS taxonomy is open.

**Wired into Table 1 (2026-11-04, `build_table1_midwives.R`).** A new block,
"Multi-state license status (Open Payments provider profile)", follows the
same file-existence gate and per-block unknown-labeling convention as every
other Table 1 block -- `artifacts/cohort_midwives_open_payments_profile_supplement.csv`
was added to `TABLE1_ENRICHMENT`, so a Table 1 build missing it refuses to
publish rather than emit an empty category. Verified against the live
12,170-person ACTIVE/primary-linked Table 1 cohort (a different, stricter
cohort definition than this audit's 16,775-NPI `cohort_member` set, hence
the different denominator): 4,628 single-state, 2,492 multi-state (35.0%
of the 7,120 with a profile), 5,050 with no Open Payments provider profile
-- sums exactly to N. Not yet in a published Table 1 render; this machine
is missing five other, unrelated enrichment inputs (sex enumeration, DAC
education, HPSA status, Medicare participation, the ACOG crosswalk), none
of which this addition touches, and the build correctly refused to publish
a partial table rather than overwrite the real one.

## 6. What this does and does not establish

- **Pairwise still means pairwise, not against truth.** §5 adds 36
  non-NPPES pairs, but a few pairs still have no comparison at all — PECOS
  revalidation and State Boards of Nursing share zero NPIs in this cohort —
  and no pair here, NPPES-anchored or not, tells you which side of a
  disagreement is correct.
- **Open Payments' N counts payment transactions, not NPI-years.** A
  provider with five payments in one year contributes up to five comparison
  rows in §3 and §5 alike — a different unit than every other source's
  one-row-per-NPI-year.
- **The 5-year flow cohort in §5 is 184 NPIs** out of a ~5,000-10,000/year
  panel — requiring all four longitudinal sources present every year
  2021-2025 is a demanding filter, and that 184 is not necessarily
  representative of midwives who only appear in some years or some sources.
- **State Boards of Nursing cover 7 states only** (CO, CT, FL, IL, PA, TX,
  WA) — this is not a 50-state audit for that source, and the other sources'
  "coverage" numbers are national, not state-by-state breakdowns, in this
  first pass. A true state-by-state cut of every source (not just the
  state-scoped BON data) is future work, not done here.
- **NPPES's own staleness is not classified** in this pass, because
  `last_update_date` is not yet extracted into `midwife_panel.csv`. Every
  "disagreement" above could be NPPES being stale, the other source being
  stale, or a genuine multi-state practice — this audit cannot distinguish
  those without that field (see §1).
- **Healthgrades and the 7 state BON sources are single, non-reproducible
  snapshots** — re-running this audit next year will not show whether they
  have moved, only whether this project scraped them again.
- **Facility Affiliation's 2013-2022 state is an arbitrary tie-break, not a
  collapse rule.** A midwife with CCNs resolving to hospitals in two
  different states in the same year gets whichever CCN appeared first in the
  source file, not a documented "primary" affiliation — CMS gives no rank or
  admission volume to break the tie honestly. `n_ccns_resolved` is kept in
  `artifacts/historical_facility_affiliation_ccn_level.csv` so the
  multiplicity stays visible even though the state-comparison tables above
  collapse it to one value.

## 7. Reproducing

```bash
# Historical DAC/Physician Compare, 2013-2025 (2013-2016 from NBER downloads
# under data/raw/cms_physician_compare/<year>/, 2017-2025 from tables already
# in /Volumes/MufflySamsung/DuckDB/nber_my_duckdb.duckdb)
Rscript extract_physician_compare_historical_midwives.R

# Facility Affiliation, 2013-2022, from the CCNs embedded in the historical
# DAC files above -- must run after extract_physician_compare_historical_midwives.R
Rscript extract_historical_facility_affiliation.R

# Open Payments address history, 2015-2021 (2022-2024 already existed)
Rscript extract_open_payments_address_history.R

# Open Payments, 2025 -- direct CMS download, raw file at
# /Volumes/MufflySamsung/open_payments_data/2025/unzipped_files/ must exist first
Rscript extract_open_payments_2025.R

# PECOS revalidation/reassignment state history, 2021-2026
Rscript extract_pecos_revalidation_state_history.R

# The consolidated coverage + agreement tables
Rscript build_state_source_audit.R

# §5: full pairwise matrix, every non-NPPES pair
Rscript build_state_source_pairwise_audit.R

# §5: per-NPI consensus score, longitudinal tier flow, and the
# Wilson confidence intervals on the §3 agreement table
Rscript build_cross_source_comparison.R

# §5: license-state + specialty-taxonomy, from the Open Payments profile
# registry (data/CMS_Open_Payments_Profile_Supplement.csv)
Rscript extract_open_payments_profile_supplement.R
```
