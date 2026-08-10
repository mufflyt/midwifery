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
2. **Gold-Standard Empirical Calibration**: Fitting ordinary least squares (OLS) regression models over ground-truth provider birth dates—specifically **Washington State DOH direct 4-digit birth years** ($N = 1,025$) and **Healthgrades provider ages**—and comparing against derived state issue dates ($N = 1,829$ combined).

---

## 2. Theoretical Framework & Prior Specification

### 2.1 Primary Temporal Anchor
For every certificant $i$ on the AMCB active roster ($N = 22,309$), the initial certification year $Y_{\text{cert}, i}$ is parsed from `certification_date` in [`midwives.csv`](file:///Users/tmuffly/midwifery/midwives.csv).

Years elapsed since certification relative to reference year $Y_{\text{ref}} = 2026$ is defined as:
$$T_i = Y_{\text{ref}} - Y_{\text{cert}, i}$$

---

## 3. Empirical Calibration Models & Statistical Evaluation

### 3.1 Model 1: Gold-Standard Direct Ground-Truth Model (Washington DOH + Healthgrades)
* **Sample**: $N = 1,025$ certificants with direct 4-digit birth years from Washington State DOH (`birth_year_source == "direct"`) and verified Healthgrades ages.
* **Regression Formula**:
  $$\text{Age}_{\text{Direct}} = 36.18 + 0.847 \cdot T_i$$
* **Statistical Performance**:
  * **Coefficient of Determination ($R^2$)**: $\mathbf{0.5411}$ (**54.1% of continuous age variance explained**)
  * **Residual Standard Error (RSE)**: $\mathbf{7.87\text{ years}}$ ($DF = 1,023$)
  * **Implied Mean Entry Age ($\hat{\alpha}$)**: $36.18\text{ years}$ ($p < 0.0001$)
  * **Tenure Progression Slope ($\hat{\beta}$)**: $0.8471\text{ years per certified year}$ ($p < 0.0001$)

### 3.2 Model 2: Combined State Sample Model (Direct WA + Derived IL Issue Dates)
* **Sample**: $N = 1,829$ certificants combining Washington DOH direct birth years ($1,025$) and Illinois IDFPR initial APRN license issue date back-calculations ($804$).
* **Regression Formula**:
  $$\text{Age}_{\text{Combined}} = 33.12 + 0.699 \cdot T_i$$
* **Statistical Performance**:
  * **Coefficient of Determination ($R^2$)**: $0.3550$ ($35.5\%$ of variance explained)
  * **Residual Standard Error (RSE)**: $9.46\text{ years}$ ($DF = 1,827$)
  * **Implied Mean Entry Age ($\hat{\alpha}$)**: $33.12\text{ years}$ ($p < 0.0001$)
  * **Tenure Progression Slope ($\hat{\beta}$)**: $0.699\text{ years per certified year}$ ($p < 0.0001$)

---

## 4. Empirical Model Comparison Summary

| Model Metric | Model 1: Gold-Standard Direct (WA) | Model 2: Combined State Sample | Prior Literature Baseline |
| :--- | :---: | :---: | :---: |
| **Ground-Truth Calibration Size ($N$)** | **$1,025$** | $1,829$ | Baseline Prior |
| **Primary Age Source** | **WA Direct Birth Year / HG** | WA Direct + IL Derived Issue Year | Theoretical Literature |
| **Implied Entry Age ($\hat{\alpha}$)** | **$36.18\text{ years}$** | $33.12\text{ years}$ | $29.50\text{ years}$ |
| **Tenure Slope ($\hat{\beta}$)** | **$0.847$** | $0.699$ | $1.000$ |
| **Variance Explained ($R^2$)** | **$54.1\%$** | $35.5\%$ | N/A |
| **Residual Standard Error (RSE)** | **$7.87\text{ years}$** | $9.46\text{ years}$ | N/A |

> **Methodological Selection**: The pipeline selects **Model 1 (Gold-Standard Direct)** as the primary imputation engine because direct 4-digit birth years eliminate error introduced by initial state APRN license timing variability.

---

## 5. Cohort Imputation & Demographic Age Bands

Applying the gold-standard direct calibration model ($\text{Age} = 36.18 + 0.847 \cdot T_i$) across the $N = 22,309$ AMCB cohort yields the following national demographic distribution:

### Continuous Age Summary Statistics ($N = 22,309$)
* **Minimum**: $27.0\text{ years}$
* **1st Quartile**: $42.1\text{ years}$
* **Median**: $51.4\text{ years}$
* **Mean**: $53.9\text{ years}$
* **3rd Quartile**: $63.3\text{ years}$
* **Maximum**: $82.8\text{ years}$

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
| **$<35$ years** | $514$ | $2.3\%$ |
| **$35$–$44$ years** | $7,311$ | $32.8\%$ |
| **$45$–$54$ years** | $4,576$ | $20.5\%$ |
| **$55$–$64$ years** | $5,102$ | $22.9\%$ |
| **$\ge 65$ years** | $4,806$ | $21.5\%$ |

---

## 6. Execution & Reproducibility Guide

To execute the state age enrichment and fit the calibration model:

```bash
cd /Users/tmuffly/midwifery

# Step 1: Query state Socrata APIs and build state_nursing_license_ages.csv
./enrich_state_nursing_license_ages.R

# Step 2: Fit OLS calibration models and impute cohort ages
./calibrate_amcb_certification_ages.R
```

---

## 7. Artifact & Provenance Ledger

| Artifact File | Description |
| :--- | :--- |
| [`enrich_state_nursing_license_ages.R`](file:///Users/tmuffly/midwifery/enrich_state_nursing_license_ages.R) | Executable Socrata query & multi-tier name matcher script |
| [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R) | Multi-model OLS regression & age imputation pipeline |
| [`artifacts/state_nursing_license_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/state_nursing_license_ages.csv) | Matched state licensee records ($N = 1,833$) |
| [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv) | Full cohort dataset ($N = 22,309$) with direct and calibrated ages |
| [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv) | Provenance log recording regression parameters ($\alpha$, $\beta$, $R^2$, RSE) |
