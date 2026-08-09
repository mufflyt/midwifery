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
# Everything this map needs now lives in the installed mysterymaps package;
# the path dependency on the isochrones staging file is gone.
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

sc <- mysterymaps_jenks_zero_scale(cty$midwives_per_1k_births, k = 6, digits = 1)
# Caller-side wording only: the canonical zero label is "0.0", and for this map
# the distinction between "no midwife" and "a low rate" is the whole point.
sc$leg_labs[1] <- "none"

# --- labels ------------------------------------------------------------------
fmt <- function(x) ifelse(is.na(x), "—", format(round(x), big.mark = ","))
rate_txt <- ifelse(
  is.na(cty$midwives_per_1k_births),
  "<span style='color:#888'>rate suppressed (&lt;50 births)</span>",
  sprintf("<b>%s</b> per 1,000 births", cty$midwives_per_1k_births))
# Counts agree with their nouns via the canonical helper: "1 midwives" was
# showing on every single-provider county, which is most of the rural ones.
# The Rural-Urban Continuum Code line is gone -- it named a federal
# classification the popup never explains, and the place-type is already the
# first thing the click-through paragraph says.
lab <- sprintf(
  "<div style='font:12px/1.5 system-ui,sans-serif'><b>%s, %s</b><br/>
   %s<br/>%s &nbsp;&middot;&nbsp; %s<br/>%s per year</div>",
  cty$county_name_base, cty$state, rate_txt,
  mysterymaps_pluralize(cty$study_midwives, "midwife", "midwives"),
  mysterymaps_pluralize(cty$ahrf_obgyn, "OB/GYN", "OB/GYNs"),
  mysterymaps_pluralize(cty$births_used, "birth")) %>% lapply(htmltools::HTML)

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

# The whole assembly is now one call to the canonical template
# (mysterymaps_county_access_map). It owns the choropleth, the zero-aware
# scale, the county mesh, the base-group legends and switcher, the coverage
# surfaces, the layers control and the CONUS framing. This file supplies data
# and vocabulary only -- an earlier version of it hand-built all of that, and
# the urogyn map hand-built the same thing separately.
cty$.tooltip <- vapply(lab, as.character, character(1))
cty$.popup   <- vapply(pop, as.character, character(1))

m <- mysterymaps_county_access_map(
  counties        = cty,
  value_col       = "midwives_per_1k_births",
  label_col       = ".tooltip",
  popup_col       = ".popup",
  coverage        = stats::setNames(list(c30, c60, gap60), c(G$b30, G$b60, G$gap)),
  coverage_colors = c("#08519c", "#3182bd", "#d94801"),
  coverage_labels = c("within 30 min of a midwife",
                      "within 60 min of a midwife",
                      "more than 60 min from any midwife"),
  coverage_titles = c("Drive-time coverage", "Drive-time coverage", "Coverage gap"),
  points          = NULL,          # dots are added below, with their own popups
  overlay_group   = "Midwife locations",   # never NULL: leaflet labels it "null"
  legend_title    = "Midwives per<br/>1,000 births",
  search          = NULL,          # added after the dots exist
  notes           = NULL,          # this map's notes panel is built below
  bounds          = c(24.5, -125, 49.4, -66.9))

# --- collapsible caveat panel ------------------------------------------------
# Height-capped and collapsed by default so it never covers the map, per the
# urogyn panel convention.
panel <- sprintf('
<style>
 /* bottom:52px clears the Leaflet scale bar, which sits at bottom-left and
    was drawn underneath this panel. */
 #mwnote{position:fixed;bottom:52px;left:14px;z-index:1000;max-width:340px;
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
 <summary>Drive-time access to certified nurse-midwives, 2026 &mdash; notes</summary>
 <div class="bd">
  <p style="margin:.2em 0 .7em"><b>Dissolved coverage surface.</b> Shaded ground lies
   within the stated drive time of at least one active midwife certified by the
   <a href="https://www.amcbmidwife.org/" target="_blank" rel="noopener">American
   Midwifery Certification Board (AMCB)</a> and linked to a primary midwifery
   National Provider Identifier (NPI). Individual practice locations are not
   shown in the surface and cannot be recovered from it.</p>
  <p style="margin:.2em 0 .7em"><b>Coverage:</b> %s km&sup2; within 30 minutes,
   %s km&sup2; within 60 minutes (dissolved from %s and %s source polygons).</p>
  <p style="margin:.2em 0 .7em"><b class="warn">Two routing engines.</b> Drive times
   come from <a href="https://valhalla.github.io/valhalla/" target="_blank"
   rel="noopener">Valhalla</a>: an Amazon Elastic Compute Cloud (EC2) instance
   for locations the canonical isochrone library already covered, and the public
   <a href="https://routing.openstreetmap.de/" target="_blank" rel="noopener">osm.de</a>
   server for the 2,249 midwives it did not. That split is rural-selective by
   construction. Calibration on 88 shared origins found median Intersection over
   Union (IoU) stable across the gradient (30&nbsp;minutes 0.80/0.79/0.78 for
   metropolitan, adjacent and remote counties; 60&nbsp;minutes 0.86/0.85/0.85).
   The 60-minute band is the more defensible of the two.</p>
  <p style="margin:.2em 0 .7em"><b>County shading</b> is midwives per 1,000 births,
   with births from the <a href="https://data.hrsa.gov/topics/health-workforce/ahrf"
   target="_blank" rel="noopener">Area Health Resources File (AHRF)</a> drawing on
   <a href="https://www.cdc.gov/nchs/nvss/births.htm" target="_blank"
   rel="noopener">National Center for Health Statistics (NCHS)</a> natality.
   "None" is its own class &mdash; a county with no midwife is not the low end of
   a scale. Counties under 50 births per year are suppressed rather than shown as
   noisy rates.</p>
  <p style="margin:.2em 0 .7em"><b>"No midwife located" means located, not
   practising.</b> Counts come from the AMCB roster after NPI linkage and
   geocoding; 16,506 of 16,892 roster records (97.7%%) resolved to a county, so
   a county shown with none may still be served &mdash; by a midwife we could
   not place, or by one practising across the county line. Where the
   <a href="https://wonder.cdc.gov/natality.html" target="_blank" rel="noopener">Centers
   for Disease Control and Prevention (CDC)</a> reports midwife-attended births
   in a county with no located midwife, the popup shows both; that contrast is
   real and worth reading.</p>
  <p style="margin:.2em 0 .7em"><b>Midwife dots</b> show every active,
   AMCB-certified, primary-linked midwife with a geocoded practice address
   (11,792). Click for the NPI and its
   <a href="https://npiregistry.cms.hhs.gov/" target="_blank" rel="noopener">National
   Plan and Provider Enumeration System (NPPES)</a> registry page; names appear on
   the dots from zoom&nbsp;9 in, and the search box finds a midwife by name. AMCB
   certification and NPPES are public records. Credentials shown after each name
   are as recorded in NPPES.</p>
  <p style="margin:.2em 0 .7em"><b>CDC publishes county natality</b> only for
   counties of 100,000 or more residents and pools the rest by state, so
   midwife-attended birth counts are unpublished &mdash; not zero &mdash; for most
   rural counties. County profiles name a CDC count only where one exists.</p>
  <p style="margin:.2em 0 .7em"><b>Data as of 2026</b>, the year the AMCB roster was
   retrieved. Sources carry their own vintages:</p>
  <ul style="margin:.2em 0 .7em;padding-left:1.1em">
   <li>AMCB certification roster &mdash; retrieved 6 August 2026; certifications
    through December 2025</li>
   <li>NPPES / NPI registry &mdash; 2026</li>
   <li><a href="https://www.census.gov/programs-surveys/acs" target="_blank"
    rel="noopener">American Community Survey (ACS)</a> 5-year estimates &mdash;
    2019&ndash;2023</li>
   <li>CDC natality (midwife-attended births) &mdash; 2016&ndash;2024</li>
   <li>AHRF / NCHS births &mdash; 2023</li>
   <li><a href="https://www.ers.usda.gov/data-products/rural-urban-continuum-codes/"
    target="_blank" rel="noopener">United States Department of Agriculture (USDA)
    Rural-Urban Continuum Codes</a> &mdash; 2023</li>
   <li><a href="https://www.atsdr.cdc.gov/place-health/php/svi/" target="_blank"
    rel="noopener">CDC/ATSDR Social Vulnerability Index (SVI)</a> &mdash; 2022</li>
   <li><a href="https://www.countyhealthrankings.org/" target="_blank"
    rel="noopener">County Health Rankings</a> &mdash; 2025</li>
   <li><a href="https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/provider-of-services-file-hospital-non-hospital-facilities"
    target="_blank" rel="noopener">Centers for Medicare &amp; Medicaid Services
    (CMS) Provider of Services</a> file &mdash; 2025</li>
   <li><a href="https://www.census.gov/geographies/mapping-files/time-series/geo/tiger-line-file.html"
    target="_blank" rel="noopener">Census TIGER/Line</a> county boundaries &mdash; 2023</li>
   <li><a href="https://www.openstreetmap.org/" target="_blank"
    rel="noopener">OpenStreetMap (OSM)</a> road network via Valhalla &mdash;
    tileset 24 April 2026</li>
  </ul>
  <p style="margin:.2em 0 0"><b>Scope:</b> 30/60&nbsp;min only (no 120/180 polygons
   were generated). Continental US shown; Alaska and Hawaii are excluded from
   this view but retained in the underlying data.</p>
 </div>
</details>',
  format(round(u30$area_km2), big.mark = ","),
  format(round(u60$area_km2), big.mark = ","),
  format(u30$n_origins_dissolved, big.mark = ","),
  format(u60$n_origins_dissolved, big.mark = ","))

# --- gate: every midwife must fall inside their own coverage -----------------
# A midwife is within 30 minutes of herself, so any who fall outside the
# dissolved surface are midwives whose isochrone was never generated. That
# failure is silent -- it removes shading rather than raising anything -- and
# it is currently REGIONAL (Missouri, Iowa, Kansas), so it biases the coverage
# gap toward the rural interior this map exists to describe.
#
# Reported, not fatal, until the missing isochrones are generated: erroring here
# would block the map entirely on a defect it is the map's job to reveal.
{
  gate_pts <- {
    l <- read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE,
                  progress = FALSE)
    c0 <- read_csv("midwives_panel_geocoded_enhanced.csv", show_col_types = FALSE,
                   progress = FALSE)
    l %>% filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
      distinct(certification_number, .keep_all = TRUE) %>%
      left_join(c0 %>% select(certification_number, latitude, longitude, practice_state),
                by = "certification_number") %>%
      filter(!is.na(latitude), !is.na(longitude)) %>%
      sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326)
  }
  mysterymaps_gate_provider_coverage(gate_pts, c30, label = "30-minute surface",
                                     group_col = "practice_state",
                                     on_fail = "warn")
}

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

  # Credentials from NPPES, canonicalised by the mysterymaps helper: the raw
  # text holds CNM, C.N.M., RN, CNM and APRN-CNM for what is often one
  # credential. Joined on NPI, which is the only key both sides share.
  creds <- readr::read_csv("artifacts/midwife_panel_midwifeonly.csv",
                           show_col_types = FALSE, progress = FALSE) %>%
    distinct(npi, .keep_all = TRUE) %>%
    transmute(npi = as.character(npi),
              cred_disp = mysterymaps_format_credentials(credential))
  mw <- mw %>% mutate(npi = as.character(npi)) %>%
    left_join(creds, by = "npi", relationship = "one-to-one")
  cat(sprintf("midwives with a displayable credential: %s of %s\n",
              sum(!is.na(mw$cred_disp)), nrow(mw)))

  base_name <- str_squish(paste(mw$first_name,
                                coalesce(mw$middle_name, ""), mw$last_name))
  # "Sharon Leann Beatrice Hendricks, CNM"
  full_name <- ifelse(is.na(mw$cred_disp), base_name,
                      paste0(base_name, ", ", mw$cred_disp))
  # NPPES provider-view is the public CMS registry page keyed by NPI.
  npi_link <- ifelse(
    is.na(mw$npi), "<em>no NPI linked</em>",
    sprintf('<a href="https://npiregistry.cms.hhs.gov/provider-view/%s" target="_blank" rel="noopener">%s</a>',
            mw$npi, mw$npi))
  # City comes from NPPES in all caps ("EADS"); title-cased for display by the
  # canonical helper, which keeps the state code upper and does not turn
  # MCALLEN into Mcallen. "ACTIVE" is dropped: every dot on this map is an
  # active certificant by construction, so the word carried no information.
  mw_pop <- sprintf(
    "<div style='font:13px/1.6 system-ui,sans-serif'>
     <div style='font-weight:600'>%s</div>
     <div>National Provider Identifier (NPI): %s</div>
     <div style='color:#666'>%s</div>
     <div style='color:#666;font-size:11px;margin-top:.4em'>AMCB certificate %s</div>
     </div>",
    full_name, npi_link,
    mysterymaps_place_title_case(
      paste0(coalesce(mw$practice_city, "\u2014"), ", ",
             coalesce(mw$practice_state, "\u2014"))),
    mw$certification_number)

  # NO CLUSTERING. Cluster bubbles replace the data with a count and force the
  # reader to zoom repeatedly to learn anything; every dot is drawn.
  # Names are attached as permanent tooltips, but only from zoom 9 up -- 11,792
  # labels at national zoom is unreadable ink, so the JS below adds and removes
  # the label layer on zoomend.
  mw$full_name <- full_name
  m <- m %>% leaflet::addCircleMarkers(
    data = mw, lng = ~longitude, lat = ~latitude,
    # Alpha matters at national zoom: 11,792 opaque dots read as a solid mass
    # over the metros and hide the choropleth beneath them.
    radius = 4, stroke = TRUE, weight = 0.8, color = "#ffffff",
    fillColor = "#c2185b", fillOpacity = 0.55, opacity = 0.7,
    popup = mw_pop,
    label = ~full_name,
    labelOptions = leaflet::labelOptions(
      direction = "right", offset = c(6, 0), textsize = "11px",
      className = "mw-name", opacity = 0.95),
    # NO custom pane. A separate high-zIndex pane gives the markers their own
    # canvas element covering the whole map, and that element swallows every
    # click -- including clicks on empty ground, where no dot is drawn. County
    # popups existed in the HTML for all 3,109 counties and simply never
    # opened. Sharing the map's single canvas renderer (preferCanvas = TRUE)
    # lets Leaflet hit-test markers and polygons together: a click on a dot
    # hits the dot, a click on bare county hits the county.
    group = "Midwife locations")
}

# --- interaction --------------------------------------------------------------
# Both handlers are canonical (mysterymaps): legends keyed to BASE groups, and
# point labels gated by zoom instead of hidden behind cluster bubbles. An
# earlier draft of this file hand-rolled both.
m <- mysterymaps_zoom_gated_labels(m, group = "Midwife locations",
                          min_zoom = 9, max_labels = 400)

# Name search from the canonical control (mysterymaps_name_search) rather than
# a local copy of the same plugin bootstrap. The CDN trade-off -- map opens
# offline, search box needs network -- is documented on that function.
m <- mysterymaps_name_search(m, placeholder = "Search midwife name\u2026", zoom = 11)

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
                        title = "Drive-time access to certified nurse-midwives, 2026")
cat(sprintf("written: %s (%.1f MB)\n", out, file.size(out) / 1024^2))
cat(sprintf("counties: %s | zero-midwife counties: %s | suppressed: %s\n",
            nrow(cty), sum(cty$midwives_per_1k_births == 0, na.rm = TRUE),
            sum(is.na(cty$midwives_per_1k_births))))
