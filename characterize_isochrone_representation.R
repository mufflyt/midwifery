#!/usr/bin/env Rscript
# =============================================================================
# Characterize the isochrone-representation SELECTION MECHANISM
# =============================================================================
# The reuse-coverage gate is a NEGATIVE validation result: the existing
# isochrone library is not transportable to the full ACTIVE midwifery
# workforce. 8,427 of 11,792 usable-coordinate ACTIVE primary-linked midwives
# (71.5%) fall within the 5 km reuse radius of an existing origin, and the
# missingness is strongly geographic (Metro 77.0%, Nonmetro remote 13.9%).
#
# This script describes that missingness. It does NOT correct for it.
#
# WHY NO WEIGHTING: inverse-probability / coverage weighting reweights the
# REPRESENTED midwives to stand in for the unrepresented. That works when the
# missing quantity is an attribute of the person. Here the missing quantity is
# a travel-time POLYGON around a location that has no polygon -- there is
# nothing to reweight toward. When representation is itself spatially
# informative, upweighting the few remote-rural midwives who happen to sit near
# an urban-centered origin projects urban road networks onto rural geography.
# The model below is fit for BIAS CHARACTERIZATION ONLY and its fitted values
# are never used as weights.
#
# The 3,365 unmatched are labelled `not_represented_by_existing_isochrone_library`
# and never `no_access`: they are missing exposure measurement, not zero access.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv
#          midwives_panel_geocoded_enhanced.csv
#          artifacts/midwives_geography_FROZEN.csv   (county)
#          artifacts/midwife_isochrone_match.csv     (reuse gate output)
#          data/rucc_2023.xlsx
# Outputs: artifacts/isochrone_representation_by_rucc.csv
#          artifacts/isochrone_representation_by_state.csv
#          artifacts/isochrone_representation_by_county.csv
#          artifacts/not_represented_by_existing_isochrone_library.csv
#          artifacts/isochrone_representation_model.txt
# =============================================================================
source("R/lib/table1_bands.R")
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(readxl); library(stringr)
})

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
geo  <- read_csv("artifacts/midwives_geography_FROZEN.csv", show_col_types = FALSE)
mat  <- read_csv("artifacts/midwife_isochrone_match.csv", show_col_types = FALSE)

rucc <- read_excel("data/rucc_2023.xlsx") %>%
  transmute(county = str_pad(as.character(FIPS), 5, "left", "0"),
            rucc = as.integer(RUCC_2023)) %>%
  distinct(county, .keep_all = TRUE)

# The gate's denominator, reproduced exactly: ACTIVE + primary_midwifery +
# usable coordinates. Anything else is a different question.
den <- link %>%
  filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
  select(certification_number, nppes_state) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  # county_best, not county_exact: this is a descriptive stratifier, and
  # dropping the ZIP-fallback rows would itself be a rural-selective filter.
  left_join(geo %>% select(certification_number, county_best),
            by = "certification_number") %>%
  mutate(county = str_pad(as.character(county_best), 5, "left", "0")) %>%
  left_join(rucc, by = "county") %>%
  mutate(
    represented = certification_number %in% mat$point_id,
    rurality = band_rurality(rucc, RURALITY_LABELS_SHORT)) %>%
  left_join(mat %>% select(point_id, match_method, match_distance_km),
            by = c("certification_number" = "point_id"))

n <- nrow(den)
cat(sprintf("denominator (ACTIVE, primary_midwifery, usable coords): %s\n",
            format(n, big.mark = ",")))
cat(sprintf("represented by existing isochrone library            : %s (%.1f%%)\n",
            format(sum(den$represented), big.mark = ","),
            100 * mean(den$represented)))
cat(sprintf("NOT represented                                      : %s (%.1f%%)\n\n",
            format(sum(!den$represented), big.mark = ","),
            100 * mean(!den$represented)))

# Rates are computed BEFORE any column is rebound to a name summarise() also
# defines -- a self-referencing summarise() silently reads the new column and
# has produced "100%" and "820400%" in this project already.
rate_by <- function(df, ...) {
  df %>% group_by(...) %>%
    summarise(n_midwives   = n(),
              n_represented = sum(represented),
              pct_represented = round(100 * mean(represented), 1),
              median_km = round(median(match_distance_km, na.rm = TRUE), 3),
              .groups = "drop")
}

cat("=========== REPRESENTATION BY RURALITY ===========\n")
by_rucc <- rate_by(den, rurality) %>% arrange(rurality)
print(as.data.frame(by_rucc))
write_csv(by_rucc, "artifacts/isochrone_representation_by_rucc.csv", na = "")

cat("\n(by individual RUCC code)\n")
print(as.data.frame(rate_by(den, rucc) %>% arrange(rucc)))

cat("\n=========== REPRESENTATION BY STATE (n >= 50) ===========\n")
by_state <- rate_by(den, nppes_state) %>% arrange(pct_represented)
print(as.data.frame(filter(by_state, n_midwives >= 50)), row.names = FALSE)
write_csv(by_state, "artifacts/isochrone_representation_by_state.csv", na = "")

by_county <- rate_by(den, county) %>%
  left_join(rucc, by = "county") %>%
  mutate(n_not_represented = n_midwives - n_represented) %>%
  arrange(desc(n_not_represented))
write_csv(by_county, "artifacts/isochrone_representation_by_county.csv", na = "")
cat(sprintf("\ncounties with >=1 ACTIVE primary-linked midwife : %s\n",
            format(sum(!is.na(by_county$county)), big.mark = ",")))
cat(sprintf("counties with ZERO represented midwives        : %s\n",
            format(sum(by_county$n_represented == 0 & !is.na(by_county$county)),
                   big.mark = ",")))

# --- bias characterization model (NOT a weighting model) --------------------
# Fitted values are printed and discarded. If this were ever used to weight,
# the rural coefficient below is precisely the thing that would be extrapolated
# beyond its support.
fit_df <- den %>% filter(!is.na(rurality), !is.na(nppes_state))
fit <- glm(represented ~ rurality + nppes_state, data = fit_df,
           family = binomial())
co <- summary(fit)$coefficients
rur <- co[grepl("^rurality", rownames(co)), , drop = FALSE]
cat("\n=========== BIAS CHARACTERIZATION (log-odds, NOT weights) ===========\n")
print(round(cbind(rur[, c(1, 2, 4), drop = FALSE],
                  OR = exp(rur[, 1])), 3))
capture.output({
  cat("Isochrone representation ~ rurality + state. Reference: Metro (RUCC 1-3).\n")
  cat("FOR BIAS CHARACTERIZATION ONLY. Fitted values must not be used as\n")
  cat("inverse-probability weights: no reweighting of represented midwives can\n")
  cat("reconstruct the missing travel-time polygons of the unrepresented.\n\n")
  print(summary(fit))
}, file = "artifacts/isochrone_representation_model.txt")

# --- the unrepresented ------------------------------------------------------
not_rep <- den %>%
  filter(!represented) %>%
  transmute(certification_number, nppes_state, county, rucc, rurality,
            representation_status = "not_represented_by_existing_isochrone_library")
write_csv(not_rep, "artifacts/not_represented_by_existing_isochrone_library.csv",
          na = "")
cat(sprintf("\nwritten: artifacts/not_represented_by_existing_isochrone_library.csv (%s rows)\n",
            format(nrow(not_rep), big.mark = ",")))
cat("  status label is 'not_represented_by_existing_isochrone_library'.\n")
cat("  It is NOT 'no_access'. These are midwives with unmeasured exposure.\n")
