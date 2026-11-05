# Technical Appendix: Comparing Table 1 Against AMCB's Own Published Workforce Data

**Repository**: `midwifery`
**Primary output compared**: [`docs/table1_midwives.md`](table1_midwives.md), [`artifacts/table1_midwives.csv`](../artifacts/table1_midwives.csv), [`artifacts/amcb_npi_geography_by_state.csv`](../artifacts/amcb_npi_geography_by_state.csv)
**External sources**: American Midwifery Certification Board, [Data and Research](https://www.amcbmidwife.org/about-amcb/data-and-research) — *2025 Demographic Report* (self-reported, as of 2026-01-01, N=14,802) and *Number of CNM & CM by State* (Aug 2026, N=15,322)
**Investigation date**: 2026-11-05

## 1. Why this exists

AMCB certifies and maintains the roster this entire project is built on top of, but AMCB's own published reports and this project's Table 1 describe that roster two different ways: AMCB asks certificants directly (self-report, every certification/recertification cycle); this project infers characteristics from federal and commercial sources linked by NPI, because the AMCB roster itself carries only name, certification number, credential and status — no demographics, no employment data, no self-reported anything.

Those are two independent measurements of a population that mostly overlaps. Where they agree, that is real external validation of the NPPES/AMCB linkage this project depends on. Where they disagree, that is either a genuine difference in what is being measured, or a defect worth chasing. This appendix is the comparison, done once, on the numbers available as of 2026-11-05.

**This is not a reconciliation.** AMCB's certificant database is not available to this project; nothing here can be joined person-by-person against it. Every comparison below is population-level, against AMCB's own published aggregates.

## 2. The denominator problem, solved by layer, not by one number

| Population | N | Source |
|---|---:|---|
| All AMCB certificants, Aug 2026 | 15,322 (144 CM) | AMCB state-count sheet |
| All AMCB certificants, Jan 2026 | 14,802 (140 CM) | AMCB demographic report |
| This project's `primary_midwifery`-linked population, any status | 14,640 | `artifacts/amcb_npi_geography_by_state.csv` |
| This project's Table 1 cohort (ACTIVE status + primary-tier NPI link) | 12,170 | `artifacts/table1_midwives.csv` |

The Table 1 cohort (12,170) is **not** comparable to AMCB's headline total (15,322) — it is a stricter subset, filtered to AMCB status `ACTIVE` (excluding Retired-in-good-standing, Lapsed, and other non-exit statuses the project does not currently fold back in) and requiring a confirmed primary-tier NPI link. This project's broader `primary_midwifery`-linked population, before the ACTIVE filter, is 14,640 — within 4.5% of AMCB's own Aug 2026 total. Most of the gap between 12,170 and 15,322 is the status filter, not a linkage failure.

## 3. Where the two measurements agree

| Characteristic | AMCB | Table 1 |
|---|---:|---:|
| Certified Nurse-Midwife | 99.05% | 99.0% |
| Certified Midwife | 0.95% | 1.0% |
| Female | 98.9% | 99.5% |
| Male | 0.6% | 0.5% |
| California (largest state) | 1,299 | 1,310 |

The credential split and sex distribution are close enough to read as the same population measured twice, through completely independent instruments (AMCB's own enrollment record vs. NPPES' administrative sex code). This is real corroboration of the linkage, not a coincidence — two unrelated sources should not agree this closely on a 12,000+-person population unless they are substantially describing the same people.

Sex is not a perfect match: AMCB's self-report instrument offers "Other" (0.1%) and "choose not to respond" (0.4%) options that NPPES' administrative code does not — NPPES only records F/M/X/U, and the cohort's X/U rows (19 people) are reported separately in Table 1 rather than folded into Female/Male. The two sources are not asking the same question, only a similar one.

## 4. Age: AMCB has ground truth this project does not

AMCB's demographic report gives the actual self-reported age distribution of every certificant:

| Age band | AMCB (N=14,802) |
|---|---:|
| 20-29 | 2.8% |
| 30-39 | 26.2% |
| 40-49 | 30.2% |
| 50-59 | 19.7% |
| 60-69 | 14.2% |
| 70+ | 6.9% |

Mean 48.2 years, SD 12.47.

This project has no birthdate source at all — not NPPES, not CMS DAC, not any source it holds directly from certificants. `calibrate_amcb_certification_ages.R` instead fits an OLS model on a 5,448-person ground-truth subsample (direct birthdates from Ohio and Florida voter files, Washington state birth years, and Healthgrades self-reported ages — 57% of that subsample is the Healthgrades slice, which `docs/TECHNICAL_APPENDIX_AGE_IMPUTATION.md` §8.2 already documents as skewing older than the directly-measured sources) and imputes an age for everyone else.

AMCB's published distribution is a real external benchmark for that model that this project has never checked itself against. **This is flagged as follow-up work, not done in this pass**: a direct comparison of the calibrated-age band distribution (Table 1's `Calibrated Age` block) against AMCB's own bands above, on a compatible bucketing, would say whether the imputation is capturing the true shape of the workforce's age distribution or just its central tendency.

## 5. What AMCB collects that this project cannot

AMCB's self-report instrument asks certificants directly for several things no source this project holds captures at all:

- **Race and ethnicity.** White 81.9%, Black or African American 9.1%, Asian 2.0%, more than one race 2.0%, Hispanic/Latino 6.1%. Zero coverage in this project — no federal source reports race/ethnicity for providers, and no commercial scrape this project runs captures it either.
- **Primary language and languages spoken in practice.** 4.2% report a primary language other than English; 22.3% report they see patients in Spanish. Table 1's own `Language` block states plainly: *"Not collected by NPPES, CMS DAC or the Healthgrades scrape."* AMCB had the answer the entire time — this project simply has no access to AMCB's certificant-level responses, only their published aggregate.
- **Employment status and salary.** AMCB asks re-certificants directly: full-time midwife 54.9%, part-time 18.9%, employed outside midwifery 11.3%, retired 3.8%. Full-time salary clusters at $100,000-$149,999 (65.1%). This project has no income data from any source, and its closest proxy — Trilliant's claims-derived work-site classification (hospital/clinic/FQHC/birth center) — measures *where* a midwife practices, not *how much* or *whether full-time*, which is a different question entirely.
- **Education, as degree type.** AMCB reports Master's Midwifery (58.2% of re-certificants), Master's Nursing (51.0%), DNP (11.5%). Table 1's `Training institution` block answers a different question — *which school*, from CMS DAC and Healthgrades — not *what degree*. The two are complementary, not comparable.

None of this is recoverable from public federal data. It would require either direct data-sharing with AMCB or a parallel self-report instrument, neither of which is in scope here. It is recorded as a limitation, not a gap this project can close with more extraction work.

## 6. Years certified: a real, compatible comparison

AMCB's own tenure bands, re-bucketed to this project's `<5 / 5-9 / 10-19 / 20-29 / >=30` scheme:

| Band | AMCB | Table 1 (this machine, partial-build test run) |
|---|---:|---:|
| <5 years | 25.7% | 20.0% |
| 5-9 years | 21.5% | 22.8% |
| 10-19 years (AMCB 10-15 + 16-20) | 24.7% | 28.6% |
| 20-29 years (AMCB 21-25 + 26-30) | 17.9% | 17.9% |
| >=30 years (AMCB 31-35 through 50+) | 10.0% | 10.6% |

The 10-19 and 20-29 bands land within a point or two of each other; the <5 band is the largest gap (25.7% vs. 20.0%). One plausible explanation: AMCB's tenure is measured against everyone certified, including people who later go inactive or drop out of the linkable NPPES population before much time passes — if newly-certified midwives are systematically less likely to have an established NPPES footprint yet, the ACTIVE-and-linked Table 1 cohort would under-represent the newest entrants relative to AMCB's full roster. Not confirmed here; a hypothesis worth checking against `yrs_observed` in the NPPES panel for the <5-years-certified subgroup specifically.

## 7. Geography: the most actionable finding in this comparison

AMCB's Aug 2026 state-count sheet gives an exact, authoritative count of certificants by primary work state. Compared against this project's own NPPES-derived `primary_midwifery` state distribution (`artifacts/amcb_npi_geography_by_state.csv`), the aggregate gap is small (-4.5% overall, see §2) but **not evenly distributed** — several large states are undercounted by double digits, and New York runs the other direction:

| State | AMCB (Aug 2026) | This project | Diff | % diff |
|---|---:|---:|---:|---:|
| California | 1,299 | 1,310 | +11 | +0.8% |
| New York | 1,104 | 1,236 | +132 | **+12.0%** |
| Florida | 961 | 835 | -126 | **-13.1%** |
| Texas | 678 | 634 | -44 | -6.5% |
| Georgia | 645 | 548 | -97 | **-15.0%** |
| North Carolina | 641 | 559 | -82 | **-12.8%** |
| Pennsylvania | 593 | 560 | -33 | -5.6% |
| Michigan | 559 | 475 | -84 | **-15.0%** |
| Washington | 558 | 547 | -11 | -2.0% |
| Illinois | 551 | 514 | -37 | -6.7% |
| Ohio | 535 | 524 | -11 | -2.1% |
| Colorado | 496 | 487 | -9 | -1.8% |
| Massachusetts | 474 | 490 | +16 | +3.4% |
| Minnesota | 449 | 426 | -23 | -5.1% |
| Virginia | 444 | 366 | -78 | **-17.6%** |
| Oregon | 415 | 429 | +14 | +3.4% |
| Tennessee | 376 | 296 | -80 | **-21.3%** |

(Full 51-jurisdiction table, including every small-N state where percentage swings are noisy and less meaningful, is in `artifacts/table1_amcb_state_comparison.csv`.)

**Reading this table.** The pattern is not random scatter around zero — it is a consistent undercount across most large states, concentrated enough (Georgia, Michigan, North Carolina, Virginia, Tennessee all −13% to −22%) that it is unlikely to be pure linkage noise. New York is the one large state running the opposite direction, by a wide margin (+12%). Three non-exclusive explanations, none confirmed here:

1. **NPPES practice-state lag.** A midwife who moved states keeps her prior practice address in NPPES until she updates it; if movers skew toward specific states (e.g., into New York, out of Georgia/Michigan/Virginia), that alone could produce exactly this asymmetric pattern.
2. **"Primary work state" vs. derived practice state are different questions.** AMCB asks certificants to self-report their primary work state directly; this project derives practice state from NPPES' administrative practice address, which may not be the same place a multi-site or multi-state midwife would call "primary."
3. **AMCB's total (15,322) includes everyone in good standing, not just this project's stricter ACTIVE+linked definition** — if certain states have a disproportionate share of midwives who are AMCB-ACTIVE but not NPI-linked (or not linked to a `primary_midwifery` tier), that alone would produce a state-level undercount unrelated to any data quality issue in the linkage itself.

This is flagged as a genuine, unresolved finding — not a defect confirmed and fixed, a direction for the next investigation.

## 8. What this project has that AMCB's report does not

AMCB's own published reports contain no clinical-practice or federal-claims data at all. This project's Table 1 and its surrounding artifacts carry several dimensions AMCB does not publish:

- Hospital affiliation via CCN (privilege, count, type, ownership, birthing-friendly designation), from the CMS facility-affiliation file
- Practice setting from Trilliant claims data (hospital / clinic / FQHC / birth center), independent of the CCN-based measure above
- Medicare Part B and Part D participation, 2013-2023
- Multi-state license status and a second independent specialty/taxonomy field, both from the Open Payments provider-profile registry
- Cross-validation of practice state against up to ten independent sources (NPPES, CMS DAC, Open Payments, PECOS, Facility Affiliation, Healthgrades, Doximity, state boards of nursing, CMS NDH, Medicaid) — see [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md)

AMCB's report is the better instrument for who midwives are (demographics, employment, training); this project is the better instrument for what the federal claims record shows them doing. The two are complements, not competitors, and this comparison is useful precisely because neither one alone answers both questions.

## 9. What this does and does not establish

**Does establish**: the NPPES/AMCB linkage this entire project depends on produces a population whose credential split and sex distribution closely match AMCB's own authoritative figures — real, population-level corroboration of the linkage. It also surfaces one concrete, actionable discrepancy (state-level geography) and one concrete benchmarking opportunity (age-model validation) that did not exist before this comparison.

**Does not establish**: person-level agreement (no person-level AMCB data is available to check against), the cause of the state-level geography gap (three hypotheses offered, none tested), or how well the age-calibration model's distribution matches AMCB's published bands (flagged, not yet done).

## 10. Reproducing

```bash
# This project's state distribution (already a tracked artifact):
# artifacts/amcb_npi_geography_by_state.csv

# AMCB source documents, fetched 2026-11-05:
# https://www.amcbmidwife.org/docs/default-source/default-document-library/2025-demographic-report--final.pdf
# https://www.amcbmidwife.org/docs/default-source/default-document-library/number-of-cnm-cm-by-state---aug-2026.pdf

# Years-certified comparison used a partial-build test run
# (ALLOW_PARTIAL_TABLE1=1 Rscript build_table1_midwives.R) on a machine
# holding the age-calibration and tenure-band inputs; the figures in §6 are
# not from the published docs/table1_midwives.md, which predates those blocks
# on this machine's last complete build.
```
