source(file.path("R", "lib", "table1_bands.R"))  # band_rurality()
#!/usr/bin/env Rscript
# =============================================================================
# County midwifery supply: AHRF + CMS facilities + midwives per 1,000 births
# =============================================================================
# Adds three things to the county spine:
#
#   1. AHRF 2024-2025 county nurse-midwife counts (apn_midwvs_npi_24/_23)
#   2. Obstetric CAPACITY, which is not the same as hospital presence:
#      AHRF stgh_birth_postprtm_rm_23 (birthing/postpartum rooms) plus CMS
#      Provider of Services counts of hospitals and critical access hospitals
#   3. Midwives per 1,000 BIRTHS, alongside the conventional per-100k-population
#      rate
#
# WHY PER BIRTHS. A population denominator conflates midwife supply with a
# county's age and sex structure, and that structure varies systematically along
# the rural gradient this study measures. Births are the actual demand for
# midwifery care. Both rates are emitted so the choice is visible rather than
# buried.
#
# HOW INDEPENDENT IS AHRF, REALLY. AHRF's midwife count is itself NPI-derived
# (the variable is literally named ..._npi_24), so agreement with our
# NPPES-linked cohort is only PARTIAL corroboration -- shared upstream source,
# different vintage and processing. Disagreement is still highly informative:
# it localises where our AMCB linkage adds or loses providers relative to a
# published national file. It is NOT an independent gold standard, and this
# script does not treat it as one.
#
# DENOMINATOR SUPPRESSION. Rates on tiny birth counts are unstable, and the
# instability is rural-selective. Counties under MIN_BIRTHS get a rate of NA
# rather than a noisy number, and the count of such counties is reported.
#
# Inputs : data/ahrf/AHRF2025.csv                (downloaded, see README)
#          data/cms_pos_hospital.csv             (downloaded, see README)
#          data/county_base.csv
#          artifacts/isochrone_representation_by_county.csv
# Output : artifacts/county_midwifery_supply.csv
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
})

MIN_BIRTHS <- 50   # below this a per-1,000-births rate is noise, not signal

AHRF <- "data/ahrf/AHRF2025.csv"
POS  <- "data/cms_pos_hospital.csv"
stopifnot(file.exists(AHRF), file.exists(POS))

# --- 1. AHRF: read ONLY the columns we need ---------------------------------
# The master file is 1,927 columns / 40 MB; reading it whole is wasteful and
# has no upside.
ahrf_cols <- c(
  fips              = "fips_st_cnty",
  county_name       = "cnty_name_st_abbrev",
  ahrf_midwives_24  = "apn_midwvs_npi_24",
  ahrf_midwives_23  = "apn_midwvs_npi_23",
  ahrf_midwives_f24 = "apn_midwvs_npi_fem_24",
  ahrf_births_24    = "births_july_1_june_30_24",
  ahrf_births_3yr   = "births_3yr_avg_23",
  ahrf_birth_rooms  = "stgh_birth_postprtm_rm_23",
  ahrf_hospitals    = "hosp_23",
  ahrf_cah          = "critcl_access_hosp_23",
  ahrf_obgyn        = "md_nf_obgyn_gen_23",
  # --- birth outcomes, 3-year averages (denominator births_3yr_avg_23) ------
  # Counts, not rates: AHRF ships numerators, and dividing them here keeps the
  # denominator explicit rather than inheriting whatever AHRF used.
  ahrf_births_hosp  = "births_stgh_excl_fetal_deth_23",
  ahrf_preterm      = "births_pretrm_3yr_avg_23",
  ahrf_lbw          = "lo_birth_wgt_3yr_avg_23",
  ahrf_vlbw         = "very_lo_birth_wgt_3yr_avg_23",
  ahrf_teen_lt18    = "births_to_teens_3yr_lt18_avg_23",
  ahrf_unmarried    = "birth_unmarrd_3yr_avg_23",
  ahrf_births_wh    = "births_3yr_wh_avg_23",
  ahrf_births_bl    = "births_3yr_bl_avg_23",
  ahrf_births_hsp   = "births_3yr_hsp_avg_23",
  ahrf_births_oth   = "births_3yr_oth_avg_23",
  ahrf_lbw_wh       = "lo_birth_wgt_3yr_wh_avg_23",
  ahrf_lbw_bl       = "lo_birth_wgt_3yr_bl_avg_23")

hdr <- names(read_csv(AHRF, n_max = 0, show_col_types = FALSE))
missing <- setdiff(unname(ahrf_cols), hdr)
if (length(missing))
  stop("AHRF columns absent (vintage change?): ", paste(missing, collapse = ", "))

ahrf <- read_csv(AHRF, col_select = all_of(unname(ahrf_cols)),
                 col_types = cols(.default = col_character()))
names(ahrf) <- names(ahrf_cols)[match(names(ahrf), unname(ahrf_cols))]
ahrf <- ahrf %>%
  mutate(fips = str_pad(fips, 5, "left", "0"),
         across(-c(fips, county_name), ~ suppressWarnings(as.numeric(.))))
cat(sprintf("AHRF counties                : %s\n", nrow(ahrf)))

# --- 2. CMS Provider of Services: facility counts by county -----------------
# CORRECTION (2026-08-09): an earlier version of this file asserted that POS
# "carries no obstetric-service flag", on the strength of one grep that never
# tried the obvious abbreviation. POS column 221 is OB_SRVC_CD and column 461
# is OB_GYN_SRGRY_SW. The claim was wrong and it drove the decision to fall
# back on AHRF birthing rooms.
#
# Obstetric-service counts come from build_ob_hospital_counts() in
# R/lib/ob_hospitals.R -- the canonical implementation in this repo -- rather
# than being rewritten here. It deduplicates superseded POS records, restricts
# to short-term acute (01) and critical access (11), drops terminated
# providers, and keeps "no obstetrics" separate from "did not report".
#
# AHRF birthing rooms are RETAINED alongside, because they measure a different
# thing: rooms are capacity, OB_SRVC_CD is presence of a service.
pos <- read_csv(POS, col_types = cols(.default = col_character())) %>%
  filter(!is.na(FIPS_STATE_CD), !is.na(FIPS_CNTY_CD)) %>%
  mutate(fips = paste0(str_pad(FIPS_STATE_CD, 2, "left", "0"),
                       str_pad(FIPS_CNTY_CD, 3, "left", "0"))) %>%
  filter(PRVDR_CTGRY_CD == "01") %>%
  group_by(fips) %>%
  summarise(pos_hospitals      = n(),
            pos_short_term_gen = sum(PRVDR_CTGRY_SBTYP_CD == "01", na.rm = TRUE),
            pos_critical_acc   = sum(PRVDR_CTGRY_SBTYP_CD == "11", na.rm = TRUE),
            .groups = "drop")
cat(sprintf("POS counties with a hospital : %s\n", nrow(pos)))

source("R/lib/ob_hospitals.R")
obh <- build_ob_hospital_counts() %>%
  transmute(fips = str_pad(as.character(GEOID), 5, "left", "0"),
            n_hosp_active, n_hosp_ob, n_hosp_ob_unknown)
cat(sprintf("counties with an active hospital: %s | with an OB service: %s\n",
            nrow(obh), sum(obh$n_hosp_ob > 0)))

# --- 3. our own cohort's county counts --------------------------------------
ours <- read_csv("artifacts/isochrone_representation_by_county.csv",
                 show_col_types = FALSE) %>%
  transmute(fips = str_pad(as.character(county), 5, "left", "0"),
            study_midwives = n_midwives,
            study_represented = n_represented, rucc)

base <- read_csv("data/county_base.csv", show_col_types = FALSE) %>%
  mutate(fips = str_pad(as.character(GEOID), 5, "left", "0")) %>%
  select(fips, county_name_base = county_name, state, population,
         acs_births = births_past_12mo, women_15_44, rucc_2023, pct_rural)

# left_join FROM the county spine: a county with zero midwives must appear as a
# zero, not vanish. Dropping empty counties would delete precisely the rural
# tail the study is about.
d <- base %>%
  left_join(ahrf, by = "fips") %>%
  left_join(pos,  by = "fips") %>%
  left_join(obh,  by = "fips") %>%
  left_join(ours, by = "fips") %>%
  mutate(across(c(study_midwives, study_represented, pos_hospitals,
                  pos_short_term_gen, pos_critical_acc,
                  n_hosp_active, n_hosp_ob, n_hosp_ob_unknown),
                ~ coalesce(., 0L)))

# --- 4. rates ---------------------------------------------------------------
# Births preference: AHRF (NCHS vital statistics) over the ACS 12-month
# estimate, which is survey-based and noisy in small counties. Which one was
# used per row is recorded.
d <- d %>%
  mutate(
    births_used   = coalesce(ahrf_births_24, ahrf_births_3yr, acs_births),
    births_source = case_when(!is.na(ahrf_births_24) ~ "AHRF_natality_24",
                              !is.na(ahrf_births_3yr) ~ "AHRF_natality_3yr",
                              !is.na(acs_births)      ~ "ACS_past_12mo",
                              TRUE                    ~ NA_character_),
    # safe_rate() from mufflyaccess handles the zero denominator, the NA and
    # the Inf that round() would otherwise carry into a published table.
    midwives_per_1k_births =
      if_else(!is.na(births_used) & births_used >= MIN_BIRTHS,
              mufflyaccess::safe_rate(study_midwives, births_used,
                                      multiplier = 1000, digits = 2), NA_real_),
    ahrf_midwives_per_1k_births =
      if_else(!is.na(births_used) & births_used >= MIN_BIRTHS & !is.na(ahrf_midwives_24),
              round(1000 * ahrf_midwives_24 / births_used, 2), NA_real_),
    midwives_per_100k_pop =
      mufflyaccess::safe_rate(study_midwives, population,
                              multiplier = 1e5, digits = 2),
    birth_rooms_per_1k_births =
      if_else(!is.na(births_used) & births_used >= MIN_BIRTHS & !is.na(ahrf_birth_rooms),
              round(1000 * ahrf_birth_rooms / births_used, 2), NA_real_),
    no_hospital = pos_hospitals == 0,
    # Three-way, deliberately. A county whose hospitals never reported an
    # obstetric status has not reported "no obstetrics" -- and POS reporting is
    # sparsest among small rural hospitals, so collapsing "unreported" into
    # "no" would understate obstetric capacity exactly where this study is most
    # sensitive.
    ob_hospital_status = case_when(
      n_hosp_active == 0    ~ "no hospital",
      n_hosp_ob > 0         ~ "hospital with obstetrics",
      n_hosp_ob_unknown > 0 ~ "hospital, obstetrics unreported",
      TRUE                  ~ "hospital, no obstetrics"),
    ob_hospitals_per_1k_births =
      if_else(!is.na(births_used) & births_used >= MIN_BIRTHS,
              mufflyaccess::safe_rate(n_hosp_ob, births_used,
                                      multiplier = 1000, digits = 2), NA_real_),
    # AUDIT 2026-08-10. This copy of the RUCC rule was missed by the cycle-1
    # and cycle-2 sweeps, which scanned R/ and not the root-level scripts. It
    # still carried the original defect: a terminal TRUE branch labels ANY
    # unexpected code -- 0, 10, a 99 "not classified" sentinel -- as
    # "Nonmetro, remote". Rurality is the stratifier for the access findings,
    # and this file writes a published artifact.
    rurality = band_rurality(rucc_2023, RURALITY_LABELS_SHORT))

# --- 4b. birth outcome rates ------------------------------------------------
# All AHRF outcome numerators are 3-year averages, so they are divided by the
# matching 3-year average denominator -- NOT by the single-year birth count used
# for the supply rates. Mixing the two would inflate every outcome rate by
# roughly the ratio of the periods.
MIN_OUT <- 100   # outcome rates need a larger base than supply rates
d <- d %>%
  mutate(
    outcome_denom = ahrf_births_3yr,
    outcome_base_ok = !is.na(outcome_denom) & outcome_denom >= MIN_OUT,
    pct_preterm   = if_else(outcome_base_ok, round(100 * ahrf_preterm / outcome_denom, 2), NA_real_),
    pct_lbw       = if_else(outcome_base_ok, round(100 * ahrf_lbw     / outcome_denom, 2), NA_real_),
    pct_vlbw      = if_else(outcome_base_ok, round(100 * ahrf_vlbw    / outcome_denom, 2), NA_real_),
    pct_teen_lt18 = if_else(outcome_base_ok, round(100 * ahrf_teen_lt18 / outcome_denom, 2), NA_real_),
    pct_unmarried = if_else(outcome_base_ok, round(100 * ahrf_unmarried / outcome_denom, 2), NA_real_),
    # Race-specific LBW rates use race-specific denominators. A county with 4
    # Black births yields a meaningless 0% or 25%, so these carry their own,
    # stricter base requirement.
    pct_lbw_white = if_else(!is.na(ahrf_births_wh) & ahrf_births_wh >= MIN_OUT,
                            round(100 * ahrf_lbw_wh / ahrf_births_wh, 2), NA_real_),
    pct_lbw_black = if_else(!is.na(ahrf_births_bl) & ahrf_births_bl >= MIN_OUT,
                            round(100 * ahrf_lbw_bl / ahrf_births_bl, 2), NA_real_),
    # Non-STGH share: births NOT occurring in a short-term general hospital --
    # home, freestanding birth centre, and other facility types. This is the
    # setting where midwives are disproportionately the attendant, so it is a
    # construct-validity check on the supply measure, NOT an outcome.
    # UNVERIFIED AGAINST THE AHRF TECHNICAL DOC: the numerator is a single-year
    # count and the denominator a 3-year average, and whether the two share a
    # reporting universe is not established. Treat as exploratory until checked;
    # values outside [0,1] are set NA rather than clipped, because an
    # out-of-range value is evidence the two variables are NOT comparable.
    nonhosp_birth_share_RAW = if_else(
      !is.na(ahrf_births_hosp) & !is.na(ahrf_births_24) & ahrf_births_24 >= MIN_OUT,
      round(1 - ahrf_births_hosp / ahrf_births_24, 4), NA_real_),
    nonhosp_birth_share_RAW = if_else(
      !is.na(nonhosp_birth_share_RAW) &
        (nonhosp_birth_share_RAW < 0 | nonhosp_birth_share_RAW > 1),
      NA_real_, nonhosp_birth_share_RAW),
    obgyn_per_1k_births = if_else(!is.na(births_used) & births_used >= MIN_BIRTHS &
                                    !is.na(ahrf_obgyn),
                                  round(1000 * ahrf_obgyn / births_used, 2), NA_real_),
    midwife_share_of_birth_workforce = if_else(
      (study_midwives + coalesce(ahrf_obgyn, 0)) > 0,
      round(study_midwives / (study_midwives + coalesce(ahrf_obgyn, 0)), 3), NA_real_))

cat(sprintf("counties on spine            : %s\n", nrow(d)))
cat(sprintf("outcome rates suppressed (<%s 3yr births): %s\n", MIN_OUT,
            sum(!d$outcome_base_ok, na.rm = TRUE) + sum(is.na(d$outcome_base_ok))))
n_oor <- sum(!is.na(d$ahrf_births_hosp) & !is.na(d$ahrf_births_24) &
               d$ahrf_births_24 >= MIN_OUT & is.na(d$nonhosp_birth_share_RAW))
cat(sprintf("non-hospital share out of range (set NA) : %s\n", n_oor))
cat(sprintf("rate suppressed (<%s births) : %s\n", MIN_BIRTHS,
            sum(is.na(d$midwives_per_1k_births))))
cat(sprintf("counties with 0 study midwives: %s\n", sum(d$study_midwives == 0)))

# --- 5. AHRF vs our cohort: where do they disagree? -------------------------
cmp <- d %>% filter(!is.na(ahrf_midwives_24)) %>%
  mutate(diff = study_midwives - ahrf_midwives_24)
cat("\n=========== OUR COHORT vs AHRF (partial corroboration only) ===========\n")
cat(sprintf("counties compared            : %s\n", nrow(cmp)))
cat(sprintf("total midwives, study cohort : %s\n", format(sum(cmp$study_midwives), big.mark = ",")))
cat(sprintf("total midwives, AHRF 2024    : %s\n", format(sum(cmp$ahrf_midwives_24), big.mark = ",")))
cat(sprintf("counties equal               : %s (%.1f%%)\n",
            sum(cmp$diff == 0), 100 * mean(cmp$diff == 0)))
cat(sprintf("correlation (Spearman)       : %.3f\n",
            suppressWarnings(cor(cmp$study_midwives, cmp$ahrf_midwives_24,
                                 method = "spearman", use = "complete.obs"))))
print(as.data.frame(cmp %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(counties = n(), study = sum(study_midwives), ahrf = sum(ahrf_midwives_24),
            median_diff = median(diff), .groups = "drop")), row.names = FALSE)

cat("\n=========== SUPPLY BY RURALITY ===========\n")
print(as.data.frame(d %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(counties = n(),
            midwives = sum(study_midwives),
            births = sum(births_used, na.rm = TRUE),
            midwives_per_1k_births = round(1000 * sum(study_midwives) /
                                             sum(births_used, na.rm = TRUE), 2),
            pct_counties_no_midwife = round(100 * mean(study_midwives == 0), 1),
            pct_counties_no_hospital = round(100 * mean(no_hospital), 1),
            hosp_with_ob = sum(n_hosp_ob),
            pct_counties_with_ob_hosp = round(100 * mean(n_hosp_ob > 0), 1),
            pct_counties_ob_unreported =
              round(100 * mean(ob_hospital_status == "hospital, obstetrics unreported"), 1),
            birth_rooms = sum(ahrf_birth_rooms, na.rm = TRUE),
            .groups = "drop")), row.names = FALSE)

# --- 6. substitution: who attends births where there is no obstetrician? ----
# The policy question behind the whole study. A county with no OB/GYN but with
# midwives is not the same as a county with neither, and collapsing them into
# "underserved" throws away the distinction that matters for workforce policy.
d <- d %>%
  mutate(provider_config = case_when(
    is.na(ahrf_obgyn)                        ~ NA_character_,
    ahrf_obgyn == 0 & study_midwives == 0    ~ "Neither",
    ahrf_obgyn == 0 & study_midwives > 0     ~ "Midwife only",
    ahrf_obgyn > 0  & study_midwives == 0    ~ "OB/GYN only",
    TRUE                                     ~ "Both"))

cat("\n=========== PROVIDER CONFIGURATION BY RURALITY ===========\n")
cfg <- d %>% filter(!is.na(provider_config), !is.na(rurality)) %>%
  count(rurality, provider_config) %>%
  group_by(rurality) %>% mutate(pct = round(100 * n / sum(n), 1)) %>% ungroup()
print(as.data.frame(cfg %>% select(-n) %>%
  pivot_wider(names_from = provider_config, values_from = pct)), row.names = FALSE)

cat("\n=========== BIRTHS IN COUNTIES WITH NO OBSTETRICIAN ===========\n")
noob <- d %>% filter(!is.na(ahrf_obgyn), ahrf_obgyn == 0)
cat(sprintf("counties with no OB/GYN            : %s of %s (%.1f%%)\n",
            nrow(noob), sum(!is.na(d$ahrf_obgyn)),
            100 * nrow(noob) / sum(!is.na(d$ahrf_obgyn))))
cat(sprintf("  of those, WITH >=1 midwife       : %s (%.1f%%)\n",
            sum(noob$study_midwives > 0), 100 * mean(noob$study_midwives > 0)))
cat(sprintf("births/yr in no-OB counties        : %s\n",
            format(round(sum(noob$births_used, na.rm = TRUE)), big.mark = ",")))
cat(sprintf("  births in no-OB, no-midwife      : %s\n",
            format(round(sum(noob$births_used[noob$study_midwives == 0], na.rm = TRUE)),
                   big.mark = ",")))
print(as.data.frame(noob %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(counties = n(),
            pct_with_midwife = round(100 * mean(study_midwives > 0), 1),
            births = round(sum(births_used, na.rm = TRUE)),
            pct_lbw = round(median(pct_lbw, na.rm = TRUE), 2),
            .groups = "drop")), row.names = FALSE)

cat("\n=========== BIRTH OUTCOMES BY RURALITY (medians) ===========\n")
print(as.data.frame(d %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(counties_rated = sum(outcome_base_ok, na.rm = TRUE),
            pct_preterm = round(median(pct_preterm, na.rm = TRUE), 2),
            pct_lbw     = round(median(pct_lbw, na.rm = TRUE), 2),
            pct_vlbw    = round(median(pct_vlbw, na.rm = TRUE), 2),
            pct_teen    = round(median(pct_teen_lt18, na.rm = TRUE), 2),
            lbw_white   = round(median(pct_lbw_white, na.rm = TRUE), 2),
            lbw_black   = round(median(pct_lbw_black, na.rm = TRUE), 2),
            .groups = "drop")), row.names = FALSE)

write_csv(d, "artifacts/county_midwifery_supply.csv", na = "")
cat("\nwritten: artifacts/county_midwifery_supply.csv\n")
