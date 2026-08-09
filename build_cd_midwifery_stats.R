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
# PROVIDER UNIVERSES (see load_obstetric_providers.R for the full rationale):
#   * GENERALIST general OB/GYNs -- the clinically correct comparator for
#     midwives, since both attend routine births. Geocoded coverage is 56.4% of
#     ABOG generalists, so these counts are a FLOOR and district generalist
#     rates are downward-biased by a non-uniform amount.
#   * MFM as the referral tier above both.
#   * AMCB-certified ACTIVE primary-linked midwives.
# Non-intrapartum subspecialties (REI/GO/FPMRS/MIGS/CFP/PAG) are deliberately
# NOT summed with midwives: that comparison was wrong and has been withdrawn.
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

source("load_obstetric_providers.R")
gen <- load_generalists()
mfm <- load_subspecialists("MFM")
mw  <- load_midwives()

assign_cd <- function(df, label) {
  p <- sf::st_as_sf(df, coords = c("longitude", "latitude"), crs = 4326)
  j <- suppressMessages(sf::st_join(p, cd, join = sf::st_within))
  cat(sprintf("%-9s placed %s, outside any district %s\n",
              label, sum(!is.na(j$cd_id)), sum(is.na(j$cd_id))))
  sf::st_drop_geometry(j) %>% filter(!is.na(cd_id))
}

# Provenance must survive to the published artifact: a district whose generalist
# count rests largely on city centroids is weaker evidence than one built from
# street-level geocodes, and a reader cannot tell without this column.
centroid_counts <- function(cd_tbl) {
  if (!"coord_source" %in% names(cd_tbl)) return(NULL)
  cd_tbl %>% filter(grepl("centroid", coord_source)) %>%
    count(cd_id, name = "n_general_obgyn_city_centroid")
}
gen_cd <- assign_cd(gen, "generalOB")
mfm_cd <- assign_cd(mfm, "MFM")
mw_cd  <- assign_cd(mw,  "midwife")

# --- 3. join and rate --------------------------------------------------------
d <- sf::st_drop_geometry(cd) %>%
  left_join(acs %>% select(STATEFP, CD118FP, population, women_15_50,
                           acs_births, median_hh_income),
            by = c("STATEFP", "CD118FP")) %>%
  left_join(gen_cd %>% count(cd_id, name = "n_general_obgyn"), by = "cd_id") %>%
  left_join(mfm_cd %>% count(cd_id, name = "n_mfm"),           by = "cd_id") %>%
  left_join(centroid_counts(gen_cd), by = "cd_id") %>%
  left_join(mw_cd  %>% count(cd_id, name = "n_midwife"),       by = "cd_id") %>%
  mutate(across(c(n_general_obgyn, n_mfm, n_midwife, n_general_obgyn_city_centroid), ~ coalesce(., 0L)),
         # Generalists + midwives only. MFM is the referral tier and is counted
         # separately, not added in.
         birth_attendants = n_general_obgyn + n_midwife,
         rate_ok = !is.na(acs_births) & acs_births >= MIN_BIRTHS,
         midwives_per_1k_births =
           if_else(rate_ok, round(1000 * n_midwife / acs_births, 2), NA_real_),
         general_obgyn_per_1k_births =
           if_else(rate_ok, round(1000 * n_general_obgyn / acs_births, 2), NA_real_),
         mfm_per_1k_births =
           if_else(rate_ok, round(1000 * n_mfm / acs_births, 2), NA_real_),
         attendants_per_1k_births =
           if_else(rate_ok, round(1000 * birth_attendants / acs_births, 2), NA_real_),
         midwives_per_100k_pop =
           mufflyaccess::safe_rate(n_midwife, population,
                                   multiplier = 1e5, digits = 2),
         # Share of the ROUTINE birth-attending workforce that is midwives.
         midwife_share_of_attendants =
           if_else(birth_attendants > 0,
                   round(n_midwife / birth_attendants, 3), NA_real_),
         midwives_per_general_obgyn =
           if_else(n_general_obgyn > 0,
                   round(n_midwife / n_general_obgyn, 2), NA_real_))

cat(sprintf("districts with ACS matched: %s of %s\n",
            sum(!is.na(d$population)), nrow(d)))
cat(sprintf("rates suppressed (<%s births): %s\n", MIN_BIRTHS, sum(!d$rate_ok)))

cat("\n=========== NATIONAL (118th districts) ===========\n")
cat(sprintf("midwives            : %s\n", format(sum(d$n_midwife), big.mark = ",")))
cat(sprintf("general OB/GYNs     : %s (%.1f%% of ABOG generalist roster)\n", format(sum(d$n_general_obgyn), big.mark = ","), 100 * sum(d$n_general_obgyn) / 50556));
cat(sprintf("MFM                 : %s\n", format(sum(d$n_mfm), big.mark = ",")))
cat(sprintf("ACS births (12 mo)  : %s\n", format(sum(d$acs_births, na.rm = TRUE), big.mark = ",")))
cat(sprintf("midwives per 1k births (pooled): %.2f\n",
            1000 * sum(d$n_midwife) / sum(d$acs_births, na.rm = TRUE)))

cat("\n=========== LOWEST 15 DISTRICTS: midwives per 1,000 births ===========\n")
print(as.data.frame(d %>% filter(rate_ok) %>%
  arrange(midwives_per_1k_births, cd_id) %>%
  select(cd_id, n_midwife, n_general_obgyn, n_mfm, acs_births,
         midwives_per_1k_births, general_obgyn_per_1k_births) %>% head(15)),
  row.names = FALSE)

cat("\n=========== HIGHEST 15 DISTRICTS: midwives per 1,000 births ===========\n")
print(as.data.frame(d %>% filter(rate_ok) %>%
  arrange(desc(midwives_per_1k_births)) %>%
  select(cd_id, n_midwife, n_general_obgyn, n_mfm, acs_births,
         midwives_per_1k_births, midwife_share_of_attendants) %>% head(15)),
  row.names = FALSE)

cat("\n=========== DISTRIBUTION ===========\n")
qs <- quantile(d$midwives_per_1k_births, c(0, .1, .25, .5, .75, .9, 1), na.rm = TRUE)
print(round(qs, 2))
cat(sprintf("ratio p90/p10       : %.1fx\n", qs[["90%"]] / max(qs[["10%"]], 0.01)))

cat("\n=========== BY STATE (10 largest delegations) ===========\n")
print(as.data.frame(d %>% group_by(state) %>%
  summarise(districts = n(), midwives = sum(n_midwife),
            general_ob = sum(n_general_obgyn),
            births = sum(acs_births, na.rm = TRUE),
            midwives_per_1k_births = round(1000 * sum(n_midwife) /
                                             sum(acs_births, na.rm = TRUE), 2),
            .groups = "drop") %>%
  arrange(desc(districts)) %>% head(10)), row.names = FALSE)

write_csv(d, "artifacts/cd_midwifery_stats.csv", na = "")
cat("\nwritten: artifacts/cd_midwifery_stats.csv\n")
cat("118th Congress boundaries. Counts on 119th lines are in cd_obstetric_workforce.csv;\n")
cat("the two are NOT interchangeable and must not be joined.\n")
