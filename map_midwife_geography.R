#!/usr/bin/env Rscript
# =============================================================================
# Maps of the linked midwife cohort, built with mufflyt/mysterymaps
# =============================================================================
#
# Uses the frozen linkage and the enhanced geography. Two rules govern what is
# plotted:
#
#   TIER. Only primary_midwifery links appear in the headline maps. Nursing and
#   fuzzy tiers rest on weaker identity evidence and are mapped separately, so a
#   reader can see how much of a pattern depends on them.
#
#   PERSON-LEVEL DISCLOSURE. These are real people at real practice addresses.
#   The point map jitters coordinates and carries no names -- a dot means "a
#   certified midwife practises near here", not "this is Jane Smith's office".
#   County choropleths are aggregate and carry no such risk.
#
# Outputs: docs/maps/*.png (static), docs/maps/*.html (leaflet)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(sf); library(leaflet)
})

MM <- Sys.getenv("MYSTERYMAPS_DIR", "/tmp/mysterymaps")
for (f in c("map_create_base.R", "geographic_map.R", "map_acceptance_rate.R")) {
  p <- file.path(MM, "R", f)
  if (file.exists(p)) suppressWarnings(suppressMessages(source(p)))
}
stopifnot(exists("mysterymaps_geographic_map"), exists("mysterymaps_map_base"))
cat("mysterymaps loaded:", paste(ls(pattern = "^mysterymaps_"), collapse = ", "), "\n")

dir.create("docs/maps", recursive = TRUE, showWarnings = FALSE)

link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))
geo  <- read_csv("midwives_geography_enhanced.csv", show_col_types = FALSE)

cohort <- link %>%
  select(certification_number, linkage_tier, status, nppes_state, nppes_city,
         nppes_location_year) %>%
  left_join(geo %>% select(certification_number, county_best, county_exact),
            by = "certification_number") %>%
  filter(!is.na(county_best))

primary <- cohort %>% filter(linkage_tier == "primary_midwifery")
cat(sprintf("mappable: %s primary, %s all tiers\n",
            format(nrow(primary), big.mark = ","), format(nrow(cohort), big.mark = ",")))

# --- 1. STATE CHOROPLETH: midwives per 100,000 women aged 15-44 --------------
cb <- read_csv("data/county_base.csv", show_col_types = FALSE,
               col_types = cols(GEOID = col_character()))
denom_col <- intersect(c("female_15_44", "women_15_44", "pop_female_15_44",
                         "total_pop", "population"), names(cb))[1]
state_col <- intersect(c("state_abbr", "state", "STATEFP", "state_name"), names(cb))[1]
cat(sprintf("county_base: denominator '%s', state '%s'\n", denom_col, state_col))

by_state <- primary %>% count(nppes_state, name = "midwives") %>%
  filter(!is.na(nppes_state), nchar(nppes_state) == 2)

if (!is.na(denom_col) && !is.na(state_col)) {
  pop <- cb %>% group_by(st = .data[[state_col]]) %>%
    summarise(denom = sum(.data[[denom_col]], na.rm = TRUE), .groups = "drop")
  by_state <- by_state %>% left_join(pop, by = c("nppes_state" = "st")) %>%
    mutate(rate = ifelse(is.na(denom) | denom == 0, NA_real_, 1e5 * midwives / denom))
} else {
  by_state <- by_state %>% mutate(rate = midwives)
}
write_csv(by_state, "docs/maps/midwives_by_state.csv")

# mysterymaps_geographic_map() is written for acceptance-rate PROPORTIONS and
# warns on anything outside [0, 1], so the supply rate is rescaled to a
# 0-1 index of the highest-supply state. The underlying per-100k values stay in
# docs/maps/midwives_by_state.csv and label the legend.
rng <- range(by_state$rate, na.rm = TRUE)
p1 <- tryCatch(
  mysterymaps_geographic_map(
    data = by_state %>% transmute(state = nppes_state,
                                  offered = ifelse(is.na(rate), 0,
                                                   (rate - rng[1]) / diff(rng))),
    state_col = "state", outcome_col = "offered",
    fill_label = sprintf("Supply index\n(0 = %.1f, 1 = %.1f per 100k)", rng[1], rng[2]),
    title = "Certified midwife supply by state",
    subtitle = sprintf("%s primary-tier links · midwives per 100,000 women aged 15-44",
                       format(nrow(primary), big.mark = ",")),
    palette = "viridis"),
  error = function(e) {cat("mysterymaps_geographic_map:", conditionMessage(e), "\n"); NULL})
if (!is.null(p1)) {
  p1 <- p1 + theme(plot.background = element_rect(fill = "#f5f7f8", colour = NA),
                   legend.background = element_rect(fill = "#f5f7f8", colour = NA))
  ggsave("docs/maps/state_choropleth.png", p1, width = 10, height = 6.5, dpi = 200,
         bg = "#f5f7f8")
  cat("wrote docs/maps/state_choropleth.png\n")
}

# --- 2. COUNTY CHOROPLETH ----------------------------------------------------
# mysterymaps maps states and HRRs; county is this project's analytic grain, so
# the county layer is drawn here using the same TIGER 2023 vintage the linkage
# assigned counties from.
suppressPackageStartupMessages(library(tigris)); options(tigris_use_cache = TRUE)
counties <- suppressMessages(tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  filter(!STATEFP %in% c("02", "15", "60", "66", "69", "72", "78"))   # CONUS
by_county <- primary %>% count(county_best, name = "midwives")
cmap <- counties %>% left_join(by_county, by = c("GEOID" = "county_best"))

p2 <- ggplot(cmap) +
  geom_sf(aes(fill = midwives), colour = NA) +
  scale_fill_viridis_c(option = "viridis", na.value = "grey92", trans = "sqrt",
                       name = "Midwives", breaks = c(1, 5, 20, 50, 150)) +
  coord_sf(crs = 5070) +
  labs(title = "Certified midwives by county of practice",
       subtitle = sprintf("%s primary-tier links · counties with none shown grey",
                          format(nrow(primary), big.mark = ",")),
       caption = "AMCB certification directory linked to NPPES 2007-2025 · TIGER 2023 counties") +
  theme_void(base_size = 12) +
  # theme_void() leaves the background TRANSPARENT, which renders every label
  # invisible against a dark viewer -- the first version of this map lost its
  # title, caption and legend entirely. Paint the canvas explicitly.
  theme(plot.background  = element_rect(fill = "#f5f7f8", colour = NA),
        panel.background = element_rect(fill = "#f5f7f8", colour = NA),
        legend.background = element_rect(fill = "#f5f7f8", colour = NA),
        plot.title    = element_text(face = "bold", size = 16, colour = "#0f1519",
                                     margin = margin(b = 4)),
        plot.subtitle = element_text(colour = "#5c6b74", size = 11,
                                     margin = margin(b = 10)),
        plot.caption  = element_text(colour = "#5c6b74", size = 8, hjust = 0,
                                     margin = margin(t = 10)),
        legend.title  = element_text(colour = "#0f1519", size = 9),
        legend.text   = element_text(colour = "#5c6b74", size = 8),
        legend.position = "right",
        plot.margin = margin(18, 18, 14, 18))
ggsave("docs/maps/county_choropleth.png", p2, width = 11, height = 7, dpi = 200, bg = "#f5f7f8")
cat("wrote docs/maps/county_choropleth.png\n")

# --- 3. LEAFLET: county choropleth, aggregate only ---------------------------
pal <- colorNumeric("viridis", domain = sqrt(cmap$midwives), na.color = "#e8e8e8")
m1 <- mysterymaps_map_base(title = "Certified midwives by county", zoom = 4) %>%
  addPolygons(data = st_transform(cmap, 4326),
              fillColor = ~pal(sqrt(midwives)), fillOpacity = .8, weight = .4,
              color = "#ffffff",
              label = ~sprintf("%s, %s: %s midwives", NAME, STUSPS,
                               ifelse(is.na(midwives), 0, midwives)),
              highlightOptions = highlightOptions(weight = 2, color = "#146b60",
                                                  bringToFront = TRUE)) %>%
  addLegend(pal = pal, values = sqrt(cmap$midwives), title = "Midwives (sqrt)",
            position = "bottomright")
htmlwidgets::saveWidget(m1, "docs/maps/leaflet_counties.html", selfcontained = TRUE)
cat("wrote docs/maps/leaflet_counties.html\n")

# --- 4. LEAFLET: jittered practice points, no names --------------------------
pts <- primary %>%
  left_join(read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE) %>%
              select(certification_number, latitude, longitude),
            by = "certification_number") %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  mutate(lat = latitude  + runif(n(), -0.02, 0.02),
         lng = longitude + runif(n(), -0.02, 0.02))
m2 <- mysterymaps_map_base(title = "Practice locations (jittered)", zoom = 4) %>%
  addCircleMarkers(data = pts, lng = ~lng, lat = ~lat, radius = 3,
                   stroke = FALSE, fillOpacity = .45, fillColor = "#146b60",
                   clusterOptions = markerClusterOptions(),
                   # No names, no certification numbers: a dot is "a midwife
                   # practises near here", not an identified individual.
                   label = ~sprintf("%s (last observed %s)", nppes_state,
                                    nppes_location_year))
htmlwidgets::saveWidget(m2, "docs/maps/leaflet_points.html", selfcontained = TRUE)
cat(sprintf("wrote docs/maps/leaflet_points.html (%s jittered points)\n",
            format(nrow(pts), big.mark = ",")))

cat("\ntop states:\n"); print(as.data.frame(by_state %>% arrange(desc(midwives)) %>% head(8)))
cat(sprintf("\ncounties with >=1 primary-tier midwife: %s of %s CONUS counties\n",
            format(sum(!is.na(cmap$midwives)), big.mark = ","), format(nrow(cmap), big.mark = ",")))
