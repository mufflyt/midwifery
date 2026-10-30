#!/usr/bin/env Rscript
# =============================================================================
# Geographic persistence, canonical method: 3-tier cascade + TIGER PIP
# =============================================================================
# The companion to build_results_geographic_persistence.R, which uses the
# faster ZCTA-crosswalk county method. This one uses the method
# docs/RESULTS_geographic_persistence.md's "Three methods" section calls
# canonical: every DISTINCT historical practice address across the full
# panel, geocoded live via geocode_queue_cascade.R's Census -> ArcGIS -> TIGER
# point-in-polygon cascade, then fanned out to every provider-year sharing
# that address. Both scripts share one computation core
# (R/lib/geographic_persistence_stats.R) so only the county SOURCE differs
# between them.
#
# This script does NOT run the cascade itself -- that is a separate, heavy,
# live-network-call step (hours for ~15,000 addresses), done once via:
#
#   Rscript -e 'write.csv(...)'  # build the distinct-address queue (see below)
#   GEOCODE_QUEUE=... GEOCODE_OUT=... Rscript geocode_queue_cascade.R
#
# This script only consumes that output, joins it back onto the full
# historical panel, and computes the same stats the ZCTA-crosswalk method
# does, for comparison.
#
# Input : midwife_panel.csv (gitignored, person-level, NPPES annual snapshots)
#         artifacts/amcb_npi_linkage_FROZEN.csv (current cohort_member flag)
#         artifacts/panel_geocode_results_full_history.csv (geocode_queue_
#         cascade.R's output against every distinct historical address for
#         the current cohort -- county_geoid_5char already resolved via its
#         own internal enrich_with_census_tracts() call)
#         data/county_base.csv (county FIPS -> RUCC 2023)
# Output: artifacts/geographic_persistence_canonical_panel_summary.csv
#         artifacts/geographic_persistence_canonical_rates.csv
#         artifacts/geographic_persistence_canonical_rurality_origin.csv
#         artifacts/geographic_persistence_canonical_movers.csv
#         artifacts/geographic_persistence_method_comparison.csv
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})
source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "table1_bands.R"))
source(file.path("R", "lib", "geographic_persistence_stats.R"))

LINKAGE <- Sys.getenv("GEO_PERSIST_LINKAGE", "artifacts/amcb_npi_linkage_FROZEN.csv")
PANEL   <- Sys.getenv("GEO_PERSIST_PANEL", "midwife_panel.csv")
GEOCODE_RESULTS <- Sys.getenv("GEO_PERSIST_CANONICAL_GEOCODE",
                              "artifacts/panel_geocode_results_full_history.csv")
CBASE   <- Sys.getenv("GEO_PERSIST_CBASE", "data/county_base.csv")
ZCTA_RATES <- Sys.getenv("GEO_PERSIST_ZCTA_RATES", "artifacts/geographic_persistence_rates.csv")
OUT_PANEL_SUMMARY <- Sys.getenv("GEO_PERSIST_CANONICAL_OUT_PANEL_SUMMARY",
                                "artifacts/geographic_persistence_canonical_panel_summary.csv")
OUT_RATES <- Sys.getenv("GEO_PERSIST_CANONICAL_OUT_RATES",
                        "artifacts/geographic_persistence_canonical_rates.csv")
OUT_RURALITY <- Sys.getenv("GEO_PERSIST_CANONICAL_OUT_RURALITY",
                           "artifacts/geographic_persistence_canonical_rurality_origin.csv")
OUT_MOVERS <- Sys.getenv("GEO_PERSIST_CANONICAL_OUT_MOVERS",
                         "artifacts/geographic_persistence_canonical_movers.csv")
OUT_COMPARISON <- Sys.getenv("GEO_PERSIST_OUT_COMPARISON",
                            "artifacts/geographic_persistence_method_comparison.csv")
stopifnot(file.exists(LINKAGE), file.exists(PANEL), file.exists(GEOCODE_RESULTS), file.exists(CBASE))

linkage <- read_csv(LINKAGE, show_col_types = FALSE, guess_max = Inf)
cohort_npis <- linkage$npi[linkage$cohort_member & !is.na(linkage$npi)]
cat(sprintf("cohort NPIs: %s\n", format(length(cohort_npis), big.mark = ",")))

panel <- read_csv(PANEL, show_col_types = FALSE, guess_max = Inf,
                 col_types = cols(practice_zip = "c", .default = col_guess())) %>%
  filter(npi %in% cohort_npis)
stopifnot(!anyDuplicated(panel[, c("npi", "snapshot_year")]))

# Fan the per-DISTINCT-ADDRESS geocode result out across every provider-year
# sharing that exact address -- the same address geocoded once covers every
# year a provider didn't move. Join key matches geocode_queue_cascade.R's own
# input column names exactly (built from these same four panel columns,
# unmodified, when the queue was constructed).
geocoded <- read_csv(GEOCODE_RESULTS, show_col_types = FALSE,
                     col_types = cols(county_geoid_5char = "c", .default = "c")) %>%
  select(geocode_address_1, geocode_city, geocode_state, geocode_zip, county_geoid_5char)

cbase <- read_csv(CBASE, show_col_types = FALSE)
rucc_lookup <- build_rucc_lookup(cbase$GEOID, cbase$rucc_2023)

py <- panel %>%
  left_join(geocoded, by = c("practice_address" = "geocode_address_1",
                             "practice_city" = "geocode_city",
                             "practice_state" = "geocode_state",
                             "practice_zip" = "geocode_zip")) %>%
  rename(county_fips = county_geoid_5char) %>%
  left_join(rucc_lookup, by = c("county_fips" = "county")) %>%
  mutate(rucc_cat = band_rurality(rucc, RURALITY_LABELS_SHORT))

cat(sprintf("provider-years: %s; county resolved: %s (%.1f%%)\n",
            format(nrow(py), big.mark = ","), format(sum(!is.na(py$county_fips)), big.mark = ","),
            100 * mean(!is.na(py$county_fips))))

stats <- compute_geographic_persistence_stats(py)
rates <- stats$rates
rurality <- stats$rurality
movers <- stats$movers
cat("\n-- persistence (canonical method) --\n"); print(as.data.frame(rates))
cat("\n-- rurality, origin-stratified (canonical method) --\n"); print(as.data.frame(rurality))
cat("\n-- movers (origin -> destination, career, canonical method) --\n"); print(as.data.frame(movers))

panel_summary <- tibble(!!!stats$panel, cohort_n_at_panel_build = length(cohort_npis)) %>%
  select(snapshots, year_min, year_max, cohort_n_at_panel_build, observed, provider_years,
         median_years, pairs_total, pairs_used, providers_used, median_span)

write_with_provenance(panel_summary, OUT_PANEL_SUMMARY, inputs = c(LINKAGE, PANEL, GEOCODE_RESULTS))
write_with_provenance(rates, OUT_RATES, inputs = c(LINKAGE, PANEL, GEOCODE_RESULTS))
write_with_provenance(rurality, OUT_RURALITY, inputs = c(LINKAGE, PANEL, GEOCODE_RESULTS, CBASE))
write_with_provenance(movers, OUT_MOVERS, inputs = c(LINKAGE, PANEL, GEOCODE_RESULTS, CBASE))

# --- Method comparison: canonical vs. ZCTA crosswalk ------------------------
if (file.exists(ZCTA_RATES)) {
  zcta_rates <- read_csv(ZCTA_RATES, show_col_types = FALSE)
  comparison <- bind_rows(
    zcta_rates %>% mutate(method = "zcta_crosswalk"),
    rates %>% mutate(method = "canonical_cascade")
  ) %>% select(method, horizon, n, same_county_pct, same_zip_pct, same_state_pct)
  cat("\n-- method comparison --\n"); print(as.data.frame(comparison))
  write_with_provenance(comparison, OUT_COMPARISON, inputs = c(ZCTA_RATES, OUT_RATES))
} else {
  cat(sprintf("\n[skip] %s not found -- run build_results_geographic_persistence.R first for a comparison\n", ZCTA_RATES))
}

cat(sprintf("\nwrote: %s, %s, %s, %s%s\n", OUT_PANEL_SUMMARY, OUT_RATES, OUT_RURALITY, OUT_MOVERS,
            if (file.exists(ZCTA_RATES)) sprintf(", %s", OUT_COMPARISON) else ""))
