#!/usr/bin/env Rscript
# =============================================================================
# Trilliant's provider directory as a backup source for four demographics
# =============================================================================
# Sex, training school, age and patient-panel mix, for every primary-linked
# certificant of the frozen linkage, from Trilliant's directory_provider
# (snapshot 2026-06-25). Nothing here replaces a primary source. The consumers
# use a Trilliant value only where theirs are silent:
#
#   sex     build_table1_midwives.R, after NPPES
#   school  R/lib/training_institution.R and build_table1_midwives.R, after
#           CMS DAC and Healthgrades (and the university repository)
#   age     calibrate_amcb_certification_ages.R, after every direct source and
#           only if trl_age_admission() says it beats the calibration
#   panel   no primary source exists; carried for analysis and summarised
#
# Before any of that is trusted, this script measures each field against the
# source it would back up, on the canonical ACTIVE, primary-linked cohort, and
# writes the result as an aggregate. The checks are rerun on every build, so a
# later snapshot that behaves differently is caught rather than assumed.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv   (the manifest's freeze unless
#            ALLOW_FREEZE_SHA256 names another on purpose)
#          Trilliant lake directory_provider       (external volume)
#          for the checks, if present: nppes_sex_enumeration.csv,
#            dac_cnm_education.csv, amcb_calibrated_ages.csv
# Outputs: artifacts/trilliant_demographics.csv    (person-level; gitignored)
#          artifacts/trilliant_demographics_validation_<freeze sha8>.csv
#                                                  (aggregate; tracked)
#
# R and duckplyr; the lake is read as parquet, no SQL.
# =============================================================================
suppressPackageStartupMessages({
  library(duckplyr); library(dplyr); library(readr); library(stringr); library(tidyr)
})
source(file.path("R", "lib", "common_helpers.R"))         # chr()
source(file.path("R", "lib", "medicare_duckdb.R"))        # samsung_volume_path()
source(file.path("R", "lib", "artifact_provenance.R"))    # write_with_provenance()
source(file.path("R", "lib", "cohort_definitions.R"))     # verify_linkage_freeze(), canonical_active_primary()
source(file.path("R", "lib", "training_institution.R"))   # strip_med_suffix(), training_source_dac()
source(file.path("R", "lib", "trilliant_demographics.R"))

ART <- Sys.getenv("MIDWIFERY_ARTIFACTS", "artifacts")
FROZEN <- file.path(ART, "amcb_npi_linkage_FROZEN.csv")
FROZEN_SHA256 <- verify_linkage_freeze(FROZEN)
LAKE <- { v <- Sys.getenv("TRILLIANT_LAKE", ""); if (nzchar(v)) v else
          samsung_volume_path("hpt_prices/trilliant/20260721/lake/data/main") }
TRILLIANT_SNAPSHOT <- "2026-06-25"
OUT <- file.path("artifacts", "trilliant_demographics.csv")
OUT_VALIDATION <- file.path("artifacts", sprintf("trilliant_demographics_validation_%s.csv",
                                                 substr(FROZEN_SHA256, 1, 8)))

# ---- every primary-linked certificant, any status ----------------------------
# Any status, because the age calibration runs over the whole roster; the
# checks below use the canonical ACTIVE subset.
linkage <- chr(FROZEN)
linked <- linkage |> filter(linkage_tier == "primary_midwifery", !is.na(npi), npi != "")
conflict <- linked |> group_by(certification_number) |> filter(n_distinct(npi) > 1L) |> ungroup()
if (nrow(conflict)) stop(nrow(conflict), " rows give one certificant two NPIs; resolve before enriching.", call. = FALSE)
linked <- linked |>
  arrange(certification_number) |>
  filter(!duplicated(certification_number)) |>
  select(certification_number, npi, status)
active <- canonical_active_primary(linkage)$certification_number

# ---- the directory's fields ----------------------------------------------------
trl <- read_parquet_duckdb(file.path(LAKE, "directory_provider", "*.parquet")) |>
  select(provider_npi, active_provider, provider_gender, provider_medical_school_name,
         provider_medical_school_graduation_year, provider_estimated_age,
         panel_median_age, all_of(TRL_PANEL_AGE_BANDS), panel_percent_female, panel_percent_male) |>
  semi_join(as_duckdb_tibble(tibble(provider_npi = as.numeric(unique(linked$npi)))), by = "provider_npi") |>
  collect() |>
  mutate(npi = as.character(provider_npi), .keep = "unused")
if (anyDuplicated(trl$npi)) stop("directory_provider has more than one row for an NPI.", call. = FALSE)

trl <- trl |>
  mutate(panel_ok = trl_panel_ok(pick(panel_median_age, all_of(TRL_PANEL_AGE_BANDS))))
demo <- linked |>
  left_join(trl, by = "npi", relationship = "one-to-one") |>
  transmute(certification_number, npi,
            trl_in_directory     = !is.na(active_provider),
            trl_active_provider  = active_provider,
            trl_gender_raw       = provider_gender,
            trl_sex_code         = trl_sex_code(provider_gender),
            trl_school_raw       = provider_medical_school_name,
            trl_school_clean     = trl_school_clean(provider_medical_school_name),
            trl_grad_year        = as.integer(provider_medical_school_graduation_year),
            trl_estimated_age    = as.integer(provider_estimated_age),
            # The panel fields are kept only where the record is coherent.
            across(c(panel_median_age, all_of(TRL_PANEL_AGE_BANDS), panel_percent_female, panel_percent_male),
                   \(v) if_else(panel_ok %in% TRUE, v, NA), .names = "trl_{.col}"),
            trilliant_snapshot = TRILLIANT_SNAPSHOT, frozen_sha256 = FROZEN_SHA256)
write_with_provenance(demo, OUT, inputs = FROZEN, na = "")
cat("wrote", OUT, "(person-level, gitignored):", nrow(demo), "certificants\n")

# ---- checks, on the canonical ACTIVE cohort ------------------------------------
coh <- demo |> filter(certification_number %in% active)
row <- function(field, check, n, value, note = "") tibble(field, check, n = as.integer(n), value = as.numeric(value), note)
absent <- function(field, file) row(field, "not checked", NA, NA, paste(file, "not found"))
checks <- list(row("all", "cohort (ACTIVE, primary-linked)", nrow(coh), nrow(coh)),
               row("all", "in the Trilliant directory", nrow(coh), sum(coh$trl_in_directory)))

# Sex, against NPPES.
f <- file.path(ART, "nppes_sex_enumeration.csv")
checks <- c(checks, list(row("sex", "Trilliant gives F or M", nrow(coh), sum(!is.na(coh$trl_sex_code)))))
if (file.exists(f)) {
  nppes <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE) |>
    filter(npi %in% coh$npi) |>
    group_by(npi) |>
    # An NPI listed twice with two codes has no single recorded sex.
    summarise(sex_code = if (n_distinct(sex_code, na.rm = TRUE) == 1L) first(na.omit(sex_code)) else NA_character_,
              .groups = "drop")
  s <- coh |> left_join(nppes, by = "npi", relationship = "one-to-one")
  both <- s |> filter(!is.na(sex_code), sex_code %in% c("F", "M"), !is.na(trl_sex_code))
  checks <- c(checks, list(
    row("sex", "agrees with NPPES where both give F or M (%)", nrow(both), 100 * mean(both$sex_code == both$trl_sex_code)),
    row("sex", "NPPES blank, Trilliant fills", sum(is.na(s$sex_code)), sum(is.na(s$sex_code) & !is.na(s$trl_sex_code)))))
} else checks <- c(checks, list(absent("sex", "nppes_sex_enumeration.csv")))

# School and graduation year, against CMS DAC.
f <- file.path(ART, "dac_cnm_education.csv")
checks <- c(checks, list(row("school", "Trilliant names a school", nrow(coh), sum(!is.na(coh$trl_school_clean)))))
if (file.exists(f)) {
  dac <- training_source_dac(f)
  s <- coh |> left_join(dac, by = "npi", relationship = "one-to-one")
  both <- s |> filter(!is.na(dac_school), !is.na(trl_school_clean))
  dac_year <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE) |>
    transmute(npi = NPI, grad_year = suppressWarnings(as.integer(grad_year))) |>
    filter(npi %in% coh$npi, !is.na(grad_year)) |>
    group_by(npi) |> filter(n_distinct(grad_year) == 1L) |>
    summarise(dac_grad_year = first(grad_year), .groups = "drop")
  y <- coh |> inner_join(dac_year, by = "npi", relationship = "one-to-one") |> filter(!is.na(trl_grad_year))
  checks <- c(checks, list(
    row("school", "agrees with CMS DAC where both name one (%)", nrow(both), 100 * mean(both$dac_school == both$trl_school_clean)),
    row("school", "CMS DAC names none, Trilliant names one", sum(is.na(s$dac_school)), sum(is.na(s$dac_school) & !is.na(s$trl_school_clean)),
        "before Healthgrades and the repository, which the consumers try first"),
    row("grad_year", "same year as CMS DAC (%)", nrow(y), 100 * mean(y$dac_grad_year == y$trl_grad_year))))
} else checks <- c(checks, list(absent("school", "dac_cnm_education.csv")))

# Age: derived from graduation year? Better than the calibration?
der <- trl_age_derivation(coh$trl_estimated_age, coh$trl_grad_year)
checks <- c(checks, list(
  row("age", "Trilliant gives an age", nrow(coh), sum(!is.na(coh$trl_estimated_age))),
  row("age", "share with the modal age + graduation year", der$n_both, der$share_at_modal,
      sprintf("modal sum %s; derived from graduation year: %s", der$modal_sum, der$derived))))
f <- file.path(ART, "amcb_calibrated_ages.csv")
if (file.exists(f)) {
  cal <- read_csv(f, col_types = cols(certification_number = "c", known_age = "d", fitted_age = "d",
                                      is_direct_ground_truth = "l", is_imputed = "l", .default = "c"),
                  progress = FALSE) |>
    select(certification_number, known_age, fitted_age, is_direct_ground_truth, is_imputed)
  if (anyDuplicated(cal$certification_number)) stop("amcb_calibrated_ages.csv repeats a certification number.", call. = FALSE)
  a <- coh |> left_join(cal, by = "certification_number", relationship = "one-to-one")
  adm <- trl_age_admission(a$trl_estimated_age, a$trl_grad_year, a$known_age, a$fitted_age, a$is_direct_ground_truth)
  checks <- c(checks, list(
    row("age", "Trilliant minus measured age, mean (years)", adm$n_compared, adm$trl_bias),
    row("age", "Trilliant vs measured age, mean absolute error (years)", adm$n_compared, adm$trl_mae),
    row("age", "calibration vs measured age, mean absolute error (years)", adm$n_compared, adm$ols_mae,
        "same people; the calibration is what a Trilliant age would replace"),
    row("age", "imputed ages Trilliant could fill", sum(a$is_imputed %in% TRUE), sum(a$is_imputed %in% TRUE & !is.na(a$trl_estimated_age))),
    row("age", "admitted as a backup (1 = yes)", adm$n_compared, as.numeric(adm$admitted),
        "trl_age_admission(): not derived AND closer to measured age than the calibration")))
} else checks <- c(checks, list(absent("age", "amcb_calibrated_ages.csv")))

# Patient panel: no primary source, so describe it.
p <- coh |> filter(!is.na(trl_panel_median_age))
q <- function(v, pr) unname(quantile(v, pr, na.rm = TRUE))
checks <- c(checks, list(
  row("panel", "coherent patient panel", nrow(coh), nrow(p)),
  row("panel", "panel median patient age, median", nrow(p), q(p$trl_panel_median_age, 0.5)),
  row("panel", "panel median patient age, 25th percentile", nrow(p), q(p$trl_panel_median_age, 0.25)),
  row("panel", "panel median patient age, 75th percentile", nrow(p), q(p$trl_panel_median_age, 0.75)),
  row("panel", "share of patients female (%), median across midwives", nrow(p), 100 * q(p$trl_panel_percent_female, 0.5))),
  lapply(TRL_PANEL_AGE_BANDS, \(b) row("panel", sprintf("share of patients aged %s (%%), mean across midwives",
                                                      str_replace_all(str_remove(b, "panel_percent_age_"), "_", "-")),
                                      nrow(p), 100 * mean(p[[paste0("trl_", b)]]))))

val <- bind_rows(checks) |>
  mutate(frozen_sha256 = FROZEN_SHA256, trilliant_snapshot = TRILLIANT_SNAPSHOT)
# No `inputs =` here: the freeze's path is machine-specific, and its hash is
# already a column of the file.
write_with_provenance(val, OUT_VALIDATION, na = "")
cat("wrote", OUT_VALIDATION, "\n")
print(select(val, field, check, n, value, note), n = Inf, width = 200)
