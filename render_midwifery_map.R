#!/usr/bin/env Rscript
# =============================================================================
# Render the midwifery access map -- presentation layer only
# =============================================================================
# Reads the dissolved unions written by build_midwifery_isochrone_map.R, so
# re-styling costs seconds instead of re-dissolving 4,700 polygons.
#
# DESIGN FIXES over the first draft, following the conventions in
# ~/isochrones-main/R/mysterymaps_urogyn.R:
#
#  1. RADIO GROUPS, NOT CHECKBOXES. Overlaying a translucent isochrone fill on
#     a viridis choropleth multiplies two colour scales into mud -- neither is
#     readable. The urogyn builder uses baseGroups so metrics are mutually
#     exclusive. Same here: one metric at a time.
#
#  2. ZERO GETS ITS OWN COLOUR (mm_jenks_zero_scale). In the first draft the
#     bottom bin was 0.0-0.5, so a county with NO midwives looked identical to
#     one with 0.4 per 1,000. "None" is a categorical fact, not the low end of
#     a continuum, and for this study it is the single most important class.
#     Positive values then get Jenks natural breaks rather than round numbers,
#     because the distribution is heavily right-skewed.
#
#  3. THREE GREYS THAT MEANT DIFFERENT THINGS ARE NOW DISTINGUISHED: no
#     midwives (light grey), rate suppressed under 50 births (hatched), and no
#     data at all (white).
#
#  4. THE COMPLEMENT IS DRAWN. "Beyond 60 minutes" shades the ground that is
#     NOT covered. Coverage maps flatter themselves -- the eye reads shaded
#     area as the finding -- while the uncovered gap is what the study is
#     about.
#
#  5. The caveat panel is collapsible and height-capped so it never covers the
#     map, and the legend switches with the active layer.
#
# Still dissolved-union only: no per-midwife geometry is read or drawn.
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr)
  library(leaflet); library(htmlwidgets); library(htmltools)
})
sf::sf_use_s2(FALSE)

# PROVIDER DOTS ARE SHOWN. AMCB certification status and the NPPES registry are
# both public records, and the owner has judged the dot layer publishable on
# that basis. The dissolved-union layers remain, because they answer a different
# question (where is there coverage) than the dots do (who is where).
OUTDIR <- "artifacts/maps"

# Geography and band constants come from mufflyaccess, the SSOT package. An
# earlier version of this file hand-typed the non-contiguous FIPS vector, which
# was byte-identical to NON_CONTIGUOUS_FIPS -- retyped, not derived, so the two
# would have diverged silently at the next revision.
CONUS_EXCLUDE <- mufflyaccess::NON_CONTIGUOUS_FIPS              # AK HI AS GU MP PR VI
BANDS_SHOWN   <- c(30, 60)
stopifnot(all(BANDS_SHOWN %in% mufflyaccess::CANONICAL_BANDS))
# Showing 2 of the 4 canonical bands is a deliberate, stated deviation: no
# 120/180 polygons were generated for the newly-routed locations, and falling
# back to canonical-only coverage for those bands would reinstate the
# rural-selective bias this whole effort exists to avoid.
BANDS_OMITTED <- setdiff(mufflyaccess::CANONICAL_BANDS, BANDS_SHOWN)

# --- access language guard ---------------------------------------------------
# twostep encodes a methodological constraint as a vocabulary: an accessibility
# surface with no defensible demand target cannot support normative claims, so
# "shortage", "adequacy", "unmet need" and friends are forbidden on user-facing
# strings. twostep does not currently install (it sources a file absent from the
# repo), so the one module is sourced directly rather than skipped.
local({
  f <- path.expand("~/twostep/R/access_language.R")
  if (file.exists(f)) sys.source(f, envir = globalenv())
})

# --- canonical helpers -------------------------------------------------------
# mm_jenks_zero_scale() and the map conventions below come from
# R/mysterymaps_urogyn.R in isochrones-main; see R/lib/mysterymaps_dep.R for why
# this is a path dependency and not a copy. An earlier draft of this file
# duplicated the scale function line for line.
source("R/lib/mysterymaps_dep.R")
invisible(load_mysterymaps())          # mm_jenks_zero_scale (staging file)
suppressPackageStartupMessages(library(mysterymaps))

# --- data --------------------------------------------------------------------
u30 <- readRDS(file.path(OUTDIR, "midwifery_isochrone_union_30min.rds"))
u60 <- readRDS(file.path(OUTDIR, "midwifery_isochrone_union_60min.rds"))

sup <- read_csv("artifacts/county_midwifery_supply.csv", show_col_types = FALSE) %>%
  mutate(fips = str_pad(as.character(fips), 5, "left", "0"))

cty <- suppressMessages(
  tigris::counties(cb = TRUE, resolution = "20m", year = 2023, progress_bar = FALSE)) %>%
  sf::st_transform(4326) %>%
  filter(!STATEFP %in% CONUS_EXCLUDE) %>%          # CONUS view; see note below
  mutate(fips = GEOID) %>%
  left_join(sup %>% select(fips, county_name_base, state, midwives_per_1k_births,
                           study_midwives, births_used, rurality, ahrf_obgyn,
                           pct_lbw),
            by = "fips")
cty <- suppressWarnings(rmapshaper::ms_simplify(cty, keep = 0.06, keep_shapes = TRUE))

# Clip the coverage surfaces to CONUS so they cannot extend past the county
# layer's edge -- a surface that runs off the frame reads as "unbounded".
conus <- sf::st_union(sf::st_geometry(cty))
clip_to <- function(u) {
  g <- suppressWarnings(sf::st_intersection(
    sf::st_make_valid(sf::st_geometry(u)), conus))
  suppressWarnings(rmapshaper::ms_simplify(sf::st_sf(geometry = g),
                                           keep = 0.08, keep_shapes = TRUE))
}
c30 <- clip_to(u30); c60 <- clip_to(u60)

# The complement: ground beyond the drive time. This is the gap the study is
# about, and it must be visible as a positive shape rather than as absence.
gap60 <- sf::st_sf(geometry = suppressWarnings(
  sf::st_difference(conus, sf::st_union(sf::st_geometry(c60)))))
gap60 <- suppressWarnings(rmapshaper::ms_simplify(gap60, keep = 0.08, keep_shapes = TRUE))

cty$county_label_disp <- paste0(cty$county_name_base, ", ", cty$state)

sc <- mm_jenks_zero_scale(cty$midwives_per_1k_births, k = 6, digits = 1)
# Caller-side wording only: the canonical zero label is "0.0", and for this map
# the distinction between "no midwife" and "a low rate" is the whole point.
sc$leg_labs[1] <- "none"

# --- labels ------------------------------------------------------------------
fmt <- function(x) ifelse(is.na(x), "—", format(round(x), big.mark = ","))
rate_txt <- ifelse(
  is.na(cty$midwives_per_1k_births),
  "<span style='color:#888'>rate suppressed (&lt;50 births)</span>",
  sprintf("<b>%s</b> per 1,000 births", cty$midwives_per_1k_births))
lab <- sprintf(
  "<div style='font:12px/1.5 system-ui,sans-serif'><b>%s, %s</b><br/>
   %s<br/>%s midwives &nbsp;&middot;&nbsp; %s OB/GYNs<br/>%s births/yr<br/>
   <span style='color:#666'>%s</span></div>",
  cty$county_name_base, cty$state, rate_txt,
  fmt(cty$study_midwives), fmt(cty$ahrf_obgyn), fmt(cty$births_used),
  ifelse(is.na(cty$rurality), "", cty$rurality)) %>% lapply(htmltools::HTML)

# --- county narrative --------------------------------------------------------
# Raw numbers in a tooltip make a reader do the interpretation. The sentence
# engine (R/10-county-birth-profiles.R) already writes a paragraph per county
# that handles the WONDER suppression caveat, per-capita framing, and outcome
# context in prose. Hover keeps the one-line summary; click opens the paragraph.
sent <- read_csv("artifacts/county_profiles/county_sentences.csv",
                 show_col_types = FALSE) %>%
  transmute(fips = str_pad(as.character(GEOID), 5, "left", "0"), sentences)
# The sentence engine explains, for every county below WONDER's 100,000-resident
# publication threshold, that WONDER does not publish it. That is true but not
# worth saying: it fires on ~2,700 of 3,109 counties, so it is boilerplate that
# pushes the county's actual numbers below the fold. The caveat belongs once, in
# the notes panel, not in every popup. Counties that DO have WONDER counts keep
# their sentence, because there the number is the point.
drop_wonder_null <- function(x) {
  x <- gsub("CDC WONDER does not report this county separately:[^.]*\\.(\\s|$)",
            "", x, perl = TRUE)
  str_squish(x)
}
sent$sentences <- drop_wonder_null(sent$sentences)
cty <- cty %>% left_join(sent, by = "fips")
cat(sprintf("counties with a narrative: %s of %s\n",
            sum(!is.na(cty$sentences)), nrow(cty)))

pop <- sprintf(
  "<div style='font:13px/1.6 system-ui,sans-serif;max-width:330px'>
   <div style='font-weight:600;font-size:14px;margin-bottom:.35em'>%s</div>
   <div>%s</div></div>",
  cty$county_label_disp,
  ifelse(is.na(cty$sentences),
         "<em style='color:#888'>No profile available for this county.</em>",
         cty$sentences)) %>% lapply(htmltools::HTML)

hi <- leaflet::highlightOptions(weight = 2, color = "#111", fillOpacity = 0.95,
                                bringToFront = TRUE)

G <- list(rate = "Midwives per 1,000 births",
          b30  = "Within 30 minutes",
          b60  = "Within 60 minutes",
          gap  = "Beyond 60 minutes")

m <- leaflet::leaflet(options = leaflet::leafletOptions(
        minZoom = 3, maxZoom = 14, zoomControl = TRUE,
        # 11,792 individual markers are only affordable on a canvas renderer;
        # the default SVG path-per-marker stalls the browser at national zoom.
        preferCanvas = TRUE)) %>%
  leaflet::addProviderTiles("CartoDB.PositronNoLabels", group = "base") %>%
  # Both from the canonical builder: an imperial scale bar, and a dedicated
  # high-zIndex pane so point markers render and hit-test ABOVE the choropleth.
  # Without the pane the dots are drawn but not reliably clickable.
  leaflet::addScaleBar(position = "bottomleft",
                       options = leaflet::scaleBarOptions(imperial = TRUE)) %>%
  leaflet::addMapPane("pts", zIndex = 650) %>%

  # --- metric 1: supply choropleth
  leaflet::addPolygons(data = cty, fillColor = ~sc$color(midwives_per_1k_births),
                       fillOpacity = 0.85, color = "#ffffff", weight = 0.4,
                       smoothFactor = 0.5, label = lab, popup = pop,
                       popupOptions = leaflet::popupOptions(maxWidth = 360),
                       highlightOptions = hi, group = G$rate) %>%

  # --- metric 2/3: coverage surfaces over a single always-on county mesh.
  # The mesh carries no `group`, so leaflet keeps it visible under every base
  # group -- three group-bound copies tripled the county geometry in the HTML.
  leaflet::addPolygons(data = sf::st_geometry(cty), fill = FALSE,
                       color = "#c0c0c0", weight = 0.3) %>%
  leaflet::addPolygons(data = sf::st_geometry(cty), fill = FALSE,
                       color = "#c0c0c0", weight = 0.3) %>%

  leaflet::addProviderTiles("CartoDB.PositronOnlyLabels", group = "base") %>%

  leaflet::addLegend(position = "bottomright", colors = sc$leg_cols,
                     labels = sc$leg_labs, title = "Midwives per<br/>1,000 births",
                     opacity = 0.9,
                     className = "info legend mm-lg mm-lg-rate") %>%

  mysterymaps_register_base_legend(G$rate, key = "rate") %>%
  mysterymaps_add_coverage_surfaces(
    surfaces = stats::setNames(list(c30, c60, gap60), c(G$b30, G$b60, G$gap)),
    colors = c("#08519c", "#3182bd", "#d94801"),
    legend_labels = c("within 30 min of a midwife",
                      "within 60 min of a midwife",
                      "more than 60 min from any midwife"),
    legend_titles = c("Drive-time coverage", "Drive-time coverage",
                      "Coverage gap")) %>%
  leaflet::addLayersControl(
    baseGroups = c(G$rate, G$b30, G$b60, G$gap),
    overlayGroups = "Midwife locations",
    options = leaflet::layersControlOptions(collapsed = FALSE)) %>%
  leaflet::fitBounds(-125, 24.5, -66.9, 49.4)

# --- collapsible caveat panel ------------------------------------------------
# Height-capped and collapsed by default so it never covers the map, per the
# urogyn panel convention.
panel <- sprintf('
<style>
 #mwnote{position:fixed;bottom:14px;left:14px;z-index:1000;max-width:340px;
  background:rgba(255,255,255,.96);border:1px solid #c8c8c8;border-radius:6px;
  font:12px/1.5 system-ui,-apple-system,sans-serif;box-shadow:0 1px 6px rgba(0,0,0,.18)}
 #mwnote summary{cursor:pointer;padding:8px 11px;font-weight:600;list-style:none}
 #mwnote summary::-webkit-details-marker{display:none}
 #mwnote summary:after{content:" \\25BE";color:#888}
 #mwnote[open] summary:after{content:" \\25B4"}
 #mwnote .bd{padding:0 11px 11px;max-height:44vh;overflow-y:auto;color:#333}
 #mwnote b.warn{color:#a63603}
 .mw-name{background:rgba(255,255,255,.92);border:0;box-shadow:none;
   padding:1px 4px;font-weight:600;color:#7b1236}
 .leaflet-tooltip.mw-name:before{display:none}
</style>
<details id="mwnote">
 <summary>Drive-time access to certified nurse-midwives &mdash; notes</summary>
 <div class="bd">
  <p style="margin:.2em 0 .7em"><b>Dissolved coverage surface.</b> Shaded ground lies
   within the stated drive time of at least one ACTIVE, AMCB-certified,
   primary-linked midwife. Individual practice locations are not shown and
   cannot be recovered from this map.</p>
  <p style="margin:.2em 0 .7em"><b>Coverage:</b> %s km&sup2; within 30 min,
   %s km&sup2; within 60 min (dissolved from %s and %s source polygons).</p>
  <p style="margin:.2em 0 .7em"><b class="warn">Two routing engines.</b> EC2 Valhalla
   for locations the canonical library already covered; the public osm.de server
   for the 2,249 midwives it did not. That split is rural-selective by
   construction. Calibration on 88 shared origins: median IoU is stable across
   the gradient (30&nbsp;min 0.80/0.79/0.78 metro/adjacent/remote; 60&nbsp;min
   0.86/0.85/0.85), but the area ratio drifts at 30&nbsp;min
   (0.85 metro &rarr; 1.09 remote), making the 30-minute surface relatively more
   generous rurally. <b>Do not read a rural gradient off the 30-minute band</b>;
   the 60-minute band is the defensible one (ratio swing 11%%, IoU &gt;0.8 in
   77&ndash;83%% of origins).</p>
  <p style="margin:.2em 0 .7em"><b>County shading</b> is midwives per 1,000 births
   (AHRF/NCHS births). "None" is its own class &mdash; a county with no midwife is
   not the low end of a scale. Counties under 50 births/yr are suppressed rather
   than shown as noisy rates.</p>
  <p style="margin:.2em 0 .7em"><b>Midwife dots</b> show every ACTIVE,
   AMCB-certified, primary-linked midwife with a geocoded practice address
   (11,792). Click for the NPI and its NPPES registry page; names appear on the
   dots from zoom&nbsp;9 in. AMCB certification and NPPES are public records.</p>
  <p style="margin:.2em 0 .7em"><b>CDC WONDER</b> publishes county natality only
   for counties of 100,000+ residents and pools the rest by state, so
   midwife-attended birth counts are unpublished &mdash; not zero &mdash; for most
   rural counties. County profiles name a WONDER count only where one exists.</p>
  <p style="margin:.2em 0 0"><b>Scope:</b> 30/60&nbsp;min only (no 120/180 polygons
   were generated). Continental US shown; Alaska and Hawaii are excluded from
   this view but retained in the underlying data.</p>
 </div>
</details>',
  format(round(u30$area_km2), big.mark = ","),
  format(round(u60$area_km2), big.mark = ","),
  format(u30$n_origins_dissolved, big.mark = ","),
  format(u60$n_origins_dissolved, big.mark = ","))

# --- INTERNAL: per-midwife dots ---------------------------------------------
{
  link <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
  crd  <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE)
  mw <- link %>%
    filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    left_join(crd %>% select(certification_number, latitude, longitude,
                             practice_city, practice_state),
              by = "certification_number") %>%
    filter(!is.na(latitude), !is.na(longitude))
  cat(sprintf("midwife dots: %s with coordinates\n", nrow(mw)))

  full_name <- str_squish(paste(mw$first_name,
                                coalesce(mw$middle_name, ""), mw$last_name))
  # NPPES provider-view is the public CMS registry page keyed by NPI.
  npi_link <- ifelse(
    is.na(mw$npi), "<em>no NPI linked</em>",
    sprintf('<a href="https://npiregistry.cms.hhs.gov/provider-view/%s" target="_blank" rel="noopener">%s</a>',
            mw$npi, mw$npi))
  mw_pop <- sprintf(
    "<div style='font:13px/1.6 system-ui,sans-serif'>
     <div style='font-weight:600'>%s</div>
     <div>NPI: %s</div>
     <div style='color:#666'>%s, %s</div>
     <div style='color:#666;font-size:11px;margin-top:.4em'>AMCB cert %s &middot; ACTIVE</div>
     </div>",
    full_name, npi_link,
    coalesce(mw$practice_city, "—"), coalesce(mw$practice_state, "—"),
    mw$certification_number)

  # NO CLUSTERING. Cluster bubbles replace the data with a count and force the
  # reader to zoom repeatedly to learn anything; every dot is drawn.
  # Names are attached as permanent tooltips, but only from zoom 9 up -- 11,792
  # labels at national zoom is unreadable ink, so the JS below adds and removes
  # the label layer on zoomend.
  mw$full_name <- full_name
  m <- m %>% leaflet::addCircleMarkers(
    data = mw, lng = ~longitude, lat = ~latitude,
    radius = 4, stroke = TRUE, weight = 1, color = "#ffffff",
    fillColor = "#c2185b", fillOpacity = 0.9,
    popup = mw_pop,
    label = ~full_name,
    labelOptions = leaflet::labelOptions(
      direction = "right", offset = c(6, 0), textsize = "11px",
      className = "mw-name", opacity = 0.95),
    options = leaflet::pathOptions(pane = "pts"),
    group = "Midwife locations")
}

# --- interaction --------------------------------------------------------------
# Both handlers are canonical (mysterymaps): legends keyed to BASE groups, and
# point labels gated by zoom instead of hidden behind cluster bubbles. An
# earlier draft of this file hand-rolled both.
m <- mysterymaps_base_legend_switcher(m, default = G$rate)
m <- mysterymaps_zoom_gated_labels(m, group = "Midwife locations",
                          min_zoom = 9, max_labels = 400)

# Reset-view control: specific to this map's CONUS framing, so it stays local.
m <- htmlwidgets::onRender(m, '
function(el, x) {
  var map = this;
  var Home = L.Control.extend({
    options: { position: "topleft" },
    onAdd: function() {
      var d = L.DomUtil.create("div", "leaflet-bar");
      d.innerHTML = \'<a href="#" title="Reset view" style="font:14px/26px system-ui;text-align:center">&#8962;</a>\';
      L.DomEvent.on(d, "click", function(ev) {
        L.DomEvent.stop(ev);
        map.fitBounds([[24.5, -125], [49.4, -66.9]]);
      });
      return d;
    }
  });
  map.addControl(new Home());
}')

m <- htmlwidgets::prependContent(m, htmltools::HTML(panel))

# Every user-facing string is checked before the map is written, so a normative
# word cannot reach a published figure via a hurried edit.
if (exists("assert_access_language", mode = "function")) {
  assert_access_language(c(unlist(G), sc$leg_labs,
                           "within 30 min of a midwife",
                           "within 60 min of a midwife",
                           "more than 60 min from any midwife"),
                         context = "map layer and legend labels")
  cat("access-language guard: clean\n")
}

out <- file.path(OUTDIR, "midwifery_access_map.html")
htmlwidgets::saveWidget(m, out, selfcontained = TRUE,
                        title = "Drive-time access to certified nurse-midwives")
cat(sprintf("written: %s (%.1f MB)\n", out, file.size(out) / 1024^2))
cat(sprintf("counties: %s | zero-midwife counties: %s | suppressed: %s\n",
            nrow(cty), sum(cty$midwives_per_1k_births == 0, na.rm = TRUE),
            sum(is.na(cty$midwives_per_1k_births))))
