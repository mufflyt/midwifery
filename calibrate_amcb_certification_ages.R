#!/usr/bin/env Rscript
# =============================================================================
# Calibrate & Impute Midwife Age from AMCB Certification Date
# =============================================================================
#
# Method:
#   1. Parse `certification_date` from AMCB roster (`midwives.csv` or cohort roster)
#      to derive `certification_year` and `years_certified = 2026 - certification_year`.
#   2. Merge available ground-truth provider ages from Healthgrades (hg_age),
#      State Nursing License files, or Doximity extracts if present on disk.
#   3. If ground-truth ages are present (e.g., 10-13% Healthgrades sample), fit an
#      empirical linear model:
#        age ~ years_certified
#      to estimate exact baseline entry age (alpha) and slope (beta).
#   4. If no ground-truth sample is present, fall back to literature prior:
#        alpha = 29.5, beta = 1.0  =>  imputed_age = years_certified + 29.5
#   5. Assign standard Table 1 age bands:
#        <35 years, 35-44 years, 45-54 years, 55-64 years, >=65 years.
#
# Inputs:
#   midwives.csv (or artifacts/amcb_npi_linkage_FROZEN.csv)
#   healthgrades_profile_attrs.csv (optional 10% calibration sample)
#   artifacts/state_nursing_license_ages.csv (optional state sample)
#
# Outputs:
#   artifacts/amcb_calibrated_ages.csv
#   artifacts/amcb_age_calibration_provenance.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
})

REF_YEAR <- 2026L
DEFAULT_ENTRY_AGE <- 29.5

cat(sprintf("=== AMCB Midwife Age Calibration & Imputation (Ref Year: %d) ===\n", REF_YEAR))

# --- 1. Load AMCB Roster -----------------------------------------------------
roster_path <- if (file.exists("artifacts/amcb_npi_linkage_FROZEN.csv")) {
  "artifacts/amcb_npi_linkage_FROZEN.csv"
} else if (file.exists("midwives.csv")) {
  "midwives.csv"
} else {
  stop("Cannot find midwives.csv or cohort roster in artifacts/", call. = FALSE)
}

cat(sprintf("Loading roster: %s\n", roster_path))
df_raw <- read_csv(roster_path, show_col_types = FALSE, progress = FALSE)

# Standardize certification date and years certified
df <- df_raw %>%
  mutate(
    certification_number = as.character(certification_number),
    # Handle MM/YYYY or YYYY-MM-DD formats
    cert_year = suppressWarnings(as.integer(str_extract(certification_date, "\\d{4}"))),
    years_certified = REF_YEAR - cert_year
  ) %>%
  filter(!is.na(cert_year), cert_year <= REF_YEAR, cert_year >= 1950)

cat(sprintf("  Valid certificants with cert_year: %s / %s\n",
            format(nrow(df), big.mark = ","),
            format(nrow(df_raw), big.mark = ",")))

# --- 2. Gather Ground-Truth Age Samples for Calibration ----------------------
df$known_age <- NA_real_
df$age_source <- NA_character_

# A. Healthgrades profile attributes
hg_paths <- c("healthgrades_profile_attrs.csv", "artifacts/healthgrades_profile_attrs.csv")
hg_path <- hg_paths[file.exists(hg_paths)][1]

if (!is.na(hg_path)) {
  cat(sprintf("Merging calibration sample from Healthgrades: %s\n", hg_path))
  hg_link <- if (file.exists("healthgrades_midwives.csv")) {
    read_csv("healthgrades_midwives.csv", show_col_types = FALSE, progress = FALSE)
  } else NULL
  
  hg_attrs <- read_csv(hg_path, show_col_types = FALSE, progress = FALSE)
  
  if (!is.null(hg_link) && "hg_url" %in% names(hg_attrs) && "hg_age" %in% names(hg_attrs)) {
    hg_merged <- hg_link %>%
      filter(hg_status == "ok", !is.na(hg_url)) %>%
      left_join(hg_attrs %>% select(hg_url, hg_age), by = "hg_url") %>%
      filter(!is.na(hg_age)) %>%
      distinct(certification_number, .keep_all = TRUE)
    
    df <- df %>%
      left_join(hg_merged %>% select(certification_number, hg_age), by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(hg_age)),
        age_source = if_else(!is.na(hg_age) & is.na(age_source), "Healthgrades", age_source)
      ) %>%
      select(-any_of("hg_age"))
  }
}

# B. State Nursing License ages
state_path <- "artifacts/state_nursing_license_ages.csv"
if (file.exists(state_path)) {
  cat(sprintf("Merging calibration sample from State Nursing Licenses: %s\n", state_path))
  st_ages <- read_csv(state_path, show_col_types = FALSE, progress = FALSE)
  
  if ("snl_age_plausible" %in% names(st_ages)) {
    st_ages <- st_ages %>% filter(snl_age_plausible)
  }
  
  col_age <- if ("snl_age_at_ref" %in% names(st_ages)) "snl_age_at_ref" else
             if ("license_age_at_ref" %in% names(st_ages)) "license_age_at_ref" else NA_character_
             
  if (!is.na(col_age)) {
    st_ages <- st_ages %>%
      select(certification_number, st_age = all_of(col_age)) %>%
      filter(!is.na(st_age)) %>%
      distinct(certification_number, .keep_all = TRUE)
      
    df <- df %>%
      left_join(st_ages, by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(st_age)),
        age_source = if_else(!is.na(st_age) & is.na(age_source), "State_License", age_source)
      ) %>%
      select(-any_of("st_age"))
  }
}

# C. Doximity frozen ages (if available locally)
dox_path <- "artifacts/doximity_cnm_ages.csv"
if (file.exists(dox_path)) {
  cat(sprintf("Merging calibration sample from Doximity: %s\n", dox_path))
  dox_ages <- read_csv(dox_path, show_col_types = FALSE, progress = FALSE)
  if ("dox_age_at_ref" %in% names(dox_ages)) {
    df <- df %>%
      left_join(dox_ages %>% select(certification_number, dox_age_at_ref), by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(dox_age_at_ref)),
        age_source = if_else(!is.na(dox_age_at_ref) & is.na(age_source), "Doximity", age_source)
      ) %>%
      select(-any_of("dox_age_at_ref"))
  }
}

calibration_subset <- df %>% filter(!is.na(known_age), known_age >= 21, known_age <= 85)
n_calib <- nrow(calibration_subset)

# --- 3. Calibration Model Fit ------------------------------------------------
cat("\n--- Model Calibration Status ---\n")
if (n_calib >= 30) {
  cat(sprintf("Fitting linear calibration model on N = %s known provider ages...\n",
              format(n_calib, big.mark = ",")))
  
  fit <- lm(known_age ~ years_certified, data = calibration_subset)
  fit_sum <- summary(fit)
  
  alpha <- fit$coefficients[1]
  beta  <- fit$coefficients[2]
  r2    <- fit_sum$r.squared
  rse   <- fit_sum$sigma
  
  cat(sprintf("  Calibrated Model: Age = %.2f + %.2f * years_certified\n", alpha, beta))
  cat(sprintf("  Implied entry age at certification: %.2f years\n", alpha))
  cat(sprintf("  R-squared: %.4f | Residual Std Error: %.2f years\n", r2, rse))
  
  calibration_type <- "Empirical OLS Model"
} else {
  cat(sprintf("Insufficient ground-truth sample (N = %d < 30). Using literature prior.\n", n_calib))
  alpha <- DEFAULT_ENTRY_AGE
  beta  <- 1.0
  r2    <- NA_real_
  rse   <- NA_real_
  cat(sprintf("  Literature Prior: Age = %.1f + 1.0 * years_certified\n", alpha))
  calibration_type <- "Literature Prior (29.5y entry age)"
}

# --- 4. Age Imputation and Banding -------------------------------------------
df <- df %>%
  mutate(
    fitted_age  = alpha + beta * years_certified,
    final_age   = if_else(!is.na(known_age), known_age, fitted_age),
    is_imputed  = is.na(known_age),
    age_band    = case_when(
      final_age < 35 ~ "<35 years",
      final_age < 45 ~ "35-44 years",
      final_age < 55 ~ "45-54 years",
      final_age < 65 ~ "55-64 years",
      final_age >= 65 ~ ">=65 years",
      TRUE ~ NA_character_
    )
  )

# --- 5. Summary Results & Reporting ------------------------------------------
cat("\n--- Cohort Imputed Age Summary ---\n")
cat(sprintf("Total Certificants Processed: %s\n", format(nrow(df), big.mark = ",")))
cat(sprintf("Direct Ground-Truth Ages   : %s (%.1f%%)\n",
            format(sum(!df$is_imputed), big.mark = ","),
            100 * mean(!df$is_imputed)))
cat(sprintf("Imputed Ages               : %s (%.1f%%)\n",
            format(sum(df$is_imputed), big.mark = ","),
            100 * mean(df$is_imputed)))

cat("\nAge Distribution (Summary Statistics):\n")
print(summary(df$final_age))

cat("\nAge Band Breakdown:\n")
band_tbl <- df %>%
  count(age_band, name = "n") %>%
  mutate(pct = round(100 * n / sum(n), 1)) %>%
  arrange(match(age_band, c("<35 years", "35-44 years", "45-54 years", "55-64 years", ">=65 years")))
print(as.data.frame(band_tbl))

# --- 6. Save Outputs ---------------------------------------------------------
dir.create("artifacts", showWarnings = FALSE)

out_file <- "artifacts/amcb_calibrated_ages.csv"
write_csv(df %>% select(certification_number, cert_year, years_certified,
                        known_age, age_source, fitted_age, final_age,
                        is_imputed, age_band),
          out_file, na = "")
cat(sprintf("\nWritten: %s\n", out_file))

prov_file <- "artifacts/amcb_age_calibration_provenance.csv"
prov <- tibble(
  calibrated_at    = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  roster_source    = roster_path,
  total_roster_n   = nrow(df),
  calib_sample_n   = n_calib,
  calibration_type = calibration_type,
  alpha_intercept  = alpha,
  beta_slope       = beta,
  r_squared        = r2,
  residual_std_err = rse
)
write_csv(prov, prov_file, na = "")
cat(sprintf("Written: %s\n", prov_file))

cat("\n=== Done. ===\n")
