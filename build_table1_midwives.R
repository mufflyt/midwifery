#!/usr/bin/env Rscript
# =============================================================================
# Table 1 — characteristics of the ACTIVE certified-midwife cohort
# =============================================================================
# Run as: Rscript build_table1_midwives.R
#
# Follows the long-format convention in the isochrones vignette
# `how-to-create-table-1.Rmd`: one row per level, columns
# characteristic / n / percent / category, bound together and grouped by
# category at render time. Percentages are within-category and computed on the
# NON-MISSING denominator, which is reported separately for every variable that
# has one -- a Table 1 that silently drops the unknowns overstates how much is
# known about the cohort.
#
# COHORT: ACTIVE status AND linkage_tier == "primary_midwifery". That is the
# population every downstream analysis uses. ACTIVE is an AMCB certification
# status, not a practice status; "Retired" is in good standing and "Deactivated"
# is an administrative CM<->CNM switch, so neither is an exit from the workforce.
#
# ONE REQUESTED VARIABLE IS NOT AVAILABLE. Language is not collected by any
# source this project holds: NPPES has no language field in either the 2022 or
# 2025 layout, the CMS Doctors & Clinicians file has none, and the Healthgrades
# scrape captured practice, address and credential but not languages spoken. It
# is reported as unavailable rather than approximated.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          artifacts/midwives_geography_FROZEN.csv
#          artifacts/nppes_sex_enumeration.csv   (built from the NPPES bulk file)
#          artifacts/midwife_panel_midwifeonly.csv
#          data/rucc_2023.xlsx
#          ~/isochrones/config/acog_districts.yml  (canonical ACOG mapping)
# Outputs: artifacts/table1_midwives.csv
#          docs/table1_midwives.md
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(readxl)
})

REF_YEAR <- 2026   # "years since" are measured to this study year, not Sys.Date()

# Banding and date parsing live in one tested place. Inline, each rule held
# only because the current artifacts satisfy an assumption it never enforced.
source("R/lib/table1_bands.R")

link_paths <- c(
  "artifacts/amcb_npi_linkage_FROZEN.csv",
  "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
)
link_path <- link_paths[file.exists(link_paths)][1]
if (is.na(link_path)) stop("Cohort linkage file not found.", call. = FALSE)

link <- read_csv(link_path, show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)
N <- nrow(coh)
cat(sprintf("cohort: %s ACTIVE primary-linked midwives\n", format(N, big.mark = ",")))

# --- Healthgrades attribution eligibility -------------------------------------
# Some Healthgrades profiles are claimed by more than one certificant -- either
# two genuinely different people with near-identical names (Sara vs Sarah
# Adkins; four separate Jennifer Allens), or one person holding two AMCB
# certifications (a CM and a CNM number). Either way the profile cannot be
# attributed to a specific midwife.
#
# SCOPE. This disqualifies them from HEALTHGRADES-DERIVED fields only. Their
# NPPES sex, certification type, ACOG district, rurality and enumeration dates
# are untouched by the collision, so removing them from the cohort would
# discard sound registry data, shift the denominator off N, and break
# comparability with every figure already published against it. The cohort
# stays whole; the exclusion is carried as a flag and applied per field.
#
# Selection is on hg_status == "ok": a rejected candidate keeps the URL it was
# rejected for, so !is.na(hg_url) would readmit refused matches.
coh$hg_eligible <- TRUE
hg_ambiguous <- character(0)
if (file.exists("healthgrades_midwives.csv")) {
  hg <- read_csv("healthgrades_midwives.csv", show_col_types = FALSE,
                 progress = FALSE)
  # Collisions are detected across the FULL roster, then intersected with the
  # cohort. Restricting to cohort members BEFORE the count hides the case where
  # a cohort member shares a profile with a non-cohort certificant: the URL
  # then looks unshared and the midwife is wrongly treated as attributable.
  # That mistake was live here and reported 2 affected members instead of 14.
  shared <- hg %>%
    filter(hg_status == "ok", !is.na(hg_url)) %>%
    distinct(certification_number, hg_url) %>%
    add_count(hg_url) %>%
    filter(n > 1)
  hg_ambiguous <- intersect(unique(shared$certification_number),
                            coh$certification_number)
  coh$hg_eligible <- !coh$certification_number %in% hg_ambiguous
  cat(sprintf(paste0("Healthgrades: %s cohort member(s) share %s profile URL(s); ",
                     "ineligible for Healthgrades-derived fields only\n"),
              format(length(hg_ambiguous), big.mark = ","),
              format(n_distinct(shared$hg_url), big.mark = ",")))
  cat(sprintf("  registry-derived rows keep the full cohort of %s\n",
              format(N, big.mark = ",")))
} else {
  cat("Healthgrades: scrape absent; no attribution exclusions applied\n")
}

# --- Healthgrades field usability --------------------------------------------
# Completeness is not usability. hg_years_experience is 100% non-missing and
# entirely 0, because Healthgrades does not populate roundedYearsOfExperience
# for midwives; published as a Table 1 row it would read as a finding. Every
# candidate field is classified EMPTY / CONSTANT / VARIES and scored against
# the COHORT, not against the profiles that happen to exist -- most of the loss
# is upstream in the search stage. Nothing is published from here yet; this
# writes the decision table and refuses constants at the point of use.
source("R/lib/field_quality.R")
HG_CANDIDATE_FIELDS <- c("hg_gender", "hg_age", "hg_years_experience",
                         "hg_languages", "hg_accepts_new_patients",
                         "hg_has_telehealth", "hg_medicaid_named")
hg_link <- NULL
if (file.exists("healthgrades_profile_attrs.csv") &&
    file.exists("healthgrades_midwives.csv")) {
  .attrs <- read_csv("healthgrades_profile_attrs.csv", show_col_types = FALSE,
                     progress = FALSE)
  # Attribute to certificants only through UNAMBIGUOUS profiles; a shared URL
  # would copy one person's demographics onto several midwives.
  .link <- read_csv("healthgrades_midwives.csv", show_col_types = FALSE,
                    progress = FALSE) %>%
    filter(hg_status == "ok", !is.na(hg_url),
           certification_number %in% coh$certification_number[coh$hg_eligible]) %>%
    distinct(certification_number, hg_url) %>%
    left_join(.attrs, by = "hg_url")
  hg_link <- .link
  # VERDICT is judged on ALL fetched profiles, not on the cohort-linked subset.
  # "Does the source populate this field with information?" is a property of
  # the source. Judged on the subset, hg_gender reads CONSTANT purely because
  # the single male midwife is not in it -- a genuine 99.4%-female distribution
  # would have been suppressed as if it were a scraping failure. Coverage is a
  # separate question and is still measured against the cohort.
  .rep <- lapply(intersect(HG_CANDIDATE_FIELDS, names(.link)), function(f) {
    v  <- field_variability(.attrs[[f]])
    cc <- cohort_coverage(.link[[f]], .link$certification_number,
                          coh$certification_number)
    tibble(field = f, verdict = v$verdict, distinct_values = v$n_distinct,
           cohort_n = cc$n_cohort, cohort_with_value = cc$n_with_value,
           cohort_pct = round(cc$pct, 2),
           publishable = v$verdict == "VARIES")
  })
  if (length(.rep)) {
    .rep <- bind_rows(.rep)
    write_csv(.rep, "artifacts/healthgrades_field_usability.csv")
    cat("Healthgrades field usability (cohort-based):\n")
    for (i in seq_len(nrow(.rep)))
      cat(sprintf("  %-26s %-8s %6.2f%% of cohort  %s\n", .rep$field[i],
                  .rep$verdict[i], .rep$cohort_pct[i],
                  if (.rep$publishable[i]) "" else "<- NOT PUBLISHABLE"))
    # Enforce it, do not merely report it.
    for (f in .rep$field[!.rep$publishable])
      try(assert_not_constant(.link[[f]], f), silent = TRUE)
  }
}

# --- ACOG district, from the canonical crosswalk ------------------------------
# map_state_to_acog() lives in mufflyt/isochrones and is loaded rather than
# reimplemented; the district definitions there were corrected against the ACOG
# website in 2025-12 and a local copy would silently miss that.
acog_home <- Sys.getenv("ISOCHRONES_HOME", path.expand("~/isochrones-main"))
acog_ok <- FALSE
if (file.exists(file.path(acog_home, "R", "acog_districts.R"))) {
  local({
    owd <- setwd(acog_home); on.exit(setwd(owd), add = TRUE)
    suppressWarnings(suppressMessages(
      sys.source(file.path("R", "acog_districts.R"), envir = globalenv())))
  })
  acog_ok <- exists("map_state_to_acog", mode = "function")
}
# Coverage guard: every state code must map to a district or be an expected
# exclusion (overseas military AA/AE/AP, US territories). Anything else is junk
# in the state field. This cohort's Unknown row was hiding MONTSERRADO (Liberia)
# and RHINELAND-PFALZ (Germany) among 38 legitimate exclusions -- indistinguishable
# until the two kinds were separated.
if (acog_ok) {
  ex <- tryCatch(
    assert_acog_coverage(coh$nppes_state,
                         context = "Table 1: nppes_state -> ACOG district"),
    error = function(e) {
      # Report rather than abort: the two foreign values are a known upstream
      # defect in the AMCB/NPPES state field, not a reason to withhold the whole
      # table. They are counted as excluded and named here.
      message("ACOG coverage guard: ", conditionMessage(e))
      integer(0)
    })
  if (length(ex))
    cat(sprintf("excluded from district analysis: %s\n",
                paste(sprintf("%s=%d", names(ex), ex), collapse = ", ")))
}

# ACOG district. THE ASSIGNMENT WAS DELETED AT SOME POINT while the block that
# publishes it remained, so Table 1 shipped with an empty ACOG section and
# nothing failed -- blk() on a NULL column returns zero rows AND zero
# "Unknown", so the category simply disappeared. Restored 2026-08-10.
n_acog_excluded <- if (acog_ok)
  sum(coh$nppes_state %in% ACOG_EXPECTED_UNMAPPED, na.rm = TRUE) else 0L

coh$acog_district <- if (acog_ok) {
  suppressWarnings(map_state_to_acog(coh$nppes_state))
} else {
  warning("canonical ACOG crosswalk not found; district left NA", call. = FALSE)
  NA_character_
}


if (!exists("ACOG_EXPECTED_UNMAPPED")) {
  ACOG_EXPECTED_UNMAPPED <- c("AA", "AE", "AP", "GU", "PR", "VI", "AS", "MP", "FM", "PW", "MH")
}

# --- rurality, from county via RUCC -------------------------------------------
geo_paths <- c(
  "artifacts/midwives_geography_FROZEN.csv",
  "artifacts/amcb_npi_geography.csv"
)
geo_path <- geo_paths[file.exists(geo_paths)][1]
if (!is.na(geo_path)) {
  geo <- read_csv(geo_path, show_col_types = FALSE, progress = FALSE)
  county_col <- names(geo)[str_detect(names(geo), "county_best|county_fips|practice_fips|county")][1]
  if (!is.na(county_col)) {
    geo <- geo %>% select(certification_number, county_best = !!sym(county_col))
    rucc_raw <- read_excel("data/rucc_2023.xlsx")
    rucc <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)
    coh <- coh %>%
      left_join(geo, by = "certification_number") %>%
      mutate(county = str_pad(as.character(county_best), 5, "left", "0")) %>%
      left_join(rucc, by = "county") %>%
      mutate(rurality = band_rurality(rucc))
  }
}

# --- NPPES sex and enumeration date -------------------------------------------
sx <- "artifacts/nppes_sex_enumeration.csv"
if (file.exists(sx)) {
  nd <- read_csv(sx, show_col_types = FALSE, progress = FALSE) %>%
    mutate(npi = as.character(npi)) %>% distinct(npi, .keep_all = TRUE)
  coh <- coh %>% mutate(npi = as.character(npi)) %>% left_join(nd, by = "npi")
} else {
  warning("artifacts/nppes_sex_enumeration.csv absent; sex and enumeration NA",
          call. = FALSE)
  coh$sex_code <- NA_character_; coh$enumeration_date <- NA_character_
}
coh <- coh %>%
  mutate(
    # NPPES calls this "Provider Sex Code" (2025 layout) and "Provider Gender
    # Code" (2022). It is administrative sex as recorded at enumeration, NOT
    # gender identity, and is labelled that way throughout.
    # F/M/X/U all occur in the extract. X and U are RECORDED values, not
    # missing, and collapsing them into the unknown row would erase 19 people
    # and overstate the female share by pretending the denominator is cleaner
    # than it is. Only a blank code is missing.
    sex = case_when(sex_code == "F" ~ "Female",
                    sex_code == "M" ~ "Male",
                    sex_code == "X" ~ "X (not listed as F or M)",
                    sex_code == "U" ~ "U (unspecified in NPPES)",
                    TRUE ~ NA_character_),
    enum_year = parse_enum_year(enumeration_date, max_year = REF_YEAR),
    yrs_since_enum = REF_YEAR - enum_year,
    enum_band = band_years_since_enum(yrs_since_enum))

# --- years active, from the NPPES snapshot panel ------------------------------
# "Years active" here is YEARS OBSERVED IN NPPES: the span from first to last
# annual snapshot in which the NPI appears. It is a presence measure, not a
# clinical-activity measure -- an NPI can persist after someone stops
# practising, and the panel starts in 2007, so anyone enumerated earlier is
# left-censored. Named accordingly.
pnl <- "artifacts/midwife_panel_midwifeonly.csv"
if (file.exists(pnl)) {
  yrs <- read_csv(pnl, show_col_types = FALSE, progress = FALSE) %>%
    filter(!is.na(snapshot_year)) %>%
    group_by(npi = as.character(npi)) %>%
    summarise(first_seen = min(snapshot_year), last_seen = max(snapshot_year),
              n_snapshots = n_distinct(snapshot_year), .groups = "drop") %>%
    mutate(yrs_observed = last_seen - first_seen + 1,
           left_censored = first_seen == min(first_seen))
  coh <- coh %>% left_join(yrs, by = "npi")
} else {
  coh$yrs_observed <- NA_real_; coh$first_seen <- NA_real_
}
coh <- coh %>%
  mutate(active_band = band_years_observed(yrs_observed))

# --- NPPES Geography, Taxonomy & Address Concordance ------------------------
geo_npi_file <- "artifacts/amcb_npi_geography.csv"
if (file.exists(geo_npi_file)) {
  geo_npi <- read_csv(geo_npi_file, show_col_types = FALSE, progress = FALSE) %>%
    select(npi, taxonomy_description, practice_mailing_state_differs) %>%
    mutate(
      npi = as.character(npi),
      state_concordance = case_when(
        practice_mailing_state_differs == FALSE ~ "Same practice and mailing state",
        practice_mailing_state_differs == TRUE ~ "Different practice and mailing state (Cross-state practice)",
        TRUE ~ NA_character_
      )
    )
  coh <- coh %>% mutate(npi = as.character(npi)) %>% left_join(geo_npi, by = "npi")
  cat("Merged NPPES taxonomy and address concordance into cohort.\n")
}
calib_age_file <- "artifacts/amcb_calibrated_ages.csv"
if (file.exists(calib_age_file)) {
  calib_df <- read_csv(calib_age_file, show_col_types = FALSE, progress = FALSE) %>%
    select(certification_number, age_band, is_imputed, age_source, years_certified) %>%
    mutate(
      cert_year_band = case_when(
        years_certified < 5 ~ "<5 years",
        years_certified >= 5 & years_certified < 10 ~ "5-9 years",
        years_certified >= 10 & years_certified < 20 ~ "10-19 years",
        years_certified >= 20 & years_certified < 30 ~ "20-29 years",
        years_certified >= 30 ~ ">=30 years",
        TRUE ~ NA_character_
      ),
      age_provenance = case_when(
        age_source %in% c("OH_Voter_Direct_DOB", "WA_Direct_BirthYear", "Healthgrades_Direct", "FL_Voter_Direct_DOB") ~ "Direct Verified DOB (OH/WA/FL/HG)",
        age_source == "IL_Derived_IssueYear" ~ "Derived State License Issue Date",
        TRUE ~ "OLS Calibrated Imputation"
      )
    )
  coh <- coh %>% left_join(calib_df, by = "certification_number")
  cat("Merged calibrated empirical age blocks into cohort.\n")
}

# --- CMS Doctors & Clinicians (DAC): practice structure ----------------------
# Produced by extract_dac_cnm_education.R, one row per NPI.
#
# EVERY DAC VARIABLE IS CAPPED AT DAC MEMBERSHIP, and that membership is not
# random: DAC is built from PECOS Medicare ENROLLMENT, so these rows describe
# Medicare-enrolled midwives (40.9% of the cohort), not the workforce. The
# "Unknown / not recorded" line on each block is overwhelmingly "not enrolled
# in Medicare", which is a substantive state rather than missing data.
#
# WITHIN DAC, a missing num_org_mem means NO GROUP -- solo practice. That is
# information, so it gets its own level rather than joining the same NA as the
# 7,050 midwives who are simply not in DAC. Merging them would put 498 solo
# practitioners in a row that means "we do not know".
dacx <- NULL
if (file.exists("artifacts/dac_cnm_education.csv")) {
  dacx <- read_csv("artifacts/dac_cnm_education.csv", show_col_types = FALSE,
                   progress = FALSE) %>%
    mutate(npi = as.character(NPI)) %>%
    distinct(npi, .keep_all = TRUE) %>%
    select(npi, num_org_mem, n_locations, accepts_assignment)
  coh <- coh %>%
    mutate(npi = as.character(npi)) %>%
    left_join(dacx, by = "npi", relationship = "one-to-one") %>%
    mutate(
      in_dac              = !is.na(n_locations),
      dac_practice_size   = band_practice_size(num_org_mem, in_dac),
      dac_practice_sites  = band_practice_locations(n_locations),
      dac_assignment      = label_medicare_assignment(accepts_assignment))
}

# --- HPSA / shortage-area status ----------------------------------------------
# Produced by assign_hpsa_status.R: point-in-polygon of the geocoded practice
# location against the HRSA primary-care HPSA layer.
#
# THE LEVELS ARE NOT INTERCHANGEABLE, and collapsing them would overstate
# shortage exposure roughly tenfold:
#   * only 9,819 of 22,033 polygons are DESIGNATED; 12,214 are proposed for
#     withdrawal, and counting those would inflate the figure by more than half;
#   * of the designated, 7,467 are POPULATION-GROUP designations that apply to
#     a group within the area (low-income, migrant, homeless) rather than to
#     the location -- a midwife whose office sits inside one is not thereby
#     serving that group. Only the 2,352 geographic designations describe the
#     place itself.
# Measured: 2.9% geographic versus 27.8% population-only. A single "in a HPSA"
# row would have reported the larger number.
#
# DISCIPLINE. Every polygon is PRIMARY CARE. There is no obstetric or midwifery
# HPSA, so this is a proxy for underservice where midwives practise, not a
# measure of maternity-care shortage.
hpsa <- NULL
if (file.exists("artifacts/hpsa_status.csv")) {
  hpsa <- read_csv("artifacts/hpsa_status.csv", show_col_types = FALSE,
                   progress = FALSE) %>%
    distinct(certification_number, .keep_all = TRUE)
  coh <- coh %>%
    left_join(hpsa %>% select(certification_number, hpsa_geographic,
                              hpsa_population_only, hpsa_withdrawal_only),
              by = "certification_number", relationship = "one-to-one") %>%
    mutate(hpsa_status = dplyr::case_when(
      is.na(hpsa_geographic) ~ NA_character_,
      hpsa_geographic        ~ "Designated geographic primary-care HPSA",
      hpsa_population_only   ~ "Population-group HPSA only (not location-based)",
      hpsa_withdrawal_only   ~ "HPSA proposed for withdrawal only",
      TRUE                   ~ "Not in a primary-care HPSA"))
}

# --- Medicare participation (Part B and Part D, 2013-2023) --------------------
# Produced by match_medicare_partb_partd.R against the CMS Physician & Other
# Practitioners file and the Part D Prescribers file, one row per provider per
# year, eleven years matched on BOTH sides.
#
# ABSENCE IS NOT ZERO. CMS suppresses any provider-year below 11 beneficiaries,
# so a midwife absent from a file billed nothing OR billed fewer than 11
# beneficiaries -- indistinguishable here. The rows below say "no record of",
# never "did not bill", and the negative level is named accordingly.
mcare <- NULL
if (file.exists("artifacts/medicare_participation.csv")) {
  mcare <- read_csv("artifacts/medicare_participation.csv",
                    show_col_types = FALSE, progress = FALSE) %>%
    distinct(certification_number, .keep_all = TRUE)
  coh <- coh %>% left_join(
    mcare %>% select(certification_number, part_b_any, part_d_any),
    by = "certification_number", relationship = "one-to-one") %>%
    mutate(
      medicare_part_b = dplyr::if_else(is.na(part_b_any), NA_character_,
        dplyr::if_else(part_b_any, "Billed Part B in at least one year",
                       "No Part B record (billed <11 beneficiaries, or none)")),
      medicare_part_d = dplyr::if_else(is.na(part_d_any), NA_character_,
        dplyr::if_else(part_d_any, "Prescribed under Part D in at least one year",
                       "No Part D record (billed <11 beneficiaries, or none)")))
}

# --- Healthgrades banded columns ----------------------------------------------
if (!is.null(hg_link)) {
  hg_link <- hg_link %>%
    mutate(
      hg_age_band  = band_hg_age(hg_age),
      hg_lang_flag = dplyr::if_else(
        !is.na(hg_languages) & hg_languages != "" &
          !str_to_lower(trimws(hg_languages)) %in% c("english", "english only"),
        "Yes", NA_character_)
    )
}

# --- assemble, long format, per the isochrones vignette -----------------------
# Percentages use the non-missing denominator, and the missing count is emitted
# as its own row so the two are never confused.
blk <- function(df, col, category, lvls = NULL) {
  # AN ABSENT COLUMN IS AN ERROR, NOT AN EMPTY BLOCK. df[[col]] on a missing
  # column returns NULL; as.character(NULL) has zero rows and sum(is.na(NULL))
  # is 0, so the category vanished from the table entirely -- no rows, no
  # "Unknown", no warning. That is how the ACOG block disappeared. A published
  # block that silently omits itself is worse than one that fails loudly.
  if (!col %in% names(df)) {
    stop(sprintf(paste0("Table 1 block '%s' requires column '%s', which is not ",
                        "present. Refusing to emit an empty category."),
                 category, col), call. = FALSE)
  }
  v <- df[[col]]
  known <- sum(!is.na(v))
  out <- tibble(characteristic = as.character(v)) %>%
    filter(!is.na(characteristic)) %>%
    count(characteristic, name = "n") %>%
    mutate(percent = round(100 * n / known, 1), category = category)
  if (!is.null(lvls))
    out <- out %>% arrange(match(characteristic, lvls))
  else
    out <- out %>% arrange(desc(n))
  miss <- sum(is.na(v))
  if (miss > 0)
    out <- bind_rows(out, tibble(characteristic = "Unknown / not recorded",
                                 n = miss, percent = NA_real_, category = category))
  out
}

# Parallel helper for Healthgrades-derived rows. Uses the HG-eligible
# denominator (N - shared-profile exclusions) rather than the full cohort N.
blk_hg <- function(col, category, lvls = NULL, binary_yes = NULL) {
  if (is.null(hg_link) || !col %in% names(hg_link)) {
    return(tibble(characteristic = "Healthgrades data not available",
                  n = NA_integer_, percent = NA_real_, category = category))
  }
  N_hg <- N - length(hg_ambiguous)
  v <- hg_link[[col]]
  if (!is.null(binary_yes))
    v <- dplyr::if_else(as.character(v) %in% as.character(binary_yes),
                        "Yes",
                        dplyr::if_else(is.na(v), NA_character_, "No"))
  known <- sum(!is.na(v))
  out <- tibble(characteristic = as.character(v)) %>%
    filter(!is.na(characteristic)) %>%
    count(characteristic, name = "n") %>%
    mutate(percent = round(100 * n / known, 1), category = category)
  if (!is.null(lvls))
    out <- out %>% arrange(match(characteristic, lvls))
  else
    out <- out %>% arrange(desc(n))
  miss <- max(0L, N_hg - known)
  bind_rows(out, tibble(characteristic = "Unknown / not recorded",
                        n = miss, percent = NA_real_, category = category))
}

t1 <- bind_rows(
  tibble(characteristic = "ACTIVE, primary-linked midwives", n = N,
         percent = 100, category = "Cohort"),

  blk(coh, "certification", "Certification"),
  if ("taxonomy_description" %in% names(coh))
    blk(coh, "taxonomy_description", "Primary NPPES Specialty Taxonomy"),
  # SEX -- ONE BLOCK, MERGED. Healthgrades sex was published separately; the two
  # are now one row set because the merge adds no coverage and only
  # confirmation. Measured on this cohort: NPPES has sex for 11,905 (99.9%),
  # Healthgrades for 5,878 (49.3%), and Healthgrades fills ZERO NPPES gaps --
  # every midwife it covers already had a value. Where both exist they agree on
  # 5,876 of 5,878 (99.97%), with 2 disagreements. A merged variable is
  # therefore identical to the NPPES variable; publishing both blocks implied a
  # second, independent measurement of the same 11,913 people.
  blk(coh, "sex", "Sex"),
  if ("state_concordance" %in% names(coh))
    blk(coh, "state_concordance", "Practice vs. Mailing State Concordance"),
  if ("age_band" %in% names(coh))
    blk(coh, "age_band", "Calibrated Age (100% Cohort Coverage)",
        lvls = c("<35 years", "35-44 years", "45-54 years", "55-64 years", ">=65 years")),
  if ("cert_year_band" %in% names(coh))
    blk(coh, "cert_year_band", "Years Since AMCB Initial Certification",
        lvls = c("<5 years", "5-9 years", "10-19 years", "20-29 years", ">=30 years")),
  # District percentages are computed on midwives who HAVE a district. Military
  # and territory addresses are excluded by decision (no District X), so they
  # are reported on their own line rather than inside "Unknown", which would
  # imply the district is missing when it is not applicable.
  blk(coh %>% filter(!nppes_state %in% ACOG_EXPECTED_UNMAPPED),
      "acog_district", "ACOG district",
      lvls = if (acog_ok) ACOG_DISTRICT_LEVELS else NULL),
  blk(coh, "rurality", "Rurality (RUCC 2023)",
      lvls = c("Metropolitan (RUCC 1-3)", "Nonmetropolitan, adjacent (RUCC 4-6)",
               "Nonmetropolitan, remote (RUCC 7-9)")),

  if ("dac_practice_size" %in% names(coh))
    blk(coh, "dac_practice_size",
        "Medicare practice group size (CMS DAC)",
        lvls = PRACTICE_SIZE_LEVELS),
  if ("dac_practice_sites" %in% names(coh))
    blk(coh, "dac_practice_sites",
        "Number of practice locations (CMS DAC)",
        lvls = PRACTICE_LOCATION_LEVELS),
  if ("dac_assignment" %in% names(coh))
    blk(coh, "dac_assignment",
        "Medicare assignment (CMS DAC)",
        lvls = MEDICARE_ASSIGNMENT_LEVELS),

  if ("hpsa_status" %in% names(coh))
    blk(coh, "hpsa_status", "Primary-care shortage area (HRSA HPSA)",
        lvls = c("Designated geographic primary-care HPSA",
                 "Population-group HPSA only (not location-based)",
                 "HPSA proposed for withdrawal only",
                 "Not in a primary-care HPSA")),

  if ("medicare_part_b" %in% names(coh))
    blk(coh, "medicare_part_b", "Medicare Part B, any year 2013-2023",
        lvls = c("Billed Part B in at least one year",
                 "No Part B record (billed <11 beneficiaries, or none)")),
  if ("medicare_part_d" %in% names(coh))
    blk(coh, "medicare_part_d", "Medicare Part D, any year 2013-2023",
        lvls = c("Prescribed under Part D in at least one year",
                 "No Part D record (billed <11 beneficiaries, or none)")),

  # Language: use Healthgrades data when available; otherwise note it is absent.
  # LANGUAGE IS A FLOOR, NOT A PROPORTION.
  #
  # Published as a block, this read "Yes 367, 100.0%" -- because hg_lang_flag is
  # only ever "Yes" or NA, so the denominator was the 367 who have a language
  # listed. "Of midwives listed as speaking another language, 100% speak
  # another language" is circular, and it is the kind of number that gets
  # quoted as a prevalence.
  #
  # hg_languages is present on 6.4% of profiles, and absence means NOT LISTED,
  # not "English only" -- Healthgrades publishes no negative. So the only
  # defensible statement is a lower bound against the eligible denominator,
  # reported the same way hg_medicaid_named already is.
  if (!is.null(hg_link) && "hg_lang_flag" %in% names(hg_link))
    local({
      n_yes <- sum(hg_link$hg_lang_flag == "Yes", na.rm = TRUE)
      den   <- N - length(hg_ambiguous)
      tibble(
        characteristic = c(
          "At least this many speak a language other than English",
          "Not listed (absence is not evidence of English-only)"),
        n = c(n_yes, den - n_yes),
        percent = c(round(100 * n_yes / den, 1), NA_real_),
        category = "Language (Healthgrades floor)")
    })
  else
    tibble(characteristic = "Not collected by NPPES, CMS DAC or the Healthgrades scrape",
           n = NA_integer_, percent = NA_real_, category = "Language"),

  # Healthgrades-derived person-level characteristics
  blk_hg("hg_accepts_new_patients", "Accepts new patients",
          binary_yes = c("TRUE", "true", "Yes", "yes", TRUE)),
  blk_hg("hg_has_telehealth", "Offers telehealth",
          binary_yes = c("TRUE", "true", "Yes", "yes", TRUE)),

  # The "Healthgrades-derived fields" block was removed from the table body on
  # request. The DENOMINATOR IT CARRIED IS NOT DROPPED -- it moves to the
  # header note, which already states it, because a Healthgrades row divided by
  # the wrong N is the error the block existed to prevent. The exclusion count
  # is also written to artifacts/table1_provenance.csv every build.
  NULL
)

write_csv(t1, "artifacts/table1_midwives.csv", na = "")

# Vintage stamp. The Healthgrades crawl is still running, so the ambiguity
# count is a function of WHEN this was built. Recording the scrape vintage
# lets the test suite assert that Table 1 is internally consistent with the
# data it actually saw, and report drift against a moving crawl as drift
# rather than as a defect. Without this the suite is red by construction.
readr::write_csv(tibble::tibble(
  built_at            = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  scrape_rows         = if (exists("hg")) nrow(hg) else NA_integer_,
  scrape_certificants = if (exists("hg")) dplyr::n_distinct(hg$certification_number) else NA_integer_,
  cohort_n            = N,
  hg_ambiguous_cohort = length(hg_ambiguous)),
  "artifacts/table1_provenance.csv")

# --- markdown render ----------------------------------------------------------
md <- c("# Table 1. Characteristics of the ACTIVE certified-midwife cohort", "",
        sprintf("Cohort: **%s** midwives with AMCB status ACTIVE and a primary-tier NPI link.",
                format(N, big.mark = ",")),
        "Percentages are within category and use the non-missing denominator;",
        "unknowns are counted on their own row.", "",
        sprintf(paste0("Registry-derived rows use the full cohort. Healthgrades-derived ",
                       "rows use a smaller denominator of **%s**: %s a Healthgrades ",
                       "profile with another certificant and cannot be attributed one. ",
                       "They remain in the cohort for every registry-derived row above. ACOG district percentages exclude %s midwives with an overseas-military or US-territory address, so that block sums to %s rather than the full cohort."),
                format(N - length(hg_ambiguous), big.mark = ","),
                if (length(hg_ambiguous) == 1L) "one midwife shares"
                else sprintf("%s midwives share",
                             format(length(hg_ambiguous), big.mark = ",")),
                format(n_acog_excluded, big.mark = ","),
                format(N - n_acog_excluded, big.mark = ",")), "",
        "| Characteristic | n | % |", "|---|---:|---:|")
for (cat_i in unique(t1$category)) {
  md <- c(md, sprintf("| **%s** | | |", cat_i))
  d <- t1[t1$category == cat_i, ]
  for (i in seq_len(nrow(d)))
    md <- c(md, sprintf("| %s | %s | %s |", d$characteristic[i],
                        ifelse(is.na(d$n[i]), "—", format(d$n[i], big.mark = ",")),
                        ifelse(is.na(d$percent[i]), "—",
                               sprintf("%.1f", d$percent[i]))))
}
dir.create("docs", showWarnings = FALSE)
writeLines(md, "docs/table1_midwives.md")

# Also render HTML. The markdown is the source of truth, but .md is associated
# with TeXShop on this machine, which renders LaTeX and shows the raw pipe
# table instead. Generating both here keeps them from drifting; if pandoc is
# absent the markdown still ships and the failure is announced rather than
# silent.
local({
  if (nzchar(Sys.which("pandoc"))) {
    css <- tempfile(fileext = ".html")
    writeLines(c(
      "<style>",
      " body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:52rem;",
      "      margin:2rem auto;padding:0 1.5rem;line-height:1.5;color:#1a1a1a}",
      " table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}",
      " th,td{padding:.35rem .6rem;border-bottom:1px solid #e3e3e3;text-align:left}",
      " td:nth-child(2),td:nth-child(3),th:nth-child(2),th:nth-child(3){text-align:right}",
      " thead th{border-bottom:2px solid #333}",
      " tr:has(td strong){background:#f4f6f8}",
      " h1{font-size:1.5rem;border-bottom:2px solid #333;padding-bottom:.4rem}",
      "</style>"), css)
    st <- system2("pandoc", c("docs/table1_midwives.md", "-s", "--embed-resources",
                              "--metadata", shQuote("title=Table 1"),
                              "-H", shQuote(css), "-o", "docs/table1_midwives.html"),
                  stdout = FALSE, stderr = FALSE)
    if (st == 0L) cat("written: docs/table1_midwives.html\n")
    else cat("NOTE: pandoc failed; docs/table1_midwives.html not refreshed\n")
  } else {
    cat("NOTE: pandoc not found; docs/table1_midwives.html not refreshed\n")
  }
})

cat("\n"); print(as.data.frame(t1), row.names = FALSE)
cat("\nwritten: artifacts/table1_midwives.csv, docs/table1_midwives.md\n")
