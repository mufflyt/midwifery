#!/usr/bin/env Rscript
# =============================================================================
# Final recovery accounting, AFTER polygon validation
# =============================================================================
# An origin is usable if it passes the full gate in AT LEAST ONE source
# artifact. Passing in one archive and failing in another is not a
# contradiction: the archives are successive generations of the same runs, and
# a later file may hold all four bands where an earlier one holds two. The
# validated polygon is taken from the source where it passed, which is recorded
# per origin.
#
# The 5 km re-match is redone against the VALIDATED origin set only, so the
# final coverage number is not inflated by origins that were rescued on
# proximity and then failed geometry.
#
# The canonical 3,909-origin library is not modified. No routing, no generation.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(purrr); library(stringr); library(readxl)
})
ISO <- path.expand("~/isochrones")

val <- list.files("artifacts/iso_recovery", pattern = "^val_", full.names = TRUE) %>%
  map_dfr(readRDS)
stopifnot(nrow(val) > 0)

cat("=========== VALIDATION BY SOURCE ===========\n")
print(as.data.frame(val %>% group_by(source_group) %>%
  summarise(origins = n(), all_4_bands = sum(all_4_bands), geom_ok = sum(geom_ok),
            nesting_ok = sum(nesting_ok), centre_in_30 = sum(centre_in_30),
            passes = sum(passes), .groups = "drop") %>%
  arrange(desc(passes))), row.names = FALSE)

cat("\n=========== WHY ORIGINS FAIL (union across sources) ===========\n")
best <- val %>% arrange(desc(passes), desc(all_4_bands)) %>%
  distinct(location_key, .keep_all = TRUE)
cat(sprintf("distinct rescuing origins examined : %s\n", nrow(best)))
# Anything that rescued a midwife but has no validation record is reported, not
# dropped silently -- an unexamined origin is a gap in the audit, not a pass.
all_keys <- read_csv("artifacts/iso_recovery/rescuing_origin_keys.csv",
                     show_col_types = FALSE)$location_key
unexamined <- setdiff(all_keys, best$location_key)
if (length(unexamined)) {
  cat(sprintf("NOT examined (treated as failing)  : %s\n", length(unexamined)))
  cat("  These come only from s3:supplemental_isochrones, which has 30/60/120\n")
  cat("  objects and NO 180-minute object in S3 at all -- so they could not\n")
  cat("  satisfy the four-band requirement even if validated.\n")
}
fails <- best %>% filter(!passes) %>%
  summarise(`missing a band` = sum(!all_4_bands),
            `invalid geometry` = sum(!geom_ok),
            `nesting violated` = sum(!nesting_ok),
            `centre outside own 30-min` = sum(!centre_in_30),
            `test artifact` = sum(test_artifact))
print(as.data.frame(t(fails)))
cat(sprintf("\norigins PASSING all checks          : %s of %s (%.1f%%)\n",
            sum(best$passes), nrow(best), 100 * mean(best$passes)))
cat("(reasons overlap; an origin can fail several checks at once)\n")

validated <- best %>% filter(passes)
write_csv(validated, "artifacts/historical_isochrone_recovery_validated.csv", na = "")

# --- re-match against VALIDATED origins only --------------------------------
cat_all <- read_csv("artifacts/historical_isochrone_recovery_catalog.csv",
                    show_col_types = FALSE)
o <- cat_all %>% filter(location_key %in% validated$location_key) %>%
  distinct(location_key, .keep_all = TRUE) %>%
  transmute(id = location_key, lat = center_lat, lon = center_lng)
cat(sprintf("\nvalidated origins available for matching: %s\n", nrow(o)))

crd <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
un <- read_csv("artifacts/not_represented_by_existing_isochrone_library.csv",
               show_col_types = FALSE) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude))

matcher <- local({
  owd <- setwd(ISO); on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages(
    source(file.path("R", "match_points_to_isochrones.R"))))
  match_points_to_isochrones
})
m <- suppressWarnings(suppressMessages(matcher(
  points_tbl = un %>% transmute(point_id = certification_number,
                                lat = latitude, lon = longitude),
  iso_centers_tbl = o, threshold_km = 5.0, point_id_col = "point_id",
  verbose = FALSE)))

un <- un %>% mutate(rescued = certification_number %in% m$point_id)
cat(sprintf("\nunrepresented midwives              : %s\n", nrow(un)))
cat(sprintf("rescued by VALIDATED archive origins: %s (%.1f%%)\n",
            format(sum(un$rescued), big.mark = ","), 100 * mean(un$rescued)))
cat(sprintf("still with no usable polygon        : %s (%.1f%%)\n",
            format(sum(!un$rescued), big.mark = ","), 100 * mean(!un$rescued)))

by_r <- un %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(unrepresented = n(), rescued_n = sum(rescued),
            pct_rescued = round(100 * mean(rescued), 1), .groups = "drop")

canon <- read_csv("artifacts/isochrone_representation_by_rucc.csv",
                  show_col_types = FALSE)
combined <- canon %>% select(rurality, n_midwives, canonical = n_represented) %>%
  left_join(by_r %>% select(rurality, recovered = rescued_n), by = "rurality") %>%
  mutate(recovered = coalesce(recovered, 0L),
         covered = canonical + recovered,
         pct_canonical_only = round(100 * canonical / n_midwives, 1),
         pct_with_validated_recovery = round(100 * covered / n_midwives, 1))
cat("\n=========== COVERAGE AFTER VALIDATED RECOVERY ===========\n")
print(as.data.frame(combined %>% filter(!is.na(rurality))), row.names = FALSE)
cat(sprintf("national: %.1f%% -> %.1f%%\n",
            100 * sum(combined$canonical) / sum(combined$n_midwives),
            100 * sum(combined$covered) / sum(combined$n_midwives)))

write_csv(combined, "artifacts/isochrone_coverage_after_validated_recovery.csv", na = "")
write_csv(by_r, "artifacts/historical_isochrone_recovery_by_rucc.csv", na = "")
write_csv(m, "artifacts/historical_isochrone_recovery_matches_validated.csv", na = "")
cat("\nCanonical library unchanged. Recovered origins remain a separate artifact.\n")
