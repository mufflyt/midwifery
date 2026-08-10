#!/usr/bin/env Rscript
# =============================================================================
# Calibrate & Impute Midwife Age from AMCB Certification Date
# =============================================================================
#
# Method:
#   1. Parse `certification_date` from AMCB roster (`midwives.csv` or cohort roster)
#      to derive `certification_year` and `years_certified = 2026 - certification_year`.
#   2. Merge available ground-truth provider ages from:
#      - Washington State DOH direct birth years (WA direct: gold standard)
#      - Healthgrades direct provider ages (hg_age)
#      - Illinois state license derived ages (IL derived)
#      - Doximity extracts (if present)
#   3. Prioritize Direct Ground-Truth Ages (WA direct + Healthgrades) to fit the
#      primary empirical OLS regression:
#        Age = alpha + beta * years_certified
#   4. Compare against the Combined Sample model (N = 1,829, Age = 33.12 + 0.70 * years_certified).
#   5. Assign standard Table 1 age bands:
#        <35 years, 35-44 years, 45-54 years, 55-64 years, >=65 years.
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
    cert_year = suppressWarnings(as.integer(str_extract(certification_date, "[0-9]{4}"))),
    years_certified = REF_YEAR - cert_year
  ) %>%
  filter(!is.na(cert_year), cert_year <= REF_YEAR, cert_year >= 1950)

cat(sprintf("  Valid certificants with cert_year: %s / %s\n",
            format(nrow(df), big.mark = ","),
            format(nrow(df_raw), big.mark = ",")))

# --- 2. Gather Ground-Truth Age Samples --------------------------------------
df$known_age <- NA_real_
df$age_source <- NA_character_
df$is_direct_ground_truth <- FALSE

# A. Healthgrades profile attributes (Direct Age)
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
        age_source = if_else(!is.na(hg_age) & is.na(age_source), "Healthgrades_Direct", age_source),
        is_direct_ground_truth = if_else(!is.na(hg_age), TRUE, is_direct_ground_truth)
      ) %>%
      select(-any_of("hg_age"))
  }
}

# B. State Nursing License ages (WA Direct Birth Year + IL Derived)
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
      select(certification_number, state_source, birth_year_source, st_age = all_of(col_age)) %>%
      filter(!is.na(st_age)) %>%
      distinct(certification_number, .keep_all = TRUE)
      
    df <- df %>%
      left_join(st_ages, by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(st_age)),
        is_wa_direct = !is.na(st_age) & state_source == "WA" & birth_year_source == "direct",
        age_source = if_else(!is.na(st_age) & is.na(age_source),
                             if_else(is_wa_direct, "WA_Direct_BirthYear", "IL_Derived_IssueYear"),
                             age_source),
        is_direct_ground_truth = if_else(is_wa_direct, TRUE, is_direct_ground_truth)
      ) %>%
      select(-any_of(c("st_age", "state_source", "birth_year_source", "is_wa_direct")))
  }
}

# C2. Florida Statewide Voter Database direct DOBs (22 <= Age <= 80)
fl_voter_path <- "artifacts/florida_voter_license_ages.csv"
if (file.exists(fl_voter_path)) {
  fl_voter <- read_csv(fl_voter_path, show_col_types = FALSE, progress = FALSE)
  if ("fl_age_at_ref" %in% names(fl_voter) && nrow(fl_voter) > 0) {
    cat(sprintf("Merging calibration sample from Florida Voter File: %s (N = %d)\n", fl_voter_path, nrow(fl_voter)))
    fl_voter <- fl_voter %>%
      filter(fl_age_plausible) %>%
      select(certification_number, fl_age = fl_age_at_ref) %>%
      distinct(certification_number, .keep_all = TRUE)
      
    df <- df %>%
      left_join(fl_voter, by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(fl_age)),
        age_source = if_else(!is.na(fl_age) & is.na(age_source), "FL_Voter_Direct_DOB", age_source),
        is_direct_ground_truth = if_else(!is.na(fl_age), TRUE, is_direct_ground_truth)
      ) %>%
      select(-any_of("fl_age"))
  }
}
oh_path <- "artifacts/ohio_voter_license_ages.csv"
if (file.exists(oh_path)) {
  cat(sprintf("Merging calibration sample from Ohio Voter File: %s\n", oh_path))
  oh_voter <- read_csv(oh_path, show_col_types = FALSE, progress = FALSE)
  if ("oh_age_at_ref" %in% names(oh_voter)) {
    oh_voter <- oh_voter %>%
      filter(oh_age_plausible) %>%
      select(certification_number, oh_age = oh_age_at_ref) %>%
      distinct(certification_number, .keep_all = TRUE)
      
    df <- df %>%
      left_join(oh_voter, by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(oh_age)),
        age_source = if_else(!is.na(oh_age) & is.na(age_source), "OH_Voter_Direct_DOB", age_source),
        is_direct_ground_truth = if_else(!is.na(oh_age), TRUE, is_direct_ground_truth)
      ) %>%
      select(-any_of("oh_age"))
  }
}

# D. Doximity frozen ages (if available locally)
dox_path <- "artifacts/doximity_cnm_ages.csv"
if (file.exists(dox_path)) {
  cat(sprintf("Merging calibration sample from Doximity: %s\n", dox_path))
  dox_ages <- read_csv(dox_path, show_col_types = FALSE, progress = FALSE)
  if ("dox_age_at_ref" %in% names(dox_ages)) {
    df <- df %>%
      left_join(dox_ages %>% select(certification_number, dox_age_at_ref), by = "certification_number") %>%
      mutate(
        known_age = coalesce(known_age, as.numeric(dox_age_at_ref)),
        age_source = if_else(!is.na(dox_age_at_ref) & is.na(age_source), "Doximity_Direct", age_source),
        is_direct_ground_truth = if_else(!is.na(dox_age_at_ref), TRUE, is_direct_ground_truth)
      ) %>%
      select(-any_of("dox_age_at_ref"))
  }
}

# Subsets for calibration evaluation
direct_subset <- df %>% filter(is_direct_ground_truth, !is.na(known_age), known_age >= 21, known_age <= 85)
combined_subset <- df %>% filter(!is.na(known_age), known_age >= 21, known_age <= 85)

n_direct   <- nrow(direct_subset)
n_combined <- nrow(combined_subset)

cat("\n--- Ground-Truth Calibration Subsets Available ---\n")
cat(sprintf("  Direct Ground-Truth Ages (WA Direct + Healthgrades) : N = %s\n", format(n_direct, big.mark = ",")))
cat(sprintf("  Combined Sample (Direct WA + Derived IL + Others)    : N = %s\n", format(n_combined, big.mark = ",")))

# --- 3. Calibration Model Fit & Comparison -----------------------------------
cat("\n--- Model Calibration & Fitting ---\n")

if (n_direct >= 30) {
  cat(sprintf("Fitting Primary Gold-Standard Model on Direct Ground-Truth (N = %s)...\n", format(n_direct, big.mark = ",")))
  fit_direct <- lm(known_age ~ years_certified, data = direct_subset)
  sum_direct <- summary(fit_direct)
  
  alpha_direct <- fit_direct$coefficients[1]
  beta_direct  <- fit_direct$coefficients[2]
  r2_direct    <- sum_direct$r.squared
  rse_direct   <- sum_direct$sigma
  
  cat(sprintf("  [Gold-Standard Direct Model]: Age = %.2f + %.3f * years_certified\n", alpha_direct, beta_direct))
  cat(sprintf("  Implied entry age at certification: %.2f years\n", alpha_direct))
  cat(sprintf("  R-squared: %.4f (%.1f%% variance explained) | RSE: %.2f years\n",
              r2_direct, 100 * r2_direct, rse_direct))
} else {
  alpha_direct <- DEFAULT_ENTRY_AGE
  beta_direct  <- 1.0
  r2_direct    <- NA_real_
  rse_direct   <- NA_real_
}

if (n_combined >= 30) {
  cat(sprintf("\nFitting Secondary Model on Combined Sample (N = %s)...\n", format(n_combined, big.mark = ",")))
  fit_comb <- lm(known_age ~ years_certified, data = combined_subset)
  sum_comb <- summary(fit_comb)
  
  alpha_comb <- fit_comb$coefficients[1]
  beta_comb  <- fit_comb$coefficients[2]
  r2_comb    <- sum_comb$r.squared
  rse_comb   <- sum_comb$sigma
  
  cat(sprintf("  [Combined Sample Model]     : Age = %.2f + %.3f * years_certified\n", alpha_comb, beta_comb))
  cat(sprintf("  Implied entry age at certification: %.2f years\n", alpha_comb))
  cat(sprintf("  R-squared: %.4f (%.1f%% variance explained) | RSE: %.2f years\n",
              r2_comb, 100 * r2_comb, rse_comb))
} else {
  alpha_comb <- DEFAULT_ENTRY_AGE
  beta_comb  <- 1.0
  r2_comb    <- NA_real_
  rse_comb   <- NA_real_
}

# Select primary model for cohort imputation (prefer direct gold-standard if N >= 30)
if (n_direct >= 30) {
  alpha <- alpha_direct
  beta  <- beta_direct
  r2    <- r2_direct
  rse   <- rse_direct
  calibration_type <- sprintf("Primary Gold-Standard Direct OLS (N = %d, R2 = %.3f)", n_direct, r2_direct)
} else if (n_combined >= 30) {
  alpha <- alpha_comb
  beta  <- beta_comb
  r2    <- r2_comb
  rse   <- rse_comb
  calibration_type <- sprintf("Combined Sample OLS (N = %d, R2 = %.3f)", n_combined, r2_comb)
} else {
  alpha <- DEFAULT_ENTRY_AGE
  beta  <- 1.0
  r2    <- NA_real_
  rse   <- NA_real_
  calibration_type <- "Literature Prior (29.5y entry age)"
}

cat(sprintf("\n--> Selected Imputation Model: Age = %.2f + %.3f * years_certified\n", alpha, beta))

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
            format(sum(!df$is_imputed & df$is_direct_ground_truth), big.mark = ","),
            100 * mean(!df$is_imputed & df$is_direct_ground_truth)))
cat(sprintf("State Derived Ages         : %s (%.1f%%)\n",
            format(sum(!df$is_imputed & !df$is_direct_ground_truth), big.mark = ","),
            100 * mean(!df$is_imputed & !df$is_direct_ground_truth)))
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
                        known_age, age_source, is_direct_ground_truth,
                        fitted_age, final_age, is_imputed, age_band),
          out_file, na = "")
cat(sprintf("\nWritten: %s\n", out_file))

prov_file <- "artifacts/amcb_age_calibration_provenance.csv"
prov <- tibble(
  calibrated_at       = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  roster_source       = roster_path,
  total_roster_n      = nrow(df),
  direct_ground_truth_n = n_direct,
  combined_sample_n   = n_combined,
  selected_model      = calibration_type,
  alpha_intercept     = alpha,
  beta_slope          = beta,
  r_squared           = r2,
  residual_std_err    = rse,
  direct_alpha        = alpha_direct,
  direct_beta         = beta_direct,
  direct_r2           = r2_direct,
  direct_rse          = rse_direct,
  comb_alpha          = alpha_comb,
  comb_beta           = beta_comb,
  comb_r2             = r2_comb,
  comb_rse            = rse_comb
)
write_csv(prov, prov_file, na = "")
cat(sprintf("Written: %s\n", prov_file))

cat("\n=== Done. ===\n")
