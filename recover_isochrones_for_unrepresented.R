#!/usr/bin/env Rscript
# =============================================================================
# Existing-isochrone RECOVERY search for the 3,365 unrepresented midwives
# =============================================================================
# NOTHING IS ROUTED. NOTHING IS GENERATED. No Valhalla process is started, no
# polygon is interpolated, and the canonical 3,909-origin library is not
# modified. This asks one question: do we ALREADY possess a drive-time polygon
# centred within 5 km of a midwife who is unrepresented in the canonical set?
#
# WHY PREVIOUSLY-REJECTED ARTIFACTS ARE IN SCOPE. Files like
# provider_isochrones_25K.rds were rejected for the temporal/subspecialty
# physician analysis because they lack complete temporal and subspecialty
# dimensions. Those dimensions are irrelevant here: an isochrone is a polygon
# around a POINT, and for a 2023 midwife access question the only things that
# matter are that the centre is near a midwife and that the polygon is sound.
# Rejected-for-that-purpose is not rejected-for-this-purpose.
#
# ONE EXCEPTION THAT IS NOT RELAXED. provider_isochrones.rds is the file whose
# use as the CANONICAL basis inflated an uncovered count 164 -> 445
# (CLAUDE.md #19). That warning means "never substitute it for the production
# library", which this script does not do: its origins enter a SEPARATE
# recovery catalog, tagged with their source, and are never written back into
# artifacts/isochrones/. The canonical set stays exactly 3,909.
#
# Matching uses the project's own haversine matcher at the same 5.0 km reuse
# radius as the canonical gate, so recovery is measured on identical terms.
#
# Inputs : artifacts/iso_recovery/*.rds   (origin catalogs, one per artifact)
#          artifacts/not_represented_by_existing_isochrone_library.csv
#          midwives_panel_geocoded_enhanced.csv
#          data/rucc_2023.xlsx
# Outputs: artifacts/historical_isochrone_recovery_catalog.csv   (origins)
#          artifacts/historical_isochrone_recovery_waterfall.csv
#          artifacts/historical_isochrone_recovery_matches.csv   (gitignored)
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(readxl); library(purrr)
})

ISO <- path.expand("~/isochrones")

# --- 1. Assemble the archive-origin catalog ---------------------------------
files <- list.files("artifacts/iso_recovery", full.names = TRUE, pattern = "\\.rds$")
cat <- map_dfr(files, function(f) {
  x <- readRDS(f)
  if (!nrow(x)) return(NULL)
  x
})
stopifnot(nrow(cat) > 0)

# A "source group" is the artifact SET, not the individual band file: the
# consolidated releases store one band per file, so band completeness can only
# be judged after regrouping them.
cat <- cat %>%
  mutate(source_group = str_remove(source, "[_/]\\d+min$"),
         tier = case_when(
           str_starts(source, "s3:")     ~ "1_s3_historical",
           str_starts(source, "ec2:")    ~ "2_ec2",
           str_starts(source, "extdrive:") ~ "3_external_drive",
           str_starts(source, "dropbox:") ~ "4_dropbox",
           TRUE                          ~ "5_local_derived"))

# Band completeness per (artifact set, origin). Recovery is only useful for the
# bands that actually exist -- a 30/60/120-only origin cannot answer the 180.
bands <- cat %>%
  filter(!is.na(band)) %>%
  distinct(source_group, location_key, band) %>%
  group_by(source_group, location_key) %>%
  summarise(bands_present = paste(sort(unique(band)), collapse = "/"),
            n_bands = n_distinct(band), .groups = "drop") %>%
  mutate(all_four_bands = n_bands == 4L)

origins <- cat %>%
  distinct(source_group, tier, location_key, center_lat, center_lng) %>%
  left_join(bands, by = c("source_group", "location_key"))

cat_n <- origins %>% count(tier, source_group, name = "origins") %>%
  left_join(origins %>% filter(all_four_bands) %>%
              count(tier, source_group, name = "origins_all_4_bands"),
            by = c("tier", "source_group")) %>%
  mutate(origins_all_4_bands = coalesce(origins_all_4_bands, 0L)) %>%
  arrange(tier, desc(origins))
cat("=========== ARCHIVE ORIGIN CATALOG ===========\n")
print(as.data.frame(cat_n), row.names = FALSE)

# --- 2. How much of this is genuinely NEW geography? ------------------------
canon <- local({
  owd <- setwd(ISO); on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages(
    source(file.path("R", "load_canonical_isochrone_origins.R"))))
  load_canonical_isochrone_origins()
})
canon_key <- sprintf("%.6f_%.6f", canon$lat, canon$lon)
uniq <- origins %>% distinct(location_key, center_lat, center_lng, .keep_all = TRUE)
cat(sprintf("\ncanonical origins                       : %s\n",
            format(nrow(canon), big.mark = ",")))
cat(sprintf("distinct archive origins (all sources)  : %s\n",
            format(nrow(uniq), big.mark = ",")))
cat(sprintf("  of which NOT in the canonical set     : %s\n",
            format(sum(!uniq$location_key %in% canon_key), big.mark = ",")))

# --- 3. The unrepresented midwives ------------------------------------------
crd <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
un <- read_csv("artifacts/not_represented_by_existing_isochrone_library.csv",
               show_col_types = FALSE) %>%
  left_join(crd %>% select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude))
cat(sprintf("\nunrepresented midwives to rescue        : %s\n",
            format(nrow(un), big.mark = ",")))

matcher <- local({
  owd <- setwd(ISO); on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages(
    source(file.path("R", "match_points_to_isochrones.R"))))
  match_points_to_isochrones
})

# --- 4. Waterfall: tiers applied in order, each only to the still-unrescued --
pts <- un %>% transmute(point_id = certification_number,
                        lat = latitude, lon = longitude)
rescued <- tibble(point_id = character())
rows <- list()
# All four tiers are named explicitly, including any that yielded no artifact,
# so an absent source reads as "searched, found nothing" rather than vanishing
# from the waterfall entirely.
ALL_TIERS <- c("1_s3_historical", "2_ec2", "3_external_drive", "4_dropbox",
               "5_local_derived")
for (tr in ALL_TIERS) {
  if (!any(origins$tier == tr)) {
    rows[[tr]] <- tibble(tier = tr, newly_rescued = 0L,
                         still_unrescued = nrow(pts) - nrow(rescued))
    cat(sprintf("  %-18s no artifact found at this source\n", tr))
    next
  }
  remaining <- pts %>% filter(!point_id %in% rescued$point_id)
  if (!nrow(remaining)) { rows[[tr]] <- tibble(tier = tr, newly_rescued = 0L,
                                               still_unrescued = 0L); next }
  o <- origins %>% filter(tier == tr) %>%
    distinct(location_key, .keep_all = TRUE) %>%
    transmute(id = location_key, lat = center_lat, lon = center_lng)
  m <- suppressWarnings(suppressMessages(
    matcher(points_tbl = remaining, iso_centers_tbl = o, threshold_km = 5.0,
            point_id_col = "point_id", verbose = FALSE)))
  m$tier <- tr
  rescued <- bind_rows(rescued, m)
  rows[[tr]] <- tibble(tier = tr, newly_rescued = nrow(m),
                       still_unrescued = nrow(pts) - nrow(rescued))
  cat(sprintf("  %-18s newly rescued %6s   still unrescued %6s\n", tr,
              format(nrow(m), big.mark = ","),
              format(nrow(pts) - nrow(rescued), big.mark = ",")))
}
wf <- bind_rows(rows)

cat("\n=========== RECOVERY WATERFALL ===========\n")
cat(sprintf("unrepresented by canonical library : %s\n",
            format(nrow(pts), big.mark = ",")))
print(as.data.frame(wf), row.names = FALSE)
cat(sprintf("TOTAL rescued from existing archives: %s (%.1f%%)\n",
            format(nrow(rescued), big.mark = ","),
            100 * nrow(rescued) / nrow(pts)))
cat(sprintf("STILL no existing polygon anywhere  : %s (%.1f%%)\n",
            format(nrow(pts) - nrow(rescued), big.mark = ","),
            100 * (nrow(pts) - nrow(rescued)) / nrow(pts)))

if (nrow(rescued)) {
  d <- rescued$match_distance_km
  cat(sprintf("\nclosest-match distance (km): median %.3f  mean %.3f\n",
              median(d), mean(d)))
  cat(sprintf("  0 km %.1f%% | <=0.5 km %.1f%% | <=2 km %.1f%% | 4-5 km %.1f%%\n",
              100*mean(d == 0), 100*mean(d <= 0.5), 100*mean(d <= 2),
              100*mean(d > 4)))
  print(as.data.frame(count(rescued, match_method, sort = TRUE)))
}

# --- 5. Does recovery close the RURAL gap, which is the whole point? --------
rucc <- read_excel("data/rucc_2023.xlsx") %>%
  transmute(county = str_pad(as.character(FIPS), 5, "left", "0"),
            rucc = as.integer(RUCC_2023)) %>% distinct(county, .keep_all = TRUE)
un2 <- un %>% mutate(rescued = certification_number %in% rescued$point_id)
by_r <- un2 %>% filter(!is.na(rurality)) %>% group_by(rurality) %>%
  summarise(unrepresented = n(), rescued_n = sum(rescued),
            pct_rescued = round(100 * mean(rescued), 1), .groups = "drop")
cat("\n=========== RECOVERY BY RURALITY (of the unrepresented) ===========\n")
print(as.data.frame(by_r), row.names = FALSE)

# Combined coverage: canonical + recovered, against the SAME 11,792-midwife
# denominator as the original gate, so the two are directly comparable.
canon_rep <- read_csv("artifacts/isochrone_representation_by_rucc.csv",
                      show_col_types = FALSE)
combined <- canon_rep %>%
  select(rurality, n_midwives, canonical = n_represented) %>%
  left_join(by_r %>% select(rurality, recovered = rescued_n), by = "rurality") %>%
  mutate(recovered = coalesce(recovered, 0L),
         covered = canonical + recovered,
         pct_canonical_only = round(100 * canonical / n_midwives, 1),
         pct_with_recovery  = round(100 * covered / n_midwives, 1))
cat("\n=========== COVERAGE: CANONICAL vs CANONICAL + RECOVERED ===========\n")
cat("(polygon validation has NOT run; these are candidate origins)\n")
print(as.data.frame(combined %>% filter(!is.na(rurality))), row.names = FALSE)
cat(sprintf("national: %.1f%% -> %.1f%%\n",
            100 * sum(combined$canonical) / sum(combined$n_midwives),
            100 * sum(combined$covered) / sum(combined$n_midwives)))
write_csv(combined, "artifacts/isochrone_coverage_with_recovery.csv", na = "")

write_csv(origins, "artifacts/historical_isochrone_recovery_catalog.csv", na = "")
write_csv(wf, "artifacts/historical_isochrone_recovery_waterfall.csv", na = "")
write_csv(by_r, "artifacts/historical_isochrone_recovery_by_rucc.csv", na = "")
write_csv(rescued, "artifacts/historical_isochrone_recovery_matches.csv", na = "")
cat("\nRecovered origins are a SEPARATE artifact. The canonical 3,909-origin\n")
cat("library is unchanged, and no recovered polygon has been merged into it.\n")
cat("Polygon-level validation is a separate gate and has NOT run yet.\n")
