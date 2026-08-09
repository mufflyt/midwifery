#!/usr/bin/env Rscript
# =============================================================================
# Engine calibration: osm.de public Valhalla vs EC2 Valhalla, same origins
# =============================================================================
# Run as: Rscript calibrate_osmde_vs_ec2.R [n_per_stratum]
#
# WHY THIS EXISTS. The new 30/60-minute polygons come from a different routing
# engine than the canonical library, and the split is not random: the newly
# routed locations are the ones canonical coverage missed, which is a
# rural-selective set. So "engine" and "rurality" are confounded by
# construction, and any engine difference will imitate a rural access effect.
#
# This measures that difference instead of caveating it. A sample of origins the
# EC2 library ALREADY covers is re-routed on osm.de, so the same point has two
# polygons whose only difference is the engine. Agreement is reported per
# rurality stratum, because the quantity that matters is not "do the engines
# differ on average" but "do they differ MORE in rural areas" -- a uniform
# offset is a nuisance, a rural-varying offset is a threat to the finding.
#
# Origins are stratified via the midwives they cover (artifacts/
# midwife_isochrone_match.csv joined to the rurality already computed for the
# representation analysis), so no county shapefile is needed.
#
# Metrics per origin x band:
#   area_ratio = area(osmde) / area(ec2)      1.0 = identical size
#   iou        = intersection / union         1.0 = identical shape AND position
# IoU is the honest one: two polygons can share an area to the square kilometre
# and still cover different places.
#
# Read-only against the canonical library. Nothing is written to
# artifacts/isochrones/.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(httr); library(purrr)
})
sf::sf_use_s2(FALSE)
set.seed(20260808)   # fixed: the same sample must be reproducible for the paper

BANDS   <- c(30, 60)
SERVER  <- "https://valhalla1.openstreetmap.de"
SLEEP_S <- 3.0
OUTDIR  <- "artifacts/isochrones_osmde"
N_PER   <- { a <- commandArgs(trailingOnly = TRUE)
             if (length(a)) as.integer(a[1]) else 35L }
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)

# --- 1. stratified sample of ALREADY-COVERED origins -------------------------
mat <- read_csv("artifacts/midwife_isochrone_match.csv", show_col_types = FALSE)
rep_rur <- read_csv("artifacts/isochrone_representation_by_county.csv",
                    show_col_types = FALSE)

# The matcher stores the MATCHED ORIGIN's coordinates, so distinct pairs are
# origins; each inherits the rurality of the midwives it covers. Where an origin
# covers a mix, the modal stratum is used -- this is a sampling frame, not an
# estimate, so ties do not need resolving carefully.
crd <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
un  <- read_csv("artifacts/not_represented_by_existing_isochrone_library.csv",
                show_col_types = FALSE)
rur_lookup <- bind_rows(
  un %>% select(certification_number, rurality),
  read_csv("artifacts/isochrone_representation_by_rucc.csv", show_col_types = FALSE) %>%
    slice(0) %>% transmute(certification_number = character(), rurality = character())
)

frame <- mat %>%
  transmute(certification_number = point_id,
            location_key = sprintf("%.6f_%.6f", latitude, longitude),
            center_lat = latitude, center_lng = longitude) %>%
  left_join(rur_lookup, by = "certification_number")

# Represented midwives are absent from the unrepresented file by definition, so
# their rurality is recovered from the county-level representation table via the
# geography artifact rather than left NA.
if (all(is.na(frame$rurality))) {
  geo <- read_csv("artifacts/midwives_geography_FROZEN.csv", show_col_types = FALSE)
  rucc <- readxl::read_excel("data/rucc_2023.xlsx") %>%
    transmute(county = stringr::str_pad(as.character(FIPS), 5, "left", "0"),
              rucc = as.integer(RUCC_2023)) %>% distinct(county, .keep_all = TRUE)
  frame <- frame %>%
    left_join(geo %>% select(certification_number, county_best), by = "certification_number") %>%
    mutate(county = stringr::str_pad(as.character(county_best), 5, "left", "0")) %>%
    left_join(rucc, by = "county") %>%
    mutate(rurality = case_when(is.na(rucc) ~ NA_character_,
                                rucc <= 3 ~ "Metro (RUCC 1-3)",
                                rucc <= 6 ~ "Nonmetro, adjacent (RUCC 4-6)",
                                TRUE      ~ "Nonmetro, remote (RUCC 7-9)"))
}

origins <- frame %>% filter(!is.na(rurality)) %>%
  count(location_key, center_lat, center_lng, rurality) %>%
  group_by(location_key, center_lat, center_lng) %>%
  slice_max(n, n = 1, with_ties = FALSE) %>% ungroup()

samp <- origins %>% group_by(rurality) %>%
  slice_sample(n = N_PER) %>% ungroup()
cat("=========== CALIBRATION SAMPLE ===========\n")
print(as.data.frame(count(samp, rurality)), row.names = FALSE)
cat(sprintf("total origins to re-route: %s (~%.0f min)\n\n",
            nrow(samp), nrow(samp) * (SLEEP_S + 1.2) / 60))

# --- 2. re-route them on osm.de ----------------------------------------------
fetch_one <- function(lat, lon) {
  body <- list(locations = list(list(lat = lat, lon = lon)), costing = "auto",
               contours = lapply(BANDS, function(b) list(time = b)),
               polygons = TRUE, denoise = 0.3, generalize = 50,
               min_road_class = "residential", minimum_reachability = 500)
  for (attempt in 1:3) {
    r <- tryCatch(httr::POST(paste0(SERVER, "/isochrone"), body = body,
                             encode = "json", httr::timeout(120),
                             httr::add_headers("User-Agent" = "midwifery-access-study/1.0")),
                  error = function(e) e)
    if (inherits(r, "error")) { Sys.sleep(SLEEP_S * attempt * 2); next }
    if (status_code(r) %in% c(429, 503)) {
      ra <- suppressWarnings(as.numeric(headers(r)[["retry-after"]]))
      Sys.sleep(if (!is.na(ra)) ra else SLEEP_S * 10 * attempt); next
    }
    if (http_error(r)) { Sys.sleep(SLEEP_S * attempt); next }
    g <- tryCatch(sf::st_read(content(r, as = "text", encoding = "UTF-8"), quiet = TRUE),
                  error = function(e) e)
    if (inherits(g, "error")) return(NULL)
    return(g)
  }
  NULL
}

new_polys <- list()
for (i in seq_len(nrow(samp))) {
  g <- fetch_one(samp$center_lat[i], samp$center_lng[i])
  if (!is.null(g)) new_polys[[samp$location_key[i]]] <- g
  if (i %% 20 == 0) cat(sprintf("  [%s/%s] retrieved %s\n", i, nrow(samp), length(new_polys)))
  Sys.sleep(SLEEP_S)
}
cat(sprintf("re-routed %s of %s origins\n\n", length(new_polys), nrow(samp)))
saveRDS(new_polys, file.path(OUTDIR, "_calibration_raw.rds"))

# --- 3. compare to EC2 canonical, ONE BAND AT A TIME -------------------------
# The consolidated files are 151-201 MB compressed and expand hard; loading both
# bands at once has OOM'd this 8.6 GB machine before.
want <- names(new_polys)
res <- list()
for (b in BANDS) {
  f <- path.expand(sprintf("~/isochrones/artifacts/isochrones/isochrones_%dmin_consolidated.rds", b))
  ec <- readRDS(f)
  k <- sprintf("%.6f_%.6f", as.numeric(ec$center_lat), as.numeric(ec$center_lng))
  sel <- which(k %in% want)
  gcol <- attr(ec, "sf_column")
  if (is.null(gcol) || !gcol %in% names(ec))
    gcol <- names(ec)[vapply(ec, function(z) inherits(z, "sfc"), logical(1))][1]
  ec_sf <- sf::st_sf(location_key = k[sel],
                     geometry = sf::st_sfc(ec[[gcol]][sel], crs = sf::st_crs(ec[[gcol]])))
  ec_sf <- suppressWarnings(sf::st_transform(sf::st_make_valid(ec_sf), 4326))
  rm(ec); invisible(gc())

  for (kk in ec_sf$location_key) {
    g <- new_polys[[kk]]; if (is.null(g)) next
    bcol <- intersect(c("contour", "time"), names(g))[1]
    gi <- g[as.numeric(g[[bcol]]) == b, ]
    if (!nrow(gi)) next
    a <- sf::st_make_valid(sf::st_transform(sf::st_geometry(gi), 4326))
    e <- sf::st_geometry(ec_sf[ec_sf$location_key == kk, ])[1]
    inter <- suppressWarnings(sf::st_area(sf::st_intersection(a, e)))
    uni   <- suppressWarnings(sf::st_area(sf::st_union(a, e)))
    res[[length(res) + 1]] <- tibble(
      location_key = kk, band = b,
      area_osmde_km2 = as.numeric(sf::st_area(a)) / 1e6,
      area_ec2_km2   = as.numeric(sf::st_area(e)) / 1e6,
      iou = if (length(inter) && length(uni) && as.numeric(uni) > 0)
              as.numeric(sum(inter)) / as.numeric(uni) else NA_real_)
  }
  rm(ec_sf); invisible(gc())
  cat(sprintf("band %s compared\n", b))
}

cmp <- bind_rows(res) %>%
  mutate(area_ratio = area_osmde_km2 / area_ec2_km2) %>%
  left_join(samp %>% select(location_key, rurality), by = "location_key")

cat("\n=========== ENGINE AGREEMENT BY RURALITY ===========\n")
summ <- cmp %>% group_by(rurality, band) %>%
  summarise(n = n(),
            median_area_ratio = round(median(area_ratio, na.rm = TRUE), 3),
            median_iou = round(median(iou, na.rm = TRUE), 3),
            pct_iou_over_0.8 = round(100 * mean(iou > 0.8, na.rm = TRUE), 1),
            .groups = "drop")
print(as.data.frame(summ), row.names = FALSE)

cat("\nINTERPRETATION GUIDE\n")
cat("  area_ratio ~1.0 and IoU >0.8 across ALL strata: the engines are\n")
cat("    interchangeable for this purpose; the mixed-engine caveat is minor.\n")
cat("  ratio uniformly off but STABLE across strata: a systematic offset, which\n")
cat("    biases absolute access levels but not the rural gradient.\n")
cat("  ratio or IoU DEGRADING from metro to remote: the engine difference is\n")
cat("    itself rural-selective and cannot be separated from the rural access\n")
cat("    finding. The osm.de polygons would not support a rural gradient claim.\n")

write_csv(cmp,  file.path(OUTDIR, "calibration_osmde_vs_ec2.csv"), na = "")
write_csv(summ, file.path(OUTDIR, "calibration_summary_by_rurality.csv"), na = "")
cat(sprintf("\nwritten: %s\n", file.path(OUTDIR, "calibration_osmde_vs_ec2.csv")))
