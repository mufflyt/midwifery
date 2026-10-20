#!/usr/bin/env Rscript
# =============================================================================
# Person-level dot map of the ACTIVE, primary-linked cohort -- INTERNAL ONLY
# =============================================================================
# Same disclosure judgement as map_midwife_geography.R: jittering is not
# de-identification, and in a rural county with one CNM a dot IS that person.
# This output is for the presenter's own review, never for a slide an
# audience keeps or an attendee photographs. It is written outside docs/ and
# outside any path the manuscript or public pipeline reads, and its filename
# carries the warning so it cannot be mistaken for a publishable figure later.
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(sf)
})

OUT <- "artifacts/internal_qa/dot_map_active_cohort_INTERNAL_DO_NOT_PUBLISH.png"
dir.create(dirname(OUT), recursive = TRUE, showWarnings = FALSE)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE,
                 col_types = cols(certification_number = col_character())) %>%
  select(certification_number, status)

geo <- read_csv("artifacts/midwives_geography_FROZEN.csv", show_col_types = FALSE,
                col_types = cols(certification_number = col_character())) %>%
  select(certification_number, match_status, latitude, longitude)

# ACTIVE + primary tier only -- the same cohort Table 1 and the manuscript use,
# not every linked record regardless of status.
active <- geo %>%
  inner_join(link, by = "certification_number") %>%
  filter(status == "ACTIVE", match_status == "primary",
         !is.na(latitude), !is.na(longitude),
         longitude > -130, longitude < -65, latitude > 24, latitude < 50) # CONUS box; drops AK/HI/territories

cat(sprintf("plotting %s ACTIVE, primary-linked, CONUS-geocoded midwives\n",
            format(nrow(active), big.mark = ",")))

states_sf <- suppressMessages(tigris::states(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  filter(!STATEFP %in% c("02", "15", "60", "66", "69", "72", "78"))

set.seed(42) # fixed, so the jitter is reproducible rather than a new disclosure risk on every render
jittered <- active %>%
  mutate(lon_j = longitude + rnorm(n(), 0, 0.08),
         lat_j = latitude + rnorm(n(), 0, 0.08)) %>%
  st_as_sf(coords = c("lon_j", "lat_j"), crs = 4326) # geom_point ignores coord_sf's reprojection; points must be sf geometry, not raw x/y

p <- ggplot() +
  geom_sf(data = states_sf, fill = "#f5f7f8", colour = "grey75", linewidth = 0.3) +
  geom_sf(data = jittered, size = 0.6, alpha = 0.18, colour = "#1f6f78") +
  coord_sf(crs = 5070) +
  labs(title = "ACTIVE, primary-linked CNM/CM cohort -- one jittered point per midwife",
       subtitle = sprintf("%s midwives. Coordinates jittered (SD ~0.08 deg); still shows isolated\npractice locations in sparse counties. INTERNAL REVIEW ONLY -- do not publish or share.",
                          format(nrow(jittered), big.mark = ","))) +
  theme_void(base_size = 12) +
  theme(plot.background = element_rect(fill = "white", colour = NA),
        plot.title = element_text(face = "bold", size = 13),
        plot.subtitle = element_text(colour = "#8f2a2a", size = 9.5, margin = margin(b = 6)),
        plot.margin = margin(14, 14, 10, 14))

ggsave(OUT, p, width = 10, height = 6.4, dpi = 200, bg = "white")
cat("wrote", OUT, "-- INTERNAL ONLY, do not commit or publish\n")
