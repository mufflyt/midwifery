#!/usr/bin/env Rscript
# =============================================================================
# Midwifery and obstetric RATES by congressional district (118th Congress)
# =============================================================================
# BOUNDARY VINTAGE IS THE WHOLE PROBLEM HERE. ACS 5-year 2023 -- the only source
# of district-level births and population -- is published on 118th Congress
# lines. The counts artifact (artifacts/cd_obstetric_workforce.csv) is on 119th
# lines. Several states redistricted between them, so dividing a 119th-boundary
# numerator by a 118th-boundary denominator would produce silently wrong rates
# in exactly those states.
#
# So this script does NOT reuse those counts. It re-assigns every provider to
# 118th-Congress polygons by point-in-polygon, and both numerator and
# denominator therefore describe the same piece of ground. The 119th counts
# remain the current-boundary reference; these are the rate-bearing figures.
# Any figure must state which Congress it uses.
#
# DENOMINATOR. ACS B13002_002E = women 15-50 who had a birth in the past 12
# months. It is a survey estimate with sampling error, not a vital-statistics
# birth count, and it is the same variable already used for county acs_births.
# AHRF/NCHS natality has no congressional-district equivalent.
#
# PROVIDER UNIVERSES, restated because the ratio is easy to misread:
#   * OB/GYN SUBSPECIALISTS (MFM/REI/GO/FPMRS/MIGS/CFP/PAG), not general
#     obstetricians. A zero means no subspecialist, not no obstetric care.
#   * AMCB-certified ACTIVE primary-linked midwives.
#
# Output: artifacts/cd_midwifery_stats.csv
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr); library(jsonlite)
})
sf::sf_use_s2(FALSE)

MIN_BIRTHS <- 500   # ACS district birth estimates are large; this only screens
                    # territories and any district with a degenerate estimate

# --- 1. ACS 2023 5-year, congressional district ------------------------------
key <- Sys.getenv("CENSUS_API_KEY")
if (!nzchar(key)) {
  rl  <- readLines("~/.Renviron", warn = FALSE)
  key <- sub(".*=", "", grep("CENSUS_API_KEY", rl, value = TRUE)[1])
}
key <- gsub("[\"' ]", "", key)
stopifnot(nzchar(key))

vars <- c("B01003_001E",   # total population
          "B13002_001E",   # women 15-50
          "B13002_002E",   # women 15-50 with a birth in the past 12 months
          "B19013_001E")   # median household income
u <- sprintf("https://api.census.gov/data/2023/acs/acs5?get=NAME,%s&for=congressional%%20district:*&key=%s",
             paste(vars, collapse = ","), key)
raw <- jsonlite::fromJSON(u)
acs <- as_tibble(as.data.frame(raw[-1, ], stringsAsFactors = FALSE))
names(acs) <- c("NAME", vars, "STATEFP", "CD118FP")
acs <- acs %>%
  mutate(across(all_of(vars), ~ suppressWarnings(as.numeric(.))),
         # ACS uses negative sentinels (-666666666) for suppressed estimates.
         # Left as NA rather than carried into a rate.
         across(all_of(vars), ~ if_else(. < 0, NA_real_, .))) %>%
  rename(population = B01003_001E, women_15_50 = B13002_001E,
         acs_births = B13002_002E, median_hh_income = B19013_001E)
cat(sprintf("ACS districts fetched: %s\n", nrow(acs)))

# --- 2. districts + providers, both on 118th lines ---------------------------
st_lu <- read_csv("data/county_base.csv", show_col_types = FALSE) %>%
  mutate(STATEFP = str_sub(str_pad(as.character(GEOID), 5, "left", "0"), 1, 2)) %>%
  distinct(STATEFP, state)

cd <- sf::st_read("data/cd118/cb_2023_us_cd118_500k.shp", quiet = TRUE) %>%
  sf::st_transform(4326) %>%
  left_join(st_lu, by = "STATEFP") %>%
  mutate(state = coalesce(state, STATEFP),
         cd_id = paste0(state, "-", CD118FP)) %>%
  select(cd_id, state, STATEFP, CD118FP, cd_name = NAMELSAD, geometry)
cat(sprintf("districts (118th)    : %s\n", nrow(cd)))

ob <- readRDS(path.expand("~/isochrones/artifacts/isochrones/step_2.5_final_cohort.rds")) %>%
  as_tibble() %>% filter(!is.na(latitude), !is.na(longitude)) %>%
  distinct(npi, .keep_all = TRUE) %>% select(id = npi, latitude, longitude)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
mw <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  distinct(certification_number) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  select(id = certification_number, latitude, longitude)

assign_cd <- function(df, label) {
  p <- sf::st_as_sf(df, coords = c("longitude", "latitude"), crs = 4326)
  j <- suppressMessages(sf::st_join(p, cd, join = sf::st_within))
  cat(sprintf("%-9s placed %s, outside any district %s\n",
              label, sum(!is.na(j$cd_id)), sum(is.na(j$cd_id))))
  sf::st_drop_geometry(j) %>% filter(!is.na(cd_id))
}
ob_cd <- assign_cd(ob, "OBsubsp")
mw_cd <- assign_cd(mw, "midwife")

# --- 3. join and rate --------------------------------------------------------
d <- sf::st_drop_geometry(cd) %>%
  left_join(acs %>% select(STATEFP, CD118FP, population, women_15_50,
                           acs_births, median_hh_income),
            by = c("STATEFP", "CD118FP")) %>%
  left_join(ob_cd %>% count(cd_id, name = "n_obgyn_subspec"), by = "cd_id") %>%
  left_join(mw_cd %>% count(cd_id, name = "n_midwife"),       by = "cd_id") %>%
  mutate(across(c(n_obgyn_subspec, n_midwife), ~ coalesce(., 0L)),
         total_obstetric = n_obgyn_subspec + n_midwife,
         rate_ok = !is.na(acs_births) & acs_births >= MIN_BIRTHS,
         midwives_per_1k_births =
           if_else(rate_ok, round(1000 * n_midwife / acs_births, 2), NA_real_),
         obsubspec_per_1k_births =
           if_else(rate_ok, round(1000 * n_obgyn_subspec / acs_births, 2), NA_real_),
         obstetric_workforce_per_1k_births =
           if_else(rate_ok, round(1000 * total_obstetric / acs_births, 2), NA_real_),
         midwives_per_100k_pop =
           if_else(!is.na(population) & population > 0,
                   round(1e5 * n_midwife / population, 2), NA_real_),
         midwife_share = if_else(total_obstetric > 0,
                                 round(n_midwife / total_obstetric, 3), NA_real_))

cat(sprintf("districts with ACS matched: %s of %s\n",
            sum(!is.na(d$population)), nrow(d)))
cat(sprintf("rates suppressed (<%s births): %s\n", MIN_BIRTHS, sum(!d$rate_ok)))

cat("\n=========== NATIONAL (118th districts) ===========\n")
cat(sprintf("midwives            : %s\n", format(sum(d$n_midwife), big.mark = ",")))
cat(sprintf("OB subspecialists   : %s\n", format(sum(d$n_obgyn_subspec), big.mark = ",")))
cat(sprintf("ACS births (12 mo)  : %s\n", format(sum(d$acs_births, na.rm = TRUE), big.mark = ",")))
cat(sprintf("midwives per 1k births (pooled): %.2f\n",
            1000 * sum(d$n_midwife) / sum(d$acs_births, na.rm = TRUE)))

cat("\n=========== LOWEST 15 DISTRICTS: midwives per 1,000 births ===========\n")
print(as.data.frame(d %>% filter(rate_ok) %>%
  arrange(midwives_per_1k_births, cd_id) %>%
  select(cd_id, n_midwife, n_obgyn_subspec, acs_births,
         midwives_per_1k_births, obsubspec_per_1k_births) %>% head(15)),
  row.names = FALSE)

cat("\n=========== HIGHEST 15 DISTRICTS: midwives per 1,000 births ===========\n")
print(as.data.frame(d %>% filter(rate_ok) %>%
  arrange(desc(midwives_per_1k_births)) %>%
  select(cd_id, n_midwife, n_obgyn_subspec, acs_births,
         midwives_per_1k_births, midwife_share) %>% head(15)),
  row.names = FALSE)

cat("\n=========== DISTRIBUTION ===========\n")
qs <- quantile(d$midwives_per_1k_births, c(0, .1, .25, .5, .75, .9, 1), na.rm = TRUE)
print(round(qs, 2))
cat(sprintf("ratio p90/p10       : %.1fx\n", qs[["90%"]] / max(qs[["10%"]], 0.01)))

cat("\n=========== BY STATE (10 largest delegations) ===========\n")
print(as.data.frame(d %>% group_by(state) %>%
  summarise(districts = n(), midwives = sum(n_midwife),
            obsubspec = sum(n_obgyn_subspec),
            births = sum(acs_births, na.rm = TRUE),
            midwives_per_1k_births = round(1000 * sum(n_midwife) /
                                             sum(acs_births, na.rm = TRUE), 2),
            .groups = "drop") %>%
  arrange(desc(districts)) %>% head(10)), row.names = FALSE)

write_csv(d, "artifacts/cd_midwifery_stats.csv", na = "")
cat("\nwritten: artifacts/cd_midwifery_stats.csv\n")
cat("118th Congress boundaries. Counts on 119th lines are in cd_obstetric_workforce.csv;\n")
cat("the two are NOT interchangeable and must not be joined.\n")
