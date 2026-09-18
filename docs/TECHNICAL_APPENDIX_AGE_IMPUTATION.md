# Technical Appendix: Estimation, Imputation, and Empirical Calibration of Certified Nurse-Midwife (CNM) Provider Age

**Repository**: `midwifery`  
**Target Reference Year**: 2026  
**Primary Calibration Script**: [`calibrate_amcb_certification_ages.R`](../calibrate_amcb_certification_ages.R)  
**Disambiguation Engine**: [`refine_ohio_voter_matching.py`](../refine_ohio_voter_matching.py)  
**Primary Output Artifact**: [`artifacts/amcb_calibrated_ages.csv`](../artifacts/amcb_calibrated_ages.csv)  
**Provenance Log**: [`artifacts/amcb_age_calibration_provenance.csv`](../artifacts/amcb_age_calibration_provenance.csv)  

---

## 1. Executive Summary & Problem Statement

National health workforce registries—including the National Plan and Provider Enumeration System (NPPES), the American Midwifery Certification Board (AMCB) public roster, and the CMS Doctors and Clinicians (DAC) file—do not directly report provider dates of birth or exact chronological ages.

While commercial directories (such as Healthgrades) expose exact age for a subset of providers, public attribute coverage is partial (~13.4% fill rate across active CNMs). Furthermore, scraping authenticated platforms such as Doximity presents access barriers, authentication requirements, and rate-limiting/ban risks.

To achieve **100% cohort age coverage** with guaranteed zero false-positive identity contamination, this project implements:
1. **A 3-Stage Disambiguation & Deduplication Engine**: Evaluates $7.95\text{ Million}$ Ohio voter records against the AMCB national cohort, categorizing matches into unambiguous unique names, geographically disambiguated matches, and excluded collisions.
2. **Gold-Standard Empirical Calibration**: Fits ordinary least squares (OLS) regression models over $N = 2,052$ 100% verified direct birth dates (**Ohio Secretary of State Voter Database direct DOBs**, **Washington State DOH direct 4-digit birth years**, and **Healthgrades provider ages**).

---

## 2. 3-Stage Deduplication & Disambiguation Engine

When evaluating $7.95\text{ Million}$ registered voter records, common name collisions (e.g., *"Sarah Miller"* or *"Jennifer Davis"*) can occur multiple times across a state. To eliminate false-positive identity matches:

$$\begin{array}{l|c|l}
\mathbf{Disambiguation\ Tier} & \mathbf{Confidence} & \mathbf{Selection\ Rule} \\
\hline
\text{1. Unambiguous Unique Name} & \mathbf{1.00} & \text{Name appears } N_{\text{voter}} = 1 \text{ time in all } 88 \text{ Ohio counties.} \\
\text{2. Geographically Disambiguated} & \mathbf{0.95} & N_{\text{voter}} > 1 \text{, but exactly } 1 \text{ record matches NPPES practice/home city or ZIP.} \\
\text{3. Ambiguous Collision Excluded} & \mathbf{0.00} & N_{\text{voter}} > 1 \text{ and city/ZIP cannot resolve tie. } \mathbf{Excluded\ from\ calibration.} \\
\end{array}$$

### Empirical Results of Disambiguation ($7.95\text{M}$ Ohio Voter Records)
* **Unambiguous Unique Name Matches ($N_{\text{voter}} = 1$)**: **$1,082$ midwives** ($100\%$ confidence).
* **Geographically Disambiguated Matches ($N_{\text{voter}} > 1$)**: **$31$ midwives** ($95\%$ confidence).
* **Ambiguous Collisions Excluded**: **$1,952$ candidate collisions** dropped to guarantee zero false positives.
* **Total High-Confidence Ohio DOBs**: **$1,113$ verified midwives**.

---

## 3. Empirical Calibration Models & Statistical Evaluation

### 3.1 Model 1: Gold-Standard Direct Ground-Truth Model (Disambiguated OH DOBs + WA Direct + Healthgrades)

> **Superseded — history only.** This is the 2,052-record fit. It was replaced
> on 2026-08-10 by the 5,448-record refit described in §3.2 and §4, which is
> what `artifacts/amcb_age_calibration_provenance.csv` holds and what every
> current run applies: $\text{Age} = 35.864 + 0.9428 \cdot T_i$.

* **Sample**: $N = 2,052$ certificants with 100% verified direct dates of birth from the Ohio Secretary of State Voter Database (`OH_Voter_Direct_DOB`), Washington State DOH (`WA_Direct_BirthYear`), and verified Healthgrades ages.
* **Regression Formula**:
  $$\text{Age}_{\text{Direct}} = 37.30 + 0.738 \cdot T_i$$
* **Statistical Performance**:
  * **Sample Coverage**: **$2,052$ certificants ($9.2\%$ of full national cohort)**
  * **Coefficient of Determination ($R^2$)**: $\mathbf{0.2752}$ (**27.5% of continuous age variance explained**)
  * **Residual Standard Error (RSE)**: $\mathbf{11.13\text{ years}}$ ($DF = 2,050$)
  * **Implied Mean Entry Age ($\hat{\alpha}$)**: $37.30\text{ years}$ ($p < 0.0001$)
  * **Tenure Progression Slope ($\hat{\beta}$)**: $0.738\text{ years per certified year}$ ($p < 0.0001$)

### 3.2 Illinois issue-date derivation — removed

An earlier calibration added Illinois IDFPR initial-APRN-licence issue dates,
back-calculated as `issue_year - 27`, to the direct sample. **Those values are
removed from the pipeline and the model built on them is deleted, not
deprecated.**

Validated against sources that record an actual birth year, the offset failed
in a consistent direction: **5.8% exact and 44.5% off by more than ten years**
against Healthgrades, versus 87.6% and 4.5% for WA licensing and 89.0% and 1.1%
for OH voter registration. They implied a median age of **34** against 41–54
from every measured source. An APRN licence is not issued at a fixed age, so
the offset encoded a career assumption as a measurement.

A `birth_year_source` flag travelled with them, but a flag does not protect a
value that `coalesce()` folds into `known_age` and everything downstream then
averages. A board that publishes no birth year now contributes no age.

Removing them did not shrink the calibration. The direct sample grew, on
measured data only, because the Healthgrades crawl completed at the same time:
**N 1,225 → 5,448, R² 0.550 → 0.721.**

## 4. Empirical Model Comparison Summary

| Model Metric | Gold-Standard Direct (in use) | Prior Literature Baseline |
| :--- | :---: | :---: |
| **Ground-Truth Calibration Size ($N$)** | **$5,448$** (was $2,052$) | Baseline Prior |
| **Identity Disambiguation Tier** | **100% Verified / De-duplicated** | Theoretical Literature |
| **Primary Age Source** | **OH Voter DOB / WA Direct / Healthgrades** | Theoretical Literature |
| **Implied Entry Age ($\hat{\alpha}$)** | $35.86\text{ years}$ | $29.50\text{ years}$ |
| **Variance Explained ($R^2$)** | **$0.721$** (was $0.550$) | N/A |

These are the current calibration, re-fitted 2026-08-10 after the Healthgrades
crawl completed and the derived values were removed. There is one model; the
Illinois-derived alternative is deleted rather than presented as a choice.

---

## 5. Cohort Imputation & Demographic Age Bands

### 5.0 Which model this section describes

Everything below the next paragraph was computed from
$\text{Age} = 37.30 + 0.738 \cdot T_i$ — the **§3.1 fit**, $N = 2{,}052$,
$R^2 = 0.275$, superseded on 2026-08-10. **It is retained as history and is not
the model in use.** The committed artifact
`artifacts/amcb_age_calibration_provenance.csv` holds
$\text{Age} = 35.864 + 0.9428 \cdot T_i$, $N = 5{,}448$, $R^2 = 0.721$, which
§3.2 and §4 describe and which every current run applies.

The two lines cross at $T = 7.0$ years certified and diverge after it — $+2.7$
years at 20 years certified, $+4.7$ at 30, $+6.8$ at 40 — so this is not a
rounding difference. The published bands are cut at 35/45/55/65, so a shift of
that size moves long-certified midwives across boundaries wholesale.

### 5.1 The imputed line under each model, on the current roster

The comparison below is the **imputed line alone**, $\hat{A}_i = \alpha + \beta
T_i$, applied to every certificant on the canonical 22,357-row roster (freeze
`1a7bd6a8`, all 22,357 rows carry a parseable `certification_date`). It is
reproducible from tracked files:

```r
source("R/lib/table1_bands.R")
r <- readr::read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", col_types = readr::cols(.default = "c"))
T_i <- 2026L - as.integer(stringr::str_extract(r$certification_date, "[0-9]{4}"))
table(band_hg_age(35.86433877 + 0.94276412 * T_i))
```

| | §5.2 as published (0.738) | artifact in use (0.9428) |
| :--- | ---: | ---: |
| Median | 51.3 y | **53.8 y** |
| Mean | 53.1 y | **56.0 y** |
| 1st / 3rd quartile | 42.5 / 60.9 y | 42.5 / **66.0** y |
| $<35$ years | 0 | 0 |
| $35$–$44$ years | 7,570 (33.9%) | 6,924 (31.0%) |
| $45$–$54$ years | 5,104 (22.8%) | 4,761 (21.3%) |
| $55$–$64$ years | 5,634 (25.2%) | 4,293 (19.2%) |
| $\ge 65$ years | **4,049 (18.1%)** | **6,379 (28.5%)** |

**The $\ge 65$ count is 2,330 certificants larger under the model actually in
use** — 28.5% against 18.1%, in the figure most likely to be quoted about an
ageing workforce. This is the opposite direction from §8.2's measured-source
refit, which moves the cohort *younger*; the two are independent and both
apply.

Neither column is the §5.2 table below. §5.2 blends measured ages in wherever a
direct source has one (`final_age = known_age` when present, `fitted_age`
otherwise), which is why it has a `<35 years` band at all — the fitted line has
a floor at its own intercept and cannot produce one. That blend cannot be
recomputed here: all five age sources are person-level and gitignored
(see §8.1 and #216). Regenerating §5.2 against the current model therefore
requires a run on the machine that holds them.

### 5.2 Superseded: the distribution published from the §3.1 fit

*Historical. Model $\text{Age} = 37.30 + 0.738 \cdot T_i$, roster $N = 22{,}309$
(the 2026-08-10 freeze, superseded by 22,357). Retained so the bands quoted in
earlier drafts can be traced.*

### Continuous Age Summary Statistics ($N = 22,309$)
* **Minimum**: $22.0\text{ years}$
* **1st Quartile**: $42.5\text{ years}$
* **Median**: $51.3\text{ years}$
* **Mean**: $52.7\text{ years}$
* **3rd Quartile**: $61.7\text{ years}$
* **Maximum**: $85.0\text{ years}$

### National Cohort Age Band Distribution
$$\text{Age Band}_i = \begin{cases} 
\text{"<35 years"} & \hat{A}_i < 35 \\
\text{"35-44 years"} & 35 \le \hat{A}_i < 45 \\
\text{"45-54 years"} & 45 \le \hat{A}_i < 55 \\
\text{"55-64 years"} & 55 \le \hat{A}_i < 65 \\
\text{">=65 years"} & \hat{A}_i \ge 65 
\end{cases}$$

| Age Band | Certificant Count ($N$) | Percentage (%) |
| :--- | :---: | :---: |
| **$<35$ years** | $748$ | $3.4\%$ |
| **$35$–$44$ years** | $7,042$ | $31.6\%$ |
| **$45$–$54$ years** | $4,732$ | $21.2\%$ |
| **$55$–$64$ years** | $5,551$ | $24.9\%$ |
| **$\ge 65$ years** | $4,236$ | $19.0\%$ |

---

## 5b. Multi-Source Age Triangulation (2026-08-10)

Age is the one demographic with several independent sources, so the sources can
be checked against each other rather than assumed. Coverage against the 11,913
ACTIVE primary-linked cohort:

| source | n | % of cohort | nature |
| :--- | ---: | ---: | :--- |
| Healthgrades `hg_age` | 3,099 | 26.0% | self-reported on a public profile |
| WA DOH licensing | 1,029 | 8.6% | measured birth year |
| OH voter registration | 203 | 1.7% | measured birth year |
| FL voter registration | 0 | 0% | **extract never obtained** |
| IL licensing (derived) | 0 | 0% | **withdrawn, see 3.2** |

Overlap is thin by construction — 3,311 midwives have exactly one source, 507
have two, and **only 2 have three**. Pairwise agreement is therefore reported
on the pairs that exist, not on a joint model.

**Where the sources line up.** Healthgrades self-report agrees with measured
birth years to a degree that is easy to under-credit: 87.6% exact against WA
licensing and 89.0% exact against OH voter registration, with a median
difference of exactly zero in both. Self-report is not the weak link.

**Where they do not.** The disagreement is concentrated in a tail, not spread:
4.5% of the WA pairs and 1.1% of the OH pairs are off by more than ten years.
That pattern is consistent with occasional identity error — the wrong person
matched to a profile — rather than with people misstating their age, which
would produce a smooth spread.

**Where the sources disagree about the population, not the person.** The
implied age distributions differ substantially:

| source | n | median | IQR | range |
| :--- | ---: | ---: | :--- | :--- |
| WA licensing | 1,029 | 46 | 40–55 | 27–95 |
| OH voter | 203 | 41 | 36–46 | 23–80 |
| Healthgrades | 3,099 | 54 | 44–64 | 28–94 |

These are not contradictions about individuals — the pairwise agreement above
rules that out. They are different *samples*. Healthgrades runs eight years
older than WA licensing and thirteen older than OH voter registration, which is
what selection into a public marketing profile would predict: an established
practice is more likely to maintain one. **Any age statistic quoted from
Healthgrades alone describes profile-holders, not the workforce.**

**Sources not yet obtained.** The Florida voter extract is pending and would add
a third measured birth-year source. Other states publishing voter birth years
or ages (MI, NC, OK, CO among them) are unexploited. `hg_education_year` is
present on 6% of profiles and would give a weak graduation-based proxy;
NPPES enumeration year and AMCB certification year are proxies for career
start, not birth, and are already the regressors the calibration models use —
they are not independent evidence about age.

## 6. Execution & Reproducibility Guide

To execute the 3-stage voter disambiguation and fit the calibrated age model:

```bash
cd /Users/tmuffly/midwifery

# Step 1: Run 3-Stage Disambiguation Engine over Ohio Statewide Voter Files (N = 1,113 verified DOBs)
python3 refine_ohio_voter_matching.py

# Step 2: Query state Socrata APIs (WA & IL)
./enrich_state_nursing_license_ages.R

# Step 3: Fit OLS calibration models and impute cohort ages
./calibrate_amcb_certification_ages.R
```

---

## 7. Artifact & Provenance Ledger

| Artifact File | Description |
| :--- | :--- |
| [`refine_ohio_voter_matching.py`](../refine_ohio_voter_matching.py) | 3-Stage Deduplication & Disambiguation Engine for $7.95\text{M}$ Ohio voter records |
| [`enrich_state_nursing_license_ages.R`](../enrich_state_nursing_license_ages.R) | Executable Socrata query & multi-tier name matcher script |
| [`calibrate_amcb_certification_ages.R`](../calibrate_amcb_certification_ages.R) | Multi-model OLS regression & age imputation pipeline |
| [`artifacts/ohio_voter_license_ages.csv`](../artifacts/ohio_voter_license_ages.csv) | High-confidence disambiguated Ohio voter DOB dataset ($N = 1,113$) |
| [`artifacts/state_nursing_license_ages.csv`](../artifacts/state_nursing_license_ages.csv) | Matched state licensee records ($N = 1,833$) |
| [`artifacts/amcb_calibrated_ages.csv`](../artifacts/amcb_calibrated_ages.csv) | Full cohort dataset ($N = 22,309$) with direct and calibrated ages |
| [`artifacts/amcb_age_calibration_provenance.csv`](../artifacts/amcb_age_calibration_provenance.csv) | Provenance log recording regression parameters ($\alpha$, $\beta$, $R^2$, RSE) |

---

## 8. Quality assurance (2026-09-18)

A QA pass over the age variable, run against the canonical freeze
`1a7bd6a8…`. Nothing here changed a pipeline; it records what was checked, what
held, and what did not. Four findings are tracked as issues.

### 8.1 Where the 5,448 direct ages come from

`direct_ground_truth_n = 5,448` is the number the whole age distribution rests
on, so it was traced source by source. Against the 11,913 ACTIVE primary-linked
cohort (§5b): Healthgrades 3,099, WA DOH 1,029, OH voter 203, Florida 0,
Illinois 0 — **4,331**. The remaining ~1,117 is scope, not a missing source:
§5b counts coverage *within* that cohort while the calibration fits over the
full 22,309-row roster, so ages for lapsed, retired and nursing-tier
certificants count toward 5,448 and not toward 4,331. That implies roughly
10.7% coverage outside the cohort against 36.4% inside, which is the expected
direction for certificants who are harder to match. It could not be verified
directly — every source file is person-level and gitignored — so it stands as
the only explanation consistent with the record rather than as a measurement.

**Doximity contributes nothing.** Its age sits behind a login wall,
`enrich_doximity_cnm_ages.R` requires a hand-downloaded input, no artifact
exists, and §5b does not list it. Any future reading of "five sources" should
be "three, of which one is self-reported".

### 8.2 The measured-source refit

§5b warns that "any age statistic quoted from Healthgrades alone describes
profile-holders, not the workforce". The fitted line is such a statistic —
Healthgrades is 3,099 of 5,448, larger than both measured sources combined — so
the model was refitted on measured birth years only. Ohio's data file no longer
exists (only its provenance), so this is WA direct, $N = 1{,}025$ of the 1,232
measured, with the script's own variable definitions
(`REF_YEAR = 2026`, ages clipped 21–85).

| | measured only (WA direct) | committed (57% Healthgrades) |
| :--- | ---: | ---: |
| model | Age = 36.18 + 0.847 · T | Age = 35.86 + 0.943 · T |
| $N$ | 1,025 | 5,448 |
| $R^2$ | 0.541 | 0.721 |
| RSE | 7.87 y | 7.39 y |

**The intercept survives the check and the slope does not.** Entry age at
certification is 36.2 measured against 35.9 committed — a third of a year. The
slope is about 11% steeper in the committed fit, and because it multiplies
tenure the gap compounds: +0.6 years at 10 years certified, +1.6 at 20, +2.6 at
30, +3.5 at 40.

That is the signature of selection rather than of inaccuracy, and it is
consistent with §5b's own evidence: per-person agreement with Healthgrades is
excellent (87.6% exact against WA), while the *samples* differ by 8–13 years in
median. Profile-holders are both older and longer-certified, so the correlation
between age and tenure is stronger in that subsample and the line rotates
upward around a fixed entry age.

Over the ACTIVE primary-linked cohort ($N = 12{,}171$), swapping one line for
the other moves **1,492 certificants (12.3%)** into a different published band,
every move in the same direction — older: 536 from 35–44 to 45–54, 424 from
45–54 to 55–64, 532 from 55–64 to ≥65. The `≥65` count is **596 measured
against 1,128 committed**, an 89% difference in the figure most likely to be
quoted about an ageing workforce. Tracked as
[#218](https://github.com/mufflyt/midwifery/issues/218).

**What shipped for it.** The refit above was a one-off. It is now part of the
calibration: §3b of `calibrate_amcb_certification_ages.R` fits the line on each
direct source separately and on the measured sources together, writes
`artifacts/amcb_age_calibration_by_source.csv`, and carries
`measured_ground_truth_n`, `measured_share_of_direct`, `measured_alpha`,
`measured_beta` and `measured_r2` in the provenance row — so the weight is
visible in the artifacts rather than argued in this appendix. Table 1's age
heading now states the direction of the bias where the ages are published. The
published model is unchanged: the measured-only line is a diagnostic, not a
replacement, because WA alone is itself a selected sample (§8.6).

### 8.3 Two hazards in how the number reaches print

**The calibration degraded silently.** When no ground truth was available the
model selector did not stop: it substituted `DEFAULT_ENTRY_AGE` with a slope
of 1.0, labelled itself "Literature Prior (29.5y entry age)", imputed an age for
every certificant, and the table still reported "100% Cohort Coverage". [#172](https://github.com/mufflyt/midwifery/issues/172)
recorded this happening for real — `direct_ground_truth_n` collapsing 5,448 → 0
— and it was caught by someone reading a provenance column, not by a failure.
Every one of the five source files is gitignored, so a fresh clone reproduced
the fallback by default.

**Fixed** ([#216](https://github.com/mufflyt/midwifery/issues/216)).
`calibrate_amcb_certification_ages.R` now stops when neither sample clears 30
ground-truth ages, naming which of the five source files were absent and which
were present. `ALLOW_LITERATURE_PRIOR=1` keeps an exploratory run available and
stamps `selected_model` as `LITERATURE PRIOR, NOT A FIT`. Table 1's age block
heading is built from that same `selected_model` string rather than the bare
"100% Cohort Coverage", so a prior cannot reach print wearing a fit's label.

**§5 published a distribution from a superseded model.** It applied
Age = 37.30 + 0.738 · T (the §3.1 fit, $N = 2{,}052$, $R^2 = 0.275$) while the
artifact in use is Age = 35.86 + 0.943 · T ($N = 5{,}448$, $R^2 = 0.721$). The
two lines cross at 7.0 years certified and then diverge by up to 6.8 years at
40.

**Fixed** ([#217](https://github.com/mufflyt/midwifery/issues/217)). §3.1 and
§5.2 are marked as history, and §5.1 publishes the imputed line under both
models on the current 22,357-row roster: the $\ge 65$ band holds 6,379
certificants (28.5%) under the model in use against 4,049 (18.1%) under the
superseded one. §5.2's *blended* distribution cannot be regenerated without the
gitignored person-level sources, and is labelled rather than silently retained.

### 8.4 Vintage

The Table 1 age bands sum to **11,920** — the 2026-08-10 cohort — against a
canonical ACTIVE primary-linked count of **12,171**, and the calibration's own
`roster_source` records 22,309 rows against the canonical 22,357. The age rows
therefore describe a superseded cohort, the same staleness that
[#176](https://github.com/mufflyt/midwifery/issues/176) tracks for geography.

### 8.5 What is working

`provider_estimated_age` from the commercial directory is correctly refused.
It is an imputation — estimated age plus graduation year is the constant 2052
for every midwife who has it — and `trl_age_admission()` gates it, reporting
"not used" when it fails. No modelled age from that source reaches a published
figure.

### 8.6 What this pass does **not** establish

* **Ohio could not be included** in the refit; its data file is gone. Its
  median age is 41 against WA's 46, so including it would most likely flatten
  the measured slope further and widen the gap rather than close it.
* **WA is itself a selected sample** — certificants licensed in one state,
  matched by name. The refit is a measured-source comparison, not an unbiased
  reference.
* **No adjudicated ages exist.** Neither line is validated against a vital
  record for this cohort, and at RSE ≈ 7.4–7.9 years neither supports
  individual-level banding.
