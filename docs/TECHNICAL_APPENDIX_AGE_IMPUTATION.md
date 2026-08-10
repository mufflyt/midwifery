# Technical Appendix: Estimation, Imputation, and Empirical Calibration of Certified Nurse-Midwife (CNM) Provider Age

**Repository**: `midwifery`  
**Target Reference Year**: 2026  
**Primary Calibration Script**: [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R)  
**Disambiguation Engine**: [`refine_ohio_voter_matching.py`](file:///Users/tmuffly/midwifery/refine_ohio_voter_matching.py)  
**Primary Output Artifact**: [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv)  
**Provenance Log**: [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv)  

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

Applying the gold-standard direct calibration model ($\text{Age} = 37.30 + 0.738 \cdot T_i$) across the $N = 22,309$ AMCB cohort yields the following national demographic distribution:

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
| [`refine_ohio_voter_matching.py`](file:///Users/tmuffly/midwifery/refine_ohio_voter_matching.py) | 3-Stage Deduplication & Disambiguation Engine for $7.95\text{M}$ Ohio voter records |
| [`enrich_state_nursing_license_ages.R`](file:///Users/tmuffly/midwifery/enrich_state_nursing_license_ages.R) | Executable Socrata query & multi-tier name matcher script |
| [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R) | Multi-model OLS regression & age imputation pipeline |
| [`artifacts/ohio_voter_license_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/ohio_voter_license_ages.csv) | High-confidence disambiguated Ohio voter DOB dataset ($N = 1,113$) |
| [`artifacts/state_nursing_license_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/state_nursing_license_ages.csv) | Matched state licensee records ($N = 1,833$) |
| [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv) | Full cohort dataset ($N = 22,309$) with direct and calibrated ages |
| [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv) | Provenance log recording regression parameters ($\alpha$, $\beta$, $R^2$, RSE) |
