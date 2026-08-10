# Technical Appendix: Estimation, Imputation, and Empirical Calibration of Certified Nurse-Midwife (CNM) Provider Age

**Repository**: `midwifery`  
**Target Reference Year**: 2026  
**Primary Script**: [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R)  
**Primary Output**: [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv)  

---

## 1. Executive Summary & Problem Statement

National health workforce registries—including the National Plan and Provider Enumeration System (NPPES), the American Midwifery Certification Board (AMCB) public roster, and the CMS Doctors and Clinicians (DAC) file—do not directly record provider dates of birth or exact chronological ages.

While commercial directories (such as Healthgrades) expose exact age for a subset of providers, public attribute coverage is partial (~13.4% fill rate across active CNMs). Furthermore, scraping authenticated platforms such as Doximity presents access barriers, authentication requirements, and rate-limiting/ban risks.

To achieve **100% cohort age coverage** without credentialed web scraping, this project implements a two-stage methodology:
1. **Roster-Wide Age Derivation**: An analytical baseline model anchored on exact AMCB initial certification dates ($Y_{\text{cert}}$).
2. **Empirical OLS Calibration**: An automated calibration protocol that fits an empirical linear regression model against the ~10–13% Healthgrades ground-truth sample once local profile attributes are loaded.

---

## 2. Mathematical Framework & Prior Specification

### 2.1 Primary Temporal Anchor
For every certificant $i$ on the AMCB active roster ($N = 22,309$), the initial certification year $Y_{\text{cert}, i}$ is parsed from `certification_date` in [`midwives.csv`](file:///Users/tmuffly/midwifery/midwives.csv).

Years elapsed since certification relative to reference year $Y_{\text{ref}} = 2026$ is defined as:
$$T_i = Y_{\text{ref}} - Y_{\text{cert}, i}$$

### 2.2 Literature-Informed Baseline Prior
Nurse-midwifery education in the United States requires completion of a Bachelor of Science in Nursing (BSN) followed by an accredited graduate degree (MSN or DNP). In workforce literature, entry into certified practice occurs at a median age of $\alpha_0 = 29.5 \text{ years}$.

In the absence of direct empirical calibration data, baseline provider age $\hat{A}_{i, \text{prior}}$ is calculated as:
$$\hat{A}_{i, \text{prior}} = 29.5 + T_i$$

---

## 3. Empirical Calibration Protocol (Healthgrades Integration Plan)

### 3.1 Data Preparation & Matching
When the local Healthgrades profile attribute file (`healthgrades_profile_attrs.csv`) is made available:
1. **Unambiguous Attribute Linkage**: Healthgrades profile URLs (`hg_url`) are linked to AMCB certificant numbers using [`healthgrades_midwives.csv`](file:///Users/tmuffly/midwifery/healthgrades_midwives.csv). Shared or ambiguous URLs are excluded to prevent cross-provider demographic contamination.
2. **Calibration Subset Identification**: Extract all matched providers $i \in S_{\text{calib}}$ where verified Healthgrades age $A_i^{\text{obs}}$ is present and satisfies plausibility bounds ($21 \le A_i^{\text{obs}} \le 85$).

### 3.2 Ordinary Least Squares (OLS) Model Specification
Fit an empirical linear regression model over the calibration subset $S_{\text{calib}}$ ($N \approx 1,595$):
$$A_i^{\text{obs}} = \alpha + \beta \cdot T_i + \varepsilon_i, \quad \varepsilon_i \sim \mathcal{N}(0, \sigma^2)$$

Where:
* $\alpha$ represents the empirical **mean entry age at initial AMCB certification**.
* $\beta$ represents the **rate of age progression per elapsed year** (expected $\beta \approx 1.0$).
* $\varepsilon_i$ is the residual error term.

### 3.3 Out-of-Sample Imputation Rule
For the complete cohort $i = 1, \dots, N$:

$$\hat{A}_i = \begin{cases} A_i^{\text{obs}} & \text{if } i \in S_{\text{calib}} \text{ (Direct Observed Age)} \\ \hat{\alpha} + \hat{\beta} \cdot T_i & \text{if } i \notin S_{\text{calib}} \text{ (Empirically Calibrated Imputation)} \end{cases}$$

### 3.4 Model Evaluation & Validation Metrics
Upon running the calibration, the script evaluates:
1. **Goodness of Fit ($R^2$)**: Coefficient of determination measuring variance in provider age explained by certification tenure.
2. **Residual Standard Error ($\sigma$)**: Standard error of the regression in years.
3. **Implied Entry Age ($\hat{\alpha}$)**: Comparison of empirical $\hat{\alpha}$ against the literature prior ($29.5\text{ years}$).
4. **Age Band Concordance**: Sensitivity and specificity of predicted vs. observed age bands within $S_{\text{calib}}$.

---

## 4. Execution Guide & Workflow Plan

When returning home and accessing the local Healthgrades dataset:

### Step 1: Place Healthgrades Attribute File
Place `healthgrades_profile_attrs.csv` (and `healthgrades_midwives.csv`) in either the project root or the `artifacts/` directory:
```bash
cp /path/to/your/healthgrades_profile_attrs.csv /Users/tmuffly/midwifery/artifacts/
cp /path/to/your/healthgrades_midwives.csv /Users/tmuffly/midwifery/
```

### Step 2: Re-Run the Calibration Script
Execute the standalone calibration pipeline:
```bash
cd /Users/tmuffly/midwifery
./calibrate_amcb_certification_ages.R
```

The script will automatically detect the ground-truth sample, transition from the literature prior to the **Empirical OLS Model**, fit $\hat{\alpha}$ and $\hat{\beta}$, and write updated outputs.

### Step 3: Verify Output Provenance
Inspect the generated provenance log at [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv) to confirm:
* `calibration_type`: `Empirical OLS Model`
* `calib_sample_n`: Number of matched calibration records used ($N \approx 1,595$)
* `alpha_intercept`: Empirical entry age
* `r_squared`: Fit accuracy

---

## 5. Demographic Banding & Table 1 Categorization

To maintain consistency with ACOG and AMCB demographic workforce statistics, continuous age $\hat{A}_i$ is categorized into five standardized age bands:

$$\text{Age Band}_i = \begin{cases} 
\text{"<35 years"} & \hat{A}_i < 35 \\
\text{"35-44 years"} & 35 \le \hat{A}_i < 45 \\
\text{"45-54 years"} & 45 \le \hat{A}_i < 55 \\
\text{"55-64 years"} & 55 \le \hat{A}_i < 65 \\
\text{">=65 years"} & \hat{A}_i \ge 65 
\end{cases}$$

---

## 6. Provenance & Reproducibility Audit

| Artifact File | Description |
| :--- | :--- |
| [`calibrate_amcb_certification_ages.R`](file:///Users/tmuffly/midwifery/calibrate_amcb_certification_ages.R) | Executable R calibration & imputation script |
| [`artifacts/amcb_calibrated_ages.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_calibrated_ages.csv) | Full cohort dataset ($N = 22,309$) with continuous and banded ages |
| [`artifacts/amcb_age_calibration_provenance.csv`](file:///Users/tmuffly/midwifery/artifacts/amcb_age_calibration_provenance.csv) | Audit log containing model fit metrics, regression parameters, and execution timestamps |
