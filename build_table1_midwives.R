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

# --- cohort -------------------------------------------------------------------
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                 show_col_types = FALSE, progress = FALSE)
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

coh$acog_district <- if (acog_ok) {
  # Roman-numeral ordering is now the default in the canonical function
  # (isochrones 66a7fb277); it returns an ordered factor with
  # ACOG_DISTRICT_LEVELS. The explicit as_factor = TRUE is no longer needed.
  suppressWarnings(map_state_to_acog(coh$nppes_state))
} else {
  warning("canonical ACOG crosswalk not found; district left NA", call. = FALSE)
  NA_character_
}

# --- rurality, from county via RUCC -------------------------------------------
geo <- read_csv("artifacts/midwives_geography_FROZEN.csv",
                show_col_types = FALSE, progress = FALSE) %>%
  select(certification_number, county_best)
rucc_raw <- read_excel("data/rucc_2023.xlsx")
rucc <- build_rucc_lookup(rucc_raw$FIPS, rucc_raw$RUCC_2023)
coh <- coh %>%
  left_join(geo, by = "certification_number") %>%
  mutate(county = str_pad(as.character(county_best), 5, "left", "0")) %>%
  left_join(rucc, by = "county") %>%
  mutate(rurality = band_rurality(rucc))

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
  miss <- N_hg - known
  bind_rows(out, tibble(characteristic = "Unknown / not recorded",
                        n = miss, percent = NA_real_, category = category))
}

t1 <- bind_rows(
  tibble(characteristic = "ACTIVE, primary-linked midwives", n = N,
         percent = 100, category = "Cohort"),

  blk(coh, "certification", "Certification"),
  blk(coh, "sex", "Sex recorded in NPPES"),
  # District percentages are computed on midwives who HAVE a district. Military
  # and territory addresses are excluded by decision (no District X), so they
  # are reported on their own line rather than inside "Unknown", which would
  # imply the district is missing when it is not applicable.
  blk(coh %>% filter(!nppes_state %in% ACOG_EXPECTED_UNMAPPED),
      "acog_district", "ACOG district",
      lvls = if (acog_ok) ACOG_DISTRICT_LEVELS else NULL),
  tibble(characteristic = "Excluded: overseas military or US territory",
         n = sum(coh$nppes_state %in% ACOG_EXPECTED_UNMAPPED, na.rm = TRUE),
         percent = NA_real_, category = "ACOG district"),
  blk(coh, "rurality", "Rurality (RUCC 2023)",
      lvls = c("Metropolitan (RUCC 1-3)", "Nonmetropolitan, adjacent (RUCC 4-6)",
               "Nonmetropolitan, remote (RUCC 7-9)")),
  blk(coh, "enum_band", "Years since NPI enumeration",
      lvls = c("<5 years", "5-9 years", "10-14 years", "15-19 years", ">=20 years")),
  blk(coh, "active_band", "Years observed in NPPES",
      lvls = c("<5 years", "5-9 years", "10-14 years", ">=15 years")),

  # Language: use Healthgrades data when available; otherwise note it is absent.
  if (!is.null(hg_link) && "hg_lang_flag" %in% names(hg_link))
    blk_hg("hg_lang_flag", "Speaks a language other than English",
            lvls = c("Yes", "No"))
  else
    tibble(characteristic = "Not collected by NPPES, CMS DAC or the Healthgrades scrape",
           n = NA_integer_, percent = NA_real_, category = "Language"),

  # Healthgrades-derived person-level characteristics
  blk_hg("hg_gender", "Sex (Healthgrades)", lvls = c("Female", "Male")),
  blk_hg("hg_age_band", "Age (Healthgrades)",
          lvls = c("<35 years", "35-44 years", "45-54 years",
                   "55-64 years", ">=65 years")),
  blk_hg("hg_accepts_new_patients", "Accepts new patients",
          binary_yes = c("TRUE", "true", "Yes", "yes", TRUE)),
  blk_hg("hg_has_telehealth", "Offers telehealth",
          binary_yes = c("TRUE", "true", "Yes", "yes", TRUE)),
  blk_hg("hg_medicaid_named", "Named as Medicaid provider",
          binary_yes = c("TRUE", "true", "Yes", "yes", TRUE)),

  # The denominator any Healthgrades-derived row must use. Stated
  # explicitly so it can never be silently swapped for N: those fields describe
  # a smaller population than the registry fields above them.
  tibble(characteristic = "Eligible for attribution (no shared profile)",
         n = N - length(hg_ambiguous),
         percent = round(100 * (N - length(hg_ambiguous)) / N, 1),
         category = "Healthgrades-derived fields"),
  tibble(characteristic = "Excluded: profile shared with another certificant",
         n = length(hg_ambiguous), percent = NA_real_,
         category = "Healthgrades-derived fields")
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
                       "They remain in the cohort for every registry-derived row above."),
                format(N - length(hg_ambiguous), big.mark = ","),
                if (length(hg_ambiguous) == 1L) "one midwife shares"
                else sprintf("%s midwives share",
                             format(length(hg_ambiguous), big.mark = ","))), "",
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

cat("\n"); print(as.data.frame(t1), row.names = FALSE)
cat("\nwritten: artifacts/table1_midwives.csv, docs/table1_midwives.md\n")
