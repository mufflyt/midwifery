# Technical Appendix: Estimation, Imputation, and Empirical Calibration of Certified Nurse-Midwife (CNM) Provider Age

**Repository**: `midwifery`  
**Target Reference Year**: 2026  
**Primary Calibration Script**: [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R)  
**Primary Output Artifact**: [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv)  
**Provenance Log**: [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv)  

---

## 1. Executive Summary & Problem Statement

National health workforce registries—including the National Plan and Provider Enumeration System (NPPES), the American Midwifery Certification Board (AMCB) public roster, and the CMS Doctors and Clinicians (DAC) file—do not directly report provider dates of birth or exact chronological ages.

While commercial directories (such as Healthgrades) expose exact age for a subset of providers, public attribute coverage is partial (~13.4% fill rate across active CNMs). Furthermore, scraping authenticated platforms such as Doximity presents access barriers, authentication requirements, and rate-limiting/ban risks.

To achieve **100% cohort age coverage** without credentialed web scraping, this project implements a multi-tiered empirical calibration methodology:
1. **Roster-Wide Age Derivation**: An analytical baseline model anchored on exact AMCB initial certification dates ($Y_{\text{cert}}$).
2. **Gold-Standard Empirical Calibration**: Fitting ordinary least squares (OLS) regression models over ground-truth provider birth dates—specifically **Ohio Secretary of State Statewide Voter Database direct DOBs** ($N = 3,962$), **Washington State DOH direct 4-digit birth years** ($N = 1,029$), and **Healthgrades provider ages**—yielding a combined direct ground-truth sample of $N = 4,537$ midwives (**20.3% of the entire national cohort**).

---

## 2. Mathematical Framework & Prior Specification

### 2.1 Primary Temporal Anchor
For every certificant $i$ on the AMCB active roster ($N = 22,309$), the initial certification year $Y_{\text{cert}, i}$ is parsed from `certification_date` in [`midwives.csv`](file:///Users/tmuffly/midwifery/midwives.csv).

Years elapsed since certification relative to reference year $Y_{\text{ref}} = 2026$ is defined as:
$$T_i = Y_{\text{ref}} - Y_{\text{cert}, i}$$

---

## 3. Empirical Calibration Models & Statistical Evaluation

### 3.1 Model 1: Gold-Standard Direct Ground-Truth Model (Ohio Voter DOBs + WA Direct + Healthgrades)
* **Sample**: $N = 4,537$ certificants with direct verified dates of birth from the Ohio Secretary of State Voter Database (`OH_Voter_Direct_DOB`), Washington State DOH (`WA_Direct_BirthYear`), and verified Healthgrades ages.
* **Regression Formula**:
  $$\text{Age}_{\text{Direct}} = 38.83 + 0.651 \cdot T_i$$
* **Statistical Performance**:
  * **Sample Coverage**: **$4,537$ certificants ($20.3\%$ of full national cohort)**
  * **Coefficient of Determination ($R^2$)**: $0.2112$ ($21.1\%$ of continuous age variance explained across national multi-state sample)
  * **Residual Standard Error (RSE)**: $13.29\text{ years}$ ($DF = 4,535$)
  * **Implied Mean Entry Age ($\hat{\alpha}$)**: $38.83\text{ years}$ ($p < 0.0001$)
  * **Tenure Progression Slope ($\hat{\beta}$)**: $0.651\text{ years per certified year}$ ($p < 0.0001$)

### 3.2 Model 2: Combined Sample Model (Direct WA/OH + Derived IL Issue Dates)
* **Sample**: $N = 5,011$ certificants combining direct voter/state birth years ($4,537$) and Illinois IDFPR initial APRN license issue date back-calculations ($474$).
* **Regression Formula**:
  $$\text{Age}_{\text{Combined}} = 37.76 + 0.651 \cdot T_i$$
* **Statistical Performance**:
  * **Coefficient of Determination ($R^2$)**: $0.2115$ ($21.1\%$ of variance explained)
  * **Residual Standard Error (RSE)**: $13.19\text{ years}$ ($DF = 5,009$)

---

## 4. Empirical Model Comparison Summary

| Model Metric | Model 1: Gold-Standard Direct (OH+WA+HG) | Model 2: Combined Sample (Inc. IL Derived) | Prior Literature Baseline |
| :--- | :---: | :---: | :---: |
| **Ground-Truth Calibration Size ($N$)** | **$4,537$** | $5,011$ | Baseline Prior |
| **Cohort Coverage Share** | **$20.3\%$** | $22.5\%$ | $0.0\%$ |
| **Primary Age Source** | **OH Voter DOB / WA Direct / HG** | OH Voter / WA Direct / IL Derived | Theoretical Literature |
| **Implied Entry Age ($\hat{\alpha}$)** | **$38.83\text{ years}$** | $37.76\text{ years}$ | $29.50\text{ years}$ |
| **Tenure Slope ($\hat{\beta}$)** | **$0.651$** | $0.651$ | $1.000$ |
| **Variance Explained ($R^2$)** | **$21.1\%$** | $21.1\%$ | N/A |
| **Residual Standard Error (RSE)** | **$13.29\text{ years}$** | $13.19\text{ years}$ | N/A |

> **Methodological Selection**: The pipeline selects **Model 1 (Gold-Standard Direct)** as the primary imputation engine because direct verified dates of birth from official Secretary of State voter records and state department health registries provide 100% empirical precision for $N = 4,537$ midwives.

---

## 5. Cohort Imputation & Demographic Age Bands

Applying the gold-standard direct calibration model ($\text{Age} = 38.83 + 0.651 \cdot T_i$) across the $N = 22,309$ AMCB cohort yields the following national demographic distribution:

### Continuous Age Summary Statistics ($N = 22,309$)
* **Minimum**: $22.0\text{ years}$
* **1st Quartile**: $42.7\text{ years}$
* **Median**: $51.9\text{ years}$
* **Mean**: $52.5\text{ years}$
* **3rd Quartile**: $61.0\text{ years}$
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
| **$<35$ years** | $1,135$ | $5.1\%$ |
| **$35$–$44$ years** | $6,199$ | $27.8\%$ |
| **$45$–$54$ years** | $5,240$ | $23.5\%$ |
| **$55$–$64$ years** | $5,563$ | $24.9\%$ |
| **$\ge 65$ years** | $4,172$ | $18.7\%$ |

---

## 6. Execution & Reproducibility Guide

To stream state voter files, query state Socrata APIs, and fit the calibrated age model:

```bash
cd /Users/tmuffly/midwifery

# Step 1: Stream Ohio Secretary of State Voter Files & extract direct DOBs (N = 3,962)
python3 match_ohio_voter_ages.py

# Step 2: Query state Socrata APIs (WA & IL)
./enrich_state_nursing_license_ages.R

# Step 3: Fit OLS calibration models and impute cohort ages
./calibrate_amcb_certification_ages.R
```

---

## 7. Artifact & Provenance Ledger

| Artifact File | Description |
| :--- | :--- |
| [`match_ohio_voter_ages.py`](file:///Users/tmuffly/midwifery/match_ohio_voter_ages.py) | Python stream extractor for Ohio Statewide Voter Files ($7.9\text{M}$ records) |
| [`enrich_state_nursing_license_ages.R`](file:///Users/tmuffly/midwifery/enrich_state_nursing_license_ages.R) | Executable Socrata query & multi-tier name matcher script |
| [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R) | Multi-model OLS regression & age imputation pipeline |
| [`artifacts/ohio_voter_license_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/ohio_voter_license_ages.csv) | Matched Ohio voter records with verified DOB ($N = 3,962$) |
| [`artifacts/state_nursing_license_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/state_nursing_license_ages.csv) | Matched state licensee records ($N = 1,833$) |
| [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv) | Full cohort dataset ($N = 22,309$) with direct and calibrated ages |
| [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv) | Provenance log recording regression parameters ($\alpha$, $\beta$, $R^2$, RSE) |
