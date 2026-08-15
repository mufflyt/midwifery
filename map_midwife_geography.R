#!/usr/bin/env Rscript
# =============================================================================
# Maps of the linked midwife cohort, built with mufflyt/mysterymaps
# =============================================================================
#
# Uses the frozen linkage and the enhanced geography. Two rules govern what is
# plotted:
#
#   TWO FILTERS, NOT ONE. Linkage tier answers "how sure are we this is the
#   right NPI?"; AMCB certification status answers "is this person part of the
#   current workforce?" They are independent, and conflating them turns a
#   confidently-linked DECEASED certificant into a practising midwife. An
#   earlier version of this script did exactly that: 2,741 of 14,618 mapped
#   records (18.8%) were LAPSED, RETIRED, DECEASED, REVOKED or SURRENDERED, and
#   the resulting rates were described as workforce supply. They were not.
#
#   So two separate products are produced:
#     roster_*  every primary-tier link, whatever its status -- DESCRIPTIVE
#               only, a picture of the linkage, never of the workforce
#     active_*  ACTIVE certificants only -- the only maps that may carry
#               workforce or supply language
#
#   PERSON-LEVEL DISCLOSURE. Jittering is not de-identification. 14,000
#   person-level points still reveal approximate locations of identifiable
#   clinicians, and in a rural county with one CNM the jitter is cosmetic. The
#   point map is therefore INTERNAL QA ONLY and is not committed or published;
#   shared products are county or state aggregates.
#
# Outputs: docs/maps/*.png (static), docs/maps/*.html (leaflet)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(ggplot2); library(sf); library(leaflet)
})

# The mysterymaps SOURCE checkout, which is not the same dependency as
# R/lib/mysterymaps_dep.R's mm_home(): that one resolves the staged urogyn
# helpers (R/mysterymaps_urogyn.R, in ~/isochrones-main), while the three files
# below live in the package source (~/mysterymaps/R). Two locations, two
# purposes -- hence two variables, resolved here in order of specificity.
#
# This used to default to "/tmp/mysterymaps", and the source() was guarded by
# if (file.exists(p)). On this machine that directory EXISTS and is EMPTY, so
# all three sources were skipped in silence and the failure surfaced two lines
# later as
#
#     Error: exists("mysterymaps_geographic_map") is not TRUE
#
# which sent the reader hunting for a missing export in another repository.
# There was nothing wrong with the function; the loader had quietly loaded
# nothing. An absent dependency must say which variable to set and where it
# looked -- the same rule the isochrones and mysterymaps dep files already
# follow.
MM_FILES <- c("map_create_base.R", "geographic_map.R", "map_acceptance_rate.R")

MM <- local({
  has_files <- function(d) all(file.exists(file.path(d, "R", MM_FILES)))

  # An EXPLICIT variable that does not hold the files is an error, not an
  # invitation to look elsewhere. Falling through to a different checkout would
  # silently use something other than what the caller asked for -- the same
  # failure in a new costume, and the reason R/lib/isochrones_dep.R refuses to
  # fall back to a stale copy.
  for (v in c("MYSTERYMAPS_DIR", "MYSTERYMAPS_HOME")) {
    set <- Sys.getenv(v)
    if (nzchar(set) && !has_files(set)) {
      stop(sprintf(paste0(
        "%s is set to \"%s\", which does not contain R/{%s}.\n",
        "  Point it at your mufflyt/mysterymaps checkout, or unset it to let\n",
        "  this script resolve ~/mysterymaps itself. It is NOT falling back:\n",
        "  an explicit setting that is wrong must fail, not be ignored."),
        v, set, paste(MM_FILES, collapse = ", ")), call. = FALSE)
    }
  }

  cand <- c(Sys.getenv("MYSTERYMAPS_DIR"),
            Sys.getenv("MYSTERYMAPS_HOME"),
            path.expand("~/mysterymaps"))
  cand <- unique(cand[nzchar(cand)])
  hit <- cand[vapply(cand, has_files, logical(1))]

  if (!length(hit)) {
    stop(sprintf(paste0(
      "mysterymaps source not found. Needed all of: %s\n",
      "  Searched : %s\n",
      "  Fix      : set MYSTERYMAPS_DIR to your mufflyt/mysterymaps checkout,\n",
      "             e.g. MYSTERYMAPS_DIR=~/mysterymaps\n",
      "  NOTE     : this is the package SOURCE, not the ~/isochrones-main\n",
      "             checkout that R/lib/mysterymaps_dep.R resolves."),
      paste(MM_FILES, collapse = ", "),
      paste(cand, collapse = ", ")), call. = FALSE)
  }

  hit[[1L]]
})

for (f in MM_FILES) {
  suppressWarnings(suppressMessages(source(file.path(MM, "R", f))))
}
cat("mysterymaps source:", MM, "\n")
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

roster <- cohort %>% filter(linkage_tier == "primary_midwifery")

# AMCB's own definitions: only ACTIVE means "currently certified, may use the
# CNM/CM title". RETIRED is explicitly "permanently retired from practice";
# LAPSED and REVOKED holders may no longer use the title at all.
# WORKFORCE INCLUSION RULE: status == "ACTIVE", nothing else.
#   RETIRED     AMCB: "permanently retired from practice"
#   LAPSED      may no longer use the CNM/CM title
#   REVOKED     title removed, usually by discipline ruling
#   SURRENDERED title given up, usually by discipline ruling
#   DECEASED    self-evident
#   EMERITUS    27 records carrying a status AMCB's own definitions page does
#               not document; excluded explicitly rather than silently
#   DEACTIVATED AMCB: "usually to switch certification from CM to CNM or CNM to
#               CM". 16 of 22 have an ACTIVE record under the same name, so the
#               PERSON is still counted; 6 are represented by no ACTIVE record
#               and are genuinely dropped. Verified: ACTIVE-only yields 11,913
#               rows and 11,913 distinct NPIs, so nobody is double-counted.
ACTIVE_STATUSES <- c("ACTIVE")
active <- roster %>% filter(status %in% ACTIVE_STATUSES)

cat(sprintf("primary-tier links with geography : %s\n", format(nrow(roster), big.mark = ",")))
cat("  status composition:\n")
print(as.data.frame(roster %>% count(status, sort = TRUE) %>%
                      mutate(pct = round(100 * n / sum(n), 1))))
cat(sprintf("  ACTIVE (workforce denominator)  : %s (%.1f%%)\n",
            format(nrow(active), big.mark = ","), 100 * nrow(active) / nrow(roster)))

# Completeness among ACTIVE certificants, the number a workforce claim needs.
all_active <- link %>% filter(status %in% ACTIVE_STATUSES)
act_primary <- all_active %>% filter(linkage_tier == "primary_midwifery")
cat(sprintf("\nACTIVE certificants on the roster : %s\n", format(nrow(all_active), big.mark = ",")))
cat(sprintf("  with primary NPI linkage        : %s (%.1f%%)\n",
            format(nrow(act_primary), big.mark = ","), 100 * nrow(act_primary) / nrow(all_active)))
cat(sprintf("  with county geography           : %s (%.1f%%)\n",
            format(nrow(active), big.mark = ","), 100 * nrow(active) / nrow(all_active)))

# --- PRODUCT A: roster geography, DESCRIPTIVE ONLY ---------------------------
# Every primary-linked certificant regardless of status. This is a picture of
# the LINKAGE, not of the workforce, and carries no rate and no denominator.
counties_a <- suppressMessages(tigris::counties(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  filter(!STATEFP %in% c("02", "15", "60", "66", "69", "72", "78"))
roster_cty <- counties_a %>%
  left_join(roster %>% count(county_best, name = "certificants"),
            by = c("GEOID" = "county_best"))
pA <- ggplot(roster_cty) +
  geom_sf(aes(fill = certificants), colour = NA) +
  scale_fill_viridis_c(option = "mako", na.value = "grey92", trans = "sqrt",
                       name = "Certificants", breaks = c(1, 5, 20, 50, 150)) +
  coord_sf(crs = 5070) +
  labs(title = "All primary-linked AMCB certificants by last-observed practice location",
       subtitle = sprintf("%s records of ANY certification status - %s ACTIVE, %s not",
                          format(nrow(roster), big.mark = ","),
                          format(nrow(active), big.mark = ","),
                          format(nrow(roster) - nrow(active), big.mark = ",")),
       caption = paste("DESCRIPTIVE map of the linkage, NOT the workforce: includes lapsed,",
                       "retired and deceased certificants. Not a supply measure.")) +
  theme_void(base_size = 12) +
  theme(plot.background = element_rect(fill = "#f5f7f8", colour = NA),
        legend.background = element_rect(fill = "#f5f7f8", colour = NA),
        plot.title = element_text(face = "bold", size = 14, colour = "#0f1519"),
        plot.subtitle = element_text(colour = "#5c6b74", size = 10.5, margin = margin(b = 8)),
        plot.caption = element_text(colour = "#8f2a2a", size = 8, hjust = 0),
        plot.margin = margin(18, 18, 14, 18))
ggsave("docs/maps/roster_county_descriptive.png", pA, width = 11, height = 7, dpi = 200,
       bg = "#f5f7f8")
cat("wrote docs/maps/roster_county_descriptive.png (PRODUCT A, descriptive)\n")

# --- PRODUCT B: active workforce ---------------------------------------------
primary <- active

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
write_csv(by_state, "docs/maps/active_midwives_by_state.csv")

# mysterymaps_geographic_map() is written for acceptance-rate PROPORTIONS and
# warns on anything outside [0, 1], so the supply rate is rescaled to a
# 0-1 index of the highest-supply state. The underlying per-100k values stay in
# docs/maps/midwives_by_state.csv and label the legend.
# The rate is a provider-to-population ratio and is plotted as itself.
# mysterymaps_geographic_map() coerces values into [0, 1] because it is written
# for acceptance-rate proportions, which would turn a meaningful rate into an
# arbitrary index; mysterymaps supplies the state basemap instead and the fill
# scale is defined here so the legend shows real units.
states_sf <- suppressMessages(tigris::states(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  filter(!STATEFP %in% c("02", "15", "60", "66", "69", "72", "78"))
smap <- states_sf %>% left_join(by_state, by = c("STUSPS" = "nppes_state"))

p1 <- ggplot(smap) +
  geom_sf(aes(fill = rate), colour = "white", linewidth = .25) +
  scale_fill_viridis_c(option = "viridis", na.value = "grey92",
                       name = "per 100,000\nwomen 15-44") +
  coord_sf(crs = 5070) +
  labs(title = "Active AMCB-certified midwives per 100,000 women aged 15-44",
       subtitle = sprintf("%s ACTIVE certificants by LAST-OBSERVED NPPES practice location",
                          format(nrow(primary), big.mark = ",")),
       caption = "Practice-location distribution, not a measure of access. AMCB directory linked to NPPES 2007-2025.") +
  theme_void(base_size = 12) +
  theme(plot.background = element_rect(fill = "#f5f7f8", colour = NA),
        legend.background = element_rect(fill = "#f5f7f8", colour = NA),
        plot.title = element_text(face = "bold", size = 15, colour = "#0f1519"),
        plot.subtitle = element_text(colour = "#5c6b74", size = 11, margin = margin(b = 8)),
        plot.caption = element_text(colour = "#5c6b74", size = 8, hjust = 0),
        legend.title = element_text(size = 9), legend.text = element_text(size = 8),
        plot.margin = margin(18, 18, 14, 18))
ggsave("docs/maps/active_state_rate.png", p1, width = 10, height = 6.5, dpi = 200, bg = "#f5f7f8")
cat("wrote docs/maps/active_state_rate.png\n")

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
  labs(title = "Active certified midwives by last-observed practice county",
       subtitle = sprintf("%s ACTIVE certificants · grey = no linked practice location in that county",
                          format(nrow(primary), big.mark = ",")),
       caption = paste("Distribution of practice locations, NOT access: patients cross county lines,",
                       "and 34% of the roster never linked. AMCB linked to NPPES 2007-2025, TIGER 2023.")) +
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
ggsave("docs/maps/active_county_counts.png", p2, width = 11, height = 7, dpi = 200, bg = "#f5f7f8")
cat("wrote docs/maps/active_county_counts.png\n")

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
htmlwidgets::saveWidget(m1, "docs/maps/leaflet_active_counties.html", selfcontained = TRUE)
cat("wrote docs/maps/leaflet_active_counties.html\n")

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
# INTERNAL QA ONLY -- written outside docs/ so it is never published.
dir.create("qa", showWarnings = FALSE)
htmlwidgets::saveWidget(m2, "qa/leaflet_points_INTERNAL.html", selfcontained = TRUE)
cat(sprintf("wrote qa/leaflet_points_INTERNAL.html (%s points, QA only)\n",
            format(nrow(pts), big.mark = ",")))

cat("\ntop states:\n"); print(as.data.frame(by_state %>% arrange(desc(midwives)) %>% head(8)))
cat(sprintf("\ncounties with >=1 primary-tier midwife: %s of %s CONUS counties\n",
            format(sum(!is.na(cmap$midwives)), big.mark = ","), format(nrow(cmap), big.mark = ",")))
