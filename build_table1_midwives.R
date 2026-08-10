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

# --- cohort -------------------------------------------------------------------
link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv",
                 show_col_types = FALSE, progress = FALSE)
coh <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number, .keep_all = TRUE)
N <- nrow(coh)
cat(sprintf("cohort: %s ACTIVE primary-linked midwives\n", format(N, big.mark = ",")))

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
coh$acog_district <- if (acog_ok) {
  suppressWarnings(map_state_to_acog(coh$nppes_state))
} else {
  warning("canonical ACOG crosswalk not found; district left NA", call. = FALSE)
  NA_character_
}

# --- rurality, from county via RUCC -------------------------------------------
geo <- read_csv("artifacts/midwives_geography_FROZEN.csv",
                show_col_types = FALSE, progress = FALSE) %>%
  select(certification_number, county_best)
rucc <- read_excel("data/rucc_2023.xlsx") %>%
  transmute(county = str_pad(as.character(FIPS), 5, "left", "0"),
            rucc = as.integer(RUCC_2023)) %>%
  distinct(county, .keep_all = TRUE)
coh <- coh %>%
  left_join(geo, by = "certification_number") %>%
  mutate(county = str_pad(as.character(county_best), 5, "left", "0")) %>%
  left_join(rucc, by = "county") %>%
  mutate(rurality = case_when(
    is.na(rucc) ~ NA_character_,
    rucc <= 3   ~ "Metropolitan (RUCC 1-3)",
    rucc <= 6   ~ "Nonmetropolitan, adjacent (RUCC 4-6)",
    TRUE        ~ "Nonmetropolitan, remote (RUCC 7-9)"))

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
    enum_year = suppressWarnings(as.integer(str_sub(
      str_replace_all(as.character(enumeration_date), "[^0-9/]", ""), -4))),
    yrs_since_enum = REF_YEAR - enum_year,
    yrs_since_enum = if_else(yrs_since_enum >= 0 & yrs_since_enum <= 25,
                             yrs_since_enum, NA_real_),
    enum_band = case_when(
      is.na(yrs_since_enum) ~ NA_character_,
      yrs_since_enum < 5    ~ "<5 years",
      yrs_since_enum < 10   ~ "5-9 years",
      yrs_since_enum < 15   ~ "10-14 years",
      yrs_since_enum < 20   ~ "15-19 years",
      TRUE                  ~ ">=20 years"))

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
  mutate(active_band = case_when(
    is.na(yrs_observed) ~ NA_character_,
    yrs_observed < 5    ~ "<5 years",
    yrs_observed < 10   ~ "5-9 years",
    yrs_observed < 15   ~ "10-14 years",
    TRUE                ~ ">=15 years"))

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

t1 <- bind_rows(
  tibble(characteristic = "ACTIVE, primary-linked midwives", n = N,
         percent = 100, category = "Cohort"),

  blk(coh, "certification", "Certification"),
  blk(coh, "sex", "Sex recorded in NPPES"),
  blk(coh, "acog_district", "ACOG district"),
  blk(coh, "rurality", "Rurality (RUCC 2023)",
      lvls = c("Metropolitan (RUCC 1-3)", "Nonmetropolitan, adjacent (RUCC 4-6)",
               "Nonmetropolitan, remote (RUCC 7-9)")),
  blk(coh, "enum_band", "Years since NPI enumeration",
      lvls = c("<5 years", "5-9 years", "10-14 years", "15-19 years", ">=20 years")),
  blk(coh, "active_band", "Years observed in NPPES",
      lvls = c("<5 years", "5-9 years", "10-14 years", ">=15 years")),

  tibble(characteristic = "Not collected by NPPES, CMS DAC or the Healthgrades scrape",
         n = NA_integer_, percent = NA_real_, category = "Language")
)

write_csv(t1, "artifacts/table1_midwives.csv", na = "")

# --- markdown render ----------------------------------------------------------
md <- c("# Table 1. Characteristics of the ACTIVE certified-midwife cohort", "",
        sprintf("Cohort: **%s** midwives with AMCB status ACTIVE and a primary-tier NPI link.",
                format(N, big.mark = ",")),
        "Percentages are within category and use the non-missing denominator;",
        "unknowns are counted on their own row.", "",
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
