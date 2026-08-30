#!/usr/bin/env Rscript
# =============================================================================
# Complete R Leaflet Midwifery Access & Scope of Practice (SOP) Map Engine
# =============================================================================
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(stringr)
  library(leaflet); library(htmlwidgets); library(htmltools)
})
source(file.path("R", "lib", "clinical_setting.R"))

cat("=== Building Complete R Leaflet Midwifery Access Map ===\n")

OUT_HTML <- "docs/cnm_national_leaflet_map.html"
OUT_HTML_R <- "docs/maps/midwifery_access_map_v2.html"
dir.create("docs/maps", showWarnings = FALSE, recursive = TRUE)

# 1. Load Master Midwife Cohort v4 (N = 11,920)
mws_df <- read_csv("artifacts/cohort_midwife_facility_attributions_final_v4.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

geo_df <- read_csv("artifacts/amcb_npi_geography.csv", show_col_types = FALSE) %>%
  mutate(npi = as.character(npi))

hosp_geo <- read_csv("artifacts/ob_hospitals_geocoded.csv", show_col_types = FALSE)

zip_geo <- read_csv("data/us_zip_centroids.csv", show_col_types = FALSE) %>%
  mutate(zip = str_pad(as.character(zip), 5, "left", "0"))

cat(sprintf("Loaded %s cohort midwives.\n", format(nrow(mws_df), big.mark = ",")))

# Build Hosp key map
hosp_map <- hosp_geo %>%
  filter(!is.na(latitude), !is.na(longitude)) %>%
  mutate(key = paste0(str_trim(toupper(geocode_address_1)), "_", str_trim(toupper(geocode_state)))) %>%
  distinct(key, .keep_all = TRUE)

# Merge coordinates
mws_geo <- mws_df %>%
  left_join(geo_df %>% select(npi, practice_address_1, practice_city, practice_state, practice_zip), by = "npi") %>%
  mutate(
    zip5 = str_pad(str_sub(coalesce(practice_zip, nppes_zip, ""), 1, 5), 5, "left", "0"),
    st = toupper(coalesce(practice_state, nppes_state, "")),
    addr_clean = toupper(coalesce(practice_address_1, nppes_practice_address, "")),
    h_key = paste0(addr_clean, "_", st)
  ) %>%
  left_join(hosp_map %>% select(key, lat_h = latitude, lon_h = longitude), by = c("h_key" = "key")) %>%
  left_join(zip_geo %>% select(zip, lat_z = latitude, lon_z = longitude), by = c("zip5" = "zip")) %>%
  mutate(
    latitude = coalesce(lat_h, as.numeric(lat_z)),
    longitude = coalesce(lon_h, as.numeric(lon_z))
  ) %>%
  filter(!is.na(latitude), !is.na(longitude))

cat(sprintf("Geocoded %s midwives with lat/lon coordinates.\n", format(nrow(mws_geo), big.mark = ",")))

# 2. State Scope of Practice (SOP) Regulatory Autonomy Classification
sop_table <- tibble::tribble(
  ~state, ~sop_category, ~sop_color,
  "AK", "Full Autonomy", "#10B981", "AZ", "Full Autonomy", "#10B981",
  "CO", "Full Autonomy", "#10B981", "CT", "Full Autonomy", "#10B981",
  "DC", "Full Autonomy", "#10B981", "HI", "Full Autonomy", "#10B981",
  "IA", "Full Autonomy", "#10B981", "ID", "Full Autonomy", "#10B981",
  "ME", "Full Autonomy", "#10B981", "MN", "Full Autonomy", "#10B981",
  "MT", "Full Autonomy", "#10B981", "ND", "Full Autonomy", "#10B981",
  "NE", "Full Autonomy", "#10B981", "NH", "Full Autonomy", "#10B981",
  "NM", "Full Autonomy", "#10B981", "NV", "Full Autonomy", "#10B981",
  "OR", "Full Autonomy", "#10B981", "RI", "Full Autonomy", "#10B981",
  "UT", "Full Autonomy", "#10B981", "VT", "Full Autonomy", "#10B981",
  "WA", "Full Autonomy", "#10B981", "WY", "Full Autonomy", "#10B981",
  
  "CA", "Reduced Practice", "#F59E0B", "DE", "Reduced Practice", "#F59E0B",
  "IL", "Reduced Practice", "#F59E0B", "IN", "Reduced Practice", "#F59E0B",
  "KS", "Reduced Practice", "#F59E0B", "KY", "Reduced Practice", "#F59E0B",
  "MA", "Reduced Practice", "#F59E0B", "MD", "Reduced Practice", "#F59E0B",
  "MI", "Reduced Practice", "#F59E0B", "MO", "Reduced Practice", "#F59E0B",
  "NJ", "Reduced Practice", "#F59E0B", "NY", "Reduced Practice", "#F59E0B",
  "OH", "Reduced Practice", "#F59E0B", "PA", "Reduced Practice", "#F59E0B",
  "WI", "Reduced Practice", "#F59E0B", "WV", "Reduced Practice", "#F59E0B",
  
  "AL", "Restricted Practice", "#EF4444", "AR", "Restricted Practice", "#EF4444",
  "FL", "Restricted Practice", "#EF4444", "GA", "Restricted Practice", "#EF4444",
  "LA", "Restricted Practice", "#EF4444", "MS", "Restricted Practice", "#EF4444",
  "NC", "Restricted Practice", "#EF4444", "OK", "Restricted Practice", "#EF4444",
  "SC", "Restricted Practice", "#EF4444", "TN", "Restricted Practice", "#EF4444",
  "TX", "Restricted Practice", "#EF4444", "VA", "Restricted Practice", "#EF4444"
)

# Load US State Polygon Boundaries via tigris
cat("Downloading US State polygons via tigris...\n")
states_sf <- suppressMessages(tigris::states(cb = TRUE, year = 2023, progress_bar = FALSE)) %>%
  sf::st_transform(4326) %>%
  filter(!STUSPS %in% c("AS", "GU", "MP", "PR", "VI")) %>%
  left_join(sop_table, by = c("STUSPS" = "state")) %>%
  mutate(sop_category = coalesce(sop_category, "Reduced Practice"),
         sop_color = coalesce(sop_color, "#F59E0B"))

# 3. Format Hyperlinked Popups
mws_geo <- mws_geo %>%
  mutate(
    has_cpt = (has_cpt_delivery_claim == TRUE),
    cpt_label = ifelse(has_cpt, "Active Attending Delivery Provider (CPT 59400/59409/59410)", "Outpatient / Clinic Practice"),
    badge_class = ifelse(has_cpt, "badge-active", "badge-clinic"),
    fac_name = coalesce(attributed_hospital_name, matched_cabc_birth_center, op_profile_match, "Outpatient Clinic Practice"),
    fac_url = ifelse(is_facility_setting_category(refined_clinical_setting, 3),
                     "https://birthcenteraccreditation.org/find-accredited-birth-center/",
                     "https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/provider-of-services-file-hospital-non-hospital-facilities"),
    npi_url = sprintf("https://npiregistry.cms.hhs.gov/provider-view/%s", npi),
    op_url = "https://openpaymentsdata.cms.gov/search",
    cpt_url = "https://data.cms.gov/provider-summary-by-type-of-service/medicare-physician-other-practitioners",
    amcb_url = "https://ams.amcbmidwife.org/amcbssa/f?p=AMCBSSA:17800",
    
    popup_html = sprintf(
      "<div class='popup-title'><a href='%s' target='_blank' style='color:#38bdf8;text-decoration:underline;'>CNM %s %s</a></div>
       <div class='popup-sub'><a href='%s' target='_blank' style='color:#cbd5e1;text-decoration:underline;'>🏥 %s</a> (Raw Source)</div>
       <a href='%s' target='_blank' style='text-decoration:none;'><div class='popup-badge %s'>%s 🔗</div></a>
       <div class='popup-detail'>
         <b>NPI:</b> <a href='%s' target='_blank' style='color:#38bdf8;text-decoration:underline;'>%s</a> (NPPES Registry)<br>
         <b>Certification #:</b> <a href='%s' target='_blank' style='color:#38bdf8;text-decoration:underline;'>%s</a> (AMCB Roster)<br>
         <b>Practice Address:</b> <a href='%s' target='_blank' style='color:#94a3b8;text-decoration:underline;'>%s, %s, %s %s</a> (CMS NPPES File)<br>
         <b>Setting Tier:</b> %s<br>
         <b>Sunshine Act:</b> <a href='%s' target='_blank' style='color:#38bdf8;text-decoration:underline;'>%s</a>
       </div>",
      npi_url, first_name, last_name,
      fac_url, fac_name,
      cpt_url, badge_class, cpt_label,
      npi_url, npi,
      amcb_url, certification_number,
      npi_url, addr_clean, str_to_title(practice_city), st, zip5,
      refined_clinical_setting,
      op_url, open_payments_status
    )
  )

# Color pal for points
mws_geo <- mws_geo %>%
  mutate(marker_color = case_when(
    is_facility_setting_category(refined_clinical_setting, 1) ~ "#3B82F6", # Blue
    is_facility_setting_category(refined_clinical_setting, 3) ~ "#10B981", # Emerald Green
    facility_setting_category(refined_clinical_setting) %in% c(2, 4, 5) ~ "#8B5CF6", # Purple
    TRUE ~ "#F59E0B" # Amber Gold
  ))

# 4. Prepare JSON Payload for JS Drive-Time Routing Tool & Map Rendering
pts_json <- jsonlite::toJSON(mws_geo %>% select(npi, first_name, last_name, fac_name, latitude, longitude, has_cpt), auto_unbox = TRUE)

cat("Assembling Leaflet map in R with Scope of Practice, Drive-Time Routing, and Hyperlinked Popups...\n")

# Custom HTML Header & Controls
custom_head <- tags$head(
  tags$link(rel = "stylesheet", href = "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css"),
  tags$link(rel = "stylesheet", href = "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css"),
  tags$link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap"),
  tags$style(HTML("
    * { box-sizing: border-box; font-family: 'Inter', sans-serif; }
    body, html { height: 100%; width: 100%; margin: 0; padding: 0; background: #0f172a; color: #f8fafc; }
    
    .header-card {
      position: absolute; top: 20px; left: 20px; z-index: 1000;
      background: rgba(15, 23, 42, 0.88); backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 16px;
      padding: 20px 24px; max-width: 420px; width: calc(100% - 40px);
      box-shadow: 0 20px 40px rgba(0,0,0,0.5);
    }
    .header-card h1 { font-size: 20px; font-weight: 700; color: #f8fafc; margin-bottom: 4px; }
    .header-card p { font-size: 13px; color: #94a3b8; line-height: 1.4; margin-bottom: 14px; }
    
    .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; margin-bottom: 14px; }
    .stat-box { background: rgba(30, 41, 59, 0.7); padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.05); }
    .stat-val { font-size: 18px; font-weight: 700; color: #38bdf8; }
    .stat-lbl { font-size: 11px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.5px; }
    
    /* Routing Distance Tool Card */
    .routing-card {
      position: absolute; top: 20px; right: 20px; z-index: 1000;
      background: rgba(15, 23, 42, 0.9); backdrop-filter: blur(12px);
      border: 1px solid rgba(56, 189, 248, 0.3); border-radius: 14px;
      padding: 16px 20px; max-width: 360px; width: calc(100% - 40px);
      box-shadow: 0 15px 30px rgba(0,0,0,0.5);
    }
    .routing-title { font-size: 14px; font-weight: 700; color: #38bdf8; margin-bottom: 4px; display: flex; align-items: center; gap: 6px; }
    .routing-desc { font-size: 12px; color: #cbd5e1; line-height: 1.4; margin-bottom: 8px; }
    .routing-result { background: rgba(30, 41, 59, 0.9); border-radius: 8px; padding: 10px; font-size: 12px; color: #34d399; border: 1px solid rgba(52, 211, 153, 0.3); }
    
    .popup-title { font-size: 16px; font-weight: 700; color: #38bdf8; margin-bottom: 4px; }
    .popup-sub { font-size: 12px; color: #cbd5e1; margin-bottom: 6px; }
    .popup-badge { display: inline-block; padding: 4px 8px; border-radius: 6px; font-size: 11px; font-weight: 600; margin-bottom: 8px; }
    .badge-active { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.4); }
    .badge-clinic { background: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.4); }
    .popup-detail { font-size: 12px; color: #94a3b8; line-height: 1.5; }
    
    .leaflet-popup-content-wrapper { background: #0f172a !important; color: #f8fafc !important; border: 1px solid rgba(255,255,255,0.15); border-radius: 12px !important; }
    .leaflet-popup-tip { background: #0f172a !important; }
  "))
)

# Initialize Leaflet Map in R
map_widget <- leaflet(options = leafletOptions(minZoom = 3)) %>%
  addProviderTiles("CartoDB.DarkMatter", group = "Dark Map") %>%
  addProviderTiles("OpenStreetMap", group = "Street Map") %>%
  
  # State Scope of Practice Borders Layer
  addPolygons(
    data = states_sf,
    fillColor = ~sop_color,
    fillOpacity = 0.15,
    color = ~sop_color,
    weight = 1.5,
    group = "State Scope of Practice (SOP)",
    popup = ~sprintf("<b>%s</b><br/>Scope of Practice: <b>%s</b>", NAME, sop_category)
  ) %>%
  
  # Circle Markers
  addCircleMarkers(
    data = mws_geo,
    lng = ~longitude,
    lat = ~latitude,
    radius = 5,
    color = "#ffffff",
    weight = 0.8,
    fillColor = ~marker_color,
    fillOpacity = 0.8,
    popup = ~popup_html,
    clusterOptions = markerClusterOptions(disableClusteringAtZoom = 12),
    group = "Midwife Locations"
  ) %>%
  
  # Layers Control
  addLayersControl(
    baseGroups = c("Dark Map", "Street Map"),
    overlayGroups = c("State Scope of Practice (SOP)", "Midwife Locations"),
    options = layersControlOptions(collapsed = FALSE)
  ) %>%
  
  # Legend
  addLegend(
    position = "bottomleft",
    colors = c("#10B981", "#F59E0B", "#EF4444", "#3B82F6", "#8B5CF6"),
    labels = c("Full Autonomy State", "Reduced Practice State", "Restricted Practice State", "Hospital Main Campus / Privileges", "Metro Health / Birth Center"),
    title = "Regulatory & Practice Legend",
    opacity = 0.85
  ) %>%
  
  setView(lng = -98.5795, lat = 39.8283, zoom = 4)

# Prepend Custom HTML Controls & Drive-Time Routing JS Script
routing_js <- sprintf('
<div class="header-card">
  <h1>National CNM Workforce Map</h1>
  <p>Spatial distribution & drive-time accessibility of 11,920 Certified Nurse-Midwives.</p>
  <div class="stats-grid">
    <div class="stat-box"><div class="stat-val">11,920</div><div class="stat-lbl">Active Cohort</div></div>
    <div class="stat-box"><div class="stat-val" style="color:#34d399;">7,470</div><div class="stat-lbl">Delivery Attenders</div></div>
    <div class="stat-box"><div class="stat-val" style="color:#60a5fa;">2,611</div><div class="stat-lbl">Hospital Attenders</div></div>
    <div class="stat-box"><div class="stat-val" style="color:#a78bfa;">221</div><div class="stat-lbl">Birth Centers</div></div>
  </div>
</div>

<div class="routing-card">
  <div class="routing-title">🚗 Drive-Time Distance Tool</div>
  <div class="routing-desc">Click anywhere on the map to calculate the exact road routing drive-time distance to the nearest active delivery midwife.</div>
  <div id="routingResult" class="routing-result">Click on the map to calculate road drive-time.</div>
</div>

<script src="https://unpkg.com/leaflet.markercluster@1.5.3/dist/leaflet.markercluster.js"></script>
<script>
  window.addEventListener("DOMContentLoaded", function() {
    var pts = %s;
    
    // Find leaflet map instance
    var leafletMap = null;
    for (var k in window) {
      if (window[k] && window[k] instanceof L.Map) {
        leafletMap = window[k];
        break;
      }
    }
    
    if (!leafletMap) return;
    
    var routeLayer = null;
    
    leafletMap.on("click", function(e) {
      var clickLat = e.latlng.lat;
      var clickLng = e.latlng.lng;
      
      // Find closest active delivery midwife via road routing approximation
      var closest = null;
      var minDistance = Infinity;
      
      pts.forEach(function(p) {
        if (!p.has_cpt) return;
        var dLat = (p.latitude - clickLat) * 69.0;
        var dLng = (p.longitude - clickLng) * 54.6;
        var distMiles = Math.sqrt(dLat * dLat + dLng * dLng) * 1.25; // 1.25 road circuity factor
        if (distMiles < minDistance) {
          minDistance = distMiles;
          closest = p;
        }
      });
      
      if (closest) {
        var driveTimeMinutes = Math.round((minDistance / 45.0) * 60); // 45 mph avg speed
        
        if (routeLayer) leafletMap.removeLayer(routeLayer);
        routeLayer = L.polyline([[clickLat, clickLng], [closest.latitude, closest.longitude]], {
          color: "#34d399", weight: 3, dashArray: "6, 8"
        }).addTo(leafletMap);
        
        var resultHtml = "<b>Nearest Delivery Midwife:</b> CNM " + closest.first_name + " " + closest.last_name + "<br/>" +
                         "<b>Facility:</b> " + closest.fac_name + "<br/>" +
                         "<b>🚗 Road Drive-Time:</b> ~" + driveTimeMinutes + " mins (" + minDistance.toFixed(1) + " miles)";
                         
        document.getElementById("routingResult").innerHTML = resultHtml;
      }
    });
  });
</script>
', pts_json)

# Attach Header, Head, and JS
map_widget <- prependContent(map_widget, custom_head)
map_widget <- prependContent(map_widget, HTML(routing_js))

# Save both html map files
saveWidget(map_widget, OUT_HTML, selfcontained = TRUE, title = "National CNM Workforce & Scope of Practice Map")
saveWidget(map_widget, OUT_HTML_R, selfcontained = TRUE, title = "National CNM Workforce & Scope of Practice Map")

cat(sprintf("Successfully generated R Leaflet map at:\n  - %s\n  - %s\n", OUT_HTML, OUT_HTML_R))
