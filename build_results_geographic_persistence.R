#!/usr/bin/env Rscript
# =============================================================================
# Geographic persistence of the located midwifery workforce: rebuild
# =============================================================================
# Reproduces docs/RESULTS_geographic_persistence.md's numbers against the
# CURRENT frozen cohort. That doc was computed once, ad hoc, against the
# 16,892-member cohort (2026-08-14) and never had a checked-in script --
# its own "Reproducing" section gives a manual recipe, not a command. This
# fills that gap: restrict midwife_panel.csv to the current frozen cohort,
# join county via the ZCTA crosswalk, and compute annual/career persistence,
# the RUCC-origin rurality gradient, and the movers table.
#
# SCOPE: this is the doc's "ZCTA crosswalk" method, not its "3-tier cascade +
# TIGER PIP" canonical method. The canonical method requires geocoding every
# DISTINCT historical practice address across all 19 panel years via live
# Census/ArcGIS calls -- the doc's own count was 12,722 addresses, hours of
# network calls last time. That is a separate, heavier follow-up, not done
# here. The doc's own §3 table shows the two methods agree closely (95.9% vs
# 95.9% annual, 67.5% vs 67.3% career on the prior cohort), so this is a
# faithful rebuild of the headline numbers, not a downgrade of them -- but
# the canonical-method cross-check itself is not re-run, and should be
# before treating the rurality gradient as re-validated rather than carried
# forward.
#
# Input : midwife_panel.csv (gitignored, person-level, NPPES annual snapshots)
#         artifacts/amcb_npi_linkage_FROZEN.csv (current cohort_member flag)
#         data/zcta_county_2020.txt (ZCTA -> county, via the canonical
#         zip_county_dominant() in R/lib/zip_county_crosswalk.R -- NOT a
#         hand-rolled group_by/slice_max: that file's own header documents a
#         defect four private copies of this exact logic once shared, where
#         an unfiltered NA ZCTA key silently absorbed every midwife with no
#         practice ZIP into a bogus Yukon-Koyukuk, AK row. Using the
#         canonical function gets assert_no_na_key()'s guard against that
#         for free, rather than relying on today's input happening to be
#         clean.)
#         data/county_base.csv (county FIPS -> RUCC 2023)
# Output: artifacts/geographic_persistence_panel_summary.csv
#         artifacts/geographic_persistence_rates.csv
#         artifacts/geographic_persistence_rurality_origin.csv
#         artifacts/geographic_persistence_movers.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "zip_county_crosswalk.R"))
source(file.path("R", "lib", "geographic_persistence_stats.R"))

LINKAGE <- Sys.getenv("GEO_PERSIST_LINKAGE", "artifacts/amcb_npi_linkage_FROZEN.csv")
PANEL   <- Sys.getenv("GEO_PERSIST_PANEL", "midwife_panel.csv")
ZCTA_RAW <- Sys.getenv("GEO_PERSIST_ZCTA_RAW", "data/zcta_county_2020.txt")
CBASE   <- Sys.getenv("GEO_PERSIST_CBASE", "data/county_base.csv")
OUT_PANEL_SUMMARY <- Sys.getenv("GEO_PERSIST_OUT_PANEL_SUMMARY",
                                "artifacts/geographic_persistence_panel_summary.csv")
OUT_RATES <- Sys.getenv("GEO_PERSIST_OUT_RATES", "artifacts/geographic_persistence_rates.csv")
OUT_RURALITY <- Sys.getenv("GEO_PERSIST_OUT_RURALITY",
                           "artifacts/geographic_persistence_rurality_origin.csv")
OUT_MOVERS <- Sys.getenv("GEO_PERSIST_OUT_MOVERS", "artifacts/geographic_persistence_movers.csv")
stopifnot(file.exists(LINKAGE), file.exists(PANEL), file.exists(ZCTA_RAW), file.exists(CBASE))

linkage <- read_csv(LINKAGE, show_col_types = FALSE, guess_max = Inf)
cohort_npis <- linkage$npi[linkage$cohort_member & !is.na(linkage$npi)]
cat(sprintf("cohort NPIs: %s\n", format(length(cohort_npis), big.mark = ",")))

panel <- read_csv(PANEL, show_col_types = FALSE, guess_max = Inf,
                 col_types = cols(practice_zip = "c", .default = col_guess())) %>%
  filter(npi %in% cohort_npis)

# One row per npi per snapshot_year is already true of this panel (verified:
# 0 npi-year combinations carry more than one row), so no dedup is needed --
# a credential/tax_class split (e.g. "nursing" vs "midwife") happens across
# DIFFERENT years for the same NPI, never within the same year.
stopifnot(!anyDuplicated(panel[, c("npi", "snapshot_year")]))

# ZCTA -> dominant county (largest land-share): the canonical
# zip_county_dominant(), defined once in R/lib/zip_county_crosswalk.R so this
# script cannot become a fifth private copy of its NA-key defect.
zcta <- zip_county_dominant(ZCTA_RAW) %>% rename(zcta5 = zip5, county_fips = GEOID)

cbase <- read_csv(CBASE, show_col_types = FALSE)
rucc_lookup <- build_rucc_lookup(cbase$GEOID, cbase$rucc_2023)

py <- panel %>%
  mutate(practice_zip = substr(trimws(practice_zip), 1, 5)) %>%
  # many-to-one: zip_county_dominant() guarantees exactly one row per zcta5
  # (assert_no_na_key() on its output), many provider-years share a ZIP.
  left_join(zcta, by = c("practice_zip" = "zcta5"), relationship = "many-to-one") %>%
  # many-to-one: build_rucc_lookup() guarantees exactly one row per county
  # FIPS (stops on a conflicting duplicate), many provider-years share a county.
  left_join(rucc_lookup, by = c("county_fips" = "county"), relationship = "many-to-one") %>%
  mutate(rucc_cat = band_rurality(rucc, RURALITY_LABELS_SHORT))

cat(sprintf("provider-years: %s; county resolved: %s (%.1f%%)\n",
            format(nrow(py), big.mark = ","), format(sum(!is.na(py$county_fips)), big.mark = ","),
            100 * mean(!is.na(py$county_fips))))

stats <- compute_geographic_persistence_stats(py)
rates <- stats$rates
rurality <- stats$rurality
movers <- stats$movers
cat("\n-- persistence --\n"); print(as.data.frame(rates))
cat("\n-- rurality, origin-stratified --\n"); print(as.data.frame(rurality))
cat("\n-- movers (origin -> destination, career) --\n"); print(as.data.frame(movers))

# --- Write ---------------------------------------------------------------
panel_summary <- tibble(!!!stats$panel, cohort_n_at_panel_build = length(cohort_npis)) %>%
  select(snapshots, year_min, year_max, cohort_n_at_panel_build, observed, provider_years,
         median_years, pairs_total, pairs_used, providers_used, median_span)
write_with_provenance(panel_summary, OUT_PANEL_SUMMARY, inputs = c(LINKAGE, PANEL))
write_with_provenance(rates, OUT_RATES, inputs = c(LINKAGE, PANEL, ZCTA_RAW))
write_with_provenance(rurality, OUT_RURALITY, inputs = c(LINKAGE, PANEL, ZCTA_RAW, CBASE))
write_with_provenance(movers, OUT_MOVERS, inputs = c(LINKAGE, PANEL, ZCTA_RAW, CBASE))
cat(sprintf("\nwrote 4 artifacts: %s, %s, %s, %s\n",
            OUT_PANEL_SUMMARY, OUT_RATES, OUT_RURALITY, OUT_MOVERS))
