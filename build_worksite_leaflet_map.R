#!/usr/bin/env Rscript

# Internal map of distinct physical work sites and the midwives associated
# with each site. Exact addresses plus names are intentionally kept in qa/.

suppressPackageStartupMessages({
  library(dplyr)
  library(htmltools)
  library(leaflet)
  library(mysterymaps)
  library(readr)
  library(stringr)
})
source(file.path("R", "lib", "worksite_text_helpers.R"))

ART <- "artifacts"
OUT <- "qa/leaflet_work_sites_INTERNAL.html"
dir.create(dirname(OUT), recursive = TRUE, showWarnings = FALSE)

long <- read_csv(file.path(ART, "midwife_work_sites_long.csv"),
                 show_col_types = FALSE, progress = FALSE) %>%
  mutate(
    certification_number = as.character(certification_number),
    site_id = na_if(str_squish(as.character(site_id)), "")
  )
cohort <- read_csv(file.path(ART, "amcb_npi_linkage_FROZEN.csv"),
                   col_select = c(certification_number, first_name, last_name),
                   show_col_types = FALSE, progress = FALSE) %>%
  transmute(
    certification_number = as.character(certification_number),
    first_name = coalesce(first_name, ""),
    last_name = coalesce(last_name, "")
  ) %>%
  distinct(certification_number, .keep_all = TRUE)

esc <- function(x) htmlEscape(ifelse(is.na(x), "", as.character(x)))

# Exact provider-location to NPPES Type-2 organization matches. These names
# identify an organization associated with the address; they are not treated
# as proof that the organization employs the midwife.
nppes_org <- if (file.exists(file.path(ART, "midwife_org_person.csv"))) {
  read_csv(file.path(ART, "midwife_org_person.csv"),
           show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      certification_number = as.character(certification_number),
      loc_type,
      nppes_org_name = organization_name
    ) %>%
    group_by(certification_number, loc_type) %>%
    summarise(nppes_org_name = collapse_unique(nppes_org_name), .groups = "drop")
} else {
  tibble(certification_number = character(), loc_type = character(),
         nppes_org_name = character())
}
resolution <- if (file.exists(file.path(ART, "worksite_address_resolution.csv"))) {
  read_csv(file.path(ART, "worksite_address_resolution.csv"),
           col_types = cols(.default = col_character()),
           show_col_types = FALSE, progress = FALSE) %>%
    select(site_id, resolved_site_name, resolution_source, parent_organization,
           resolved_site_setting, setting_source)
} else {
  tibble(site_id = character(), resolved_site_name = character(),
         resolution_source = character(), parent_organization = character(),
         resolved_site_setting = character(), setting_source = character())
}
setting_crosswalk <- if (file.exists(file.path(ART, "worksite_address_setting_best_match.csv"))) {
  read_csv(file.path(ART, "worksite_address_setting_best_match.csv"),
           col_types = cols(.default = col_character()),
           show_col_types = FALSE, progress = FALSE) %>%
    transmute(site_id = as.character(site_id),
              facility_match_names = matched_names,
              crosswalk_setting = best_setting,
              crosswalk_settings = matched_settings,
              crosswalk_sources = matched_sources)
} else {
  tibble(site_id = character(), facility_match_names = character(),
         crosswalk_setting = character(), crosswalk_settings = character(),
         crosswalk_sources = character())
}

site_rows <- long %>%
  filter(!is.na(site_id), is.finite(lat), is.finite(lon)) %>%
  left_join(cohort, by = "certification_number") %>%
  mutate(loc_type = case_when(
    str_starts(source, "nppes_") ~ str_remove(str_remove(source, "^nppes_"), "_location$"),
    TRUE ~ NA_character_
  )) %>%
  left_join(nppes_org, by = c("certification_number", "loc_type")) %>%
  left_join(resolution, by = "site_id") %>%
  left_join(setting_crosswalk, by = "site_id") %>%
  mutate(
    midwife_name = str_squish(paste(first_name, last_name)),
    midwife_name = if_else(midwife_name == "", certification_number, midwife_name)
  )

site_map <- site_rows %>%
  group_by(site_id) %>%
  summarise(
    lat = first(lat[is.finite(lat)]),
    lon = first(lon[is.finite(lon)]),
    street = first_nonempty(street),
    city = first_nonempty(city),
    state = first_nonempty(state),
    zip5 = first_nonempty(zip5),
    site_name = first_nonempty(site_name),
    organization = first_nonempty(matched_org_name),
    hospital_name = first_nonempty(addr_hospital_name),
    birth_center_name = first_nonempty(addr_birth_center_name),
    nppes_organization = first_nonempty(nppes_org_name),
    resolved_name = first_nonempty(resolved_site_name),
    resolved_source = first_nonempty(resolution_source),
    resolved_parent = first_nonempty(parent_organization),
    resolved_setting = first_nonempty(resolved_site_setting),
    resolved_setting_source = first_nonempty(setting_source),
    facility_match_names = first_nonempty(facility_match_names),
    crosswalk_setting = first_nonempty(crosswalk_setting),
    crosswalk_settings = first_nonempty(crosswalk_settings),
    crosswalk_sources = first_nonempty(crosswalk_sources),
    facility_type = collapse_unique(facility_type),
    sources = collapse_unique(source),
    n_midwives = n_distinct(certification_number),
    midwives = paste(sort(unique(midwife_name)), collapse = "; "),
    midwives_html = paste(sort(unique(esc(midwife_name))), collapse = "<br>"),
    .groups = "drop"
  ) %>%
  mutate(
    setting = coalesce(crosswalk_setting, resolved_setting, case_when(
      str_detect(coalesce(facility_type, ""), "hospital") ~ "Hospital",
      str_detect(coalesce(facility_type, ""), "birth_center") ~ "Birth center",
      str_detect(coalesce(facility_type, ""), "fqhc") ~ "FQHC/community health",
      str_detect(coalesce(facility_type, ""), "clinic") ~ "Clinic/practice",
      TRUE ~ "Other/unclassified"
    )),
    setting_source = case_when(
      !is.na(crosswalk_setting) ~ paste0("Facility setting crosswalk: ", crosswalk_sources),
      !is.na(resolved_setting) ~ resolved_setting_source,
      TRUE ~ "Facility-type fallback"
    ),
    site_label = case_when(
      !is.na(site_name) ~ site_name,
      !is.na(facility_match_names) ~ facility_match_names,
      !is.na(organization) ~ organization,
      !is.na(hospital_name) ~ hospital_name,
      !is.na(birth_center_name) ~ birth_center_name,
      !is.na(nppes_organization) ~ nppes_organization,
      !is.na(resolved_name) ~ resolved_name,
      TRUE ~ "Unnamed work site"
    ),
    name_source = case_when(
      !is.na(site_name) ~ "Trilliant/site directory",
      !is.na(facility_match_names) ~ "Facility setting crosswalk",
      !is.na(organization) ~ "Organization-directory match",
      !is.na(hospital_name) ~ "Hospital-at-address evidence",
      !is.na(birth_center_name) ~ "Birth-center-at-address evidence",
      !is.na(nppes_organization) ~ "NPPES Type-2 organization at provider address",
      !is.na(resolved_name) ~ resolved_source,
      TRUE ~ "No organization name resolved"
    ),
    geographic_name_evidence = str_squish(paste(
      coalesce(site_name, ""), coalesce(organization, ""),
      coalesce(hospital_name, ""), coalesce(birth_center_name, ""),
      coalesce(nppes_organization, ""), coalesce(resolved_name, ""),
      coalesce(facility_match_names, "")
    )),
    geographic_conflict = case_when(
      str_detect(geographic_name_evidence, regex("\\bGUAM\\b", ignore_case = TRUE)) & state != "GU" ~ TRUE,
      str_detect(geographic_name_evidence, regex("PUERTO RICO", ignore_case = TRUE)) & state != "PR" ~ TRUE,
      str_detect(geographic_name_evidence, regex("AMERICAN SAMOA", ignore_case = TRUE)) & state != "AS" ~ TRUE,
      str_detect(geographic_name_evidence, regex("NORTHERN MARIANA", ignore_case = TRUE)) & state != "MP" ~ TRUE,
      str_detect(geographic_name_evidence, regex("U\\.?S\\.? VIRGIN", ignore_case = TRUE)) & state != "VI" ~ TRUE,
      TRUE ~ FALSE
    ),
    geographic_conflict_detail = case_when(
      geographic_conflict & str_detect(geographic_name_evidence, regex("\\bGUAM\\b", ignore_case = TRUE)) ~ paste0("Name suggests Guam; address is ", state),
      geographic_conflict & str_detect(geographic_name_evidence, regex("PUERTO RICO", ignore_case = TRUE)) ~ paste0("Name suggests Puerto Rico; address is ", state),
      geographic_conflict & str_detect(geographic_name_evidence, regex("AMERICAN SAMOA", ignore_case = TRUE)) ~ paste0("Name suggests American Samoa; address is ", state),
      geographic_conflict & str_detect(geographic_name_evidence, regex("NORTHERN MARIANA", ignore_case = TRUE)) ~ paste0("Name suggests Northern Mariana Islands; address is ", state),
      geographic_conflict ~ paste0("Organization geography conflicts with address state ", state),
      TRUE ~ NA_character_
    ),
    address = str_squish(paste(
      coalesce(street, ""),
      coalesce(city, ""),
      coalesce(state, ""),
      coalesce(zip5, "")
    )),
    popup = paste0(
      "<div style='font:13px/1.45 system-ui,sans-serif;max-width:360px'>",
      "<div style='font-size:15px;font-weight:700;margin-bottom:4px'>", esc(site_label), "</div>",
      "<div>", esc(address), "</div>",
      "<div style='margin-top:7px'><b>", n_midwives,
      ifelse(n_midwives == 1, " midwife", " midwives"), " associated with this site</b></div>",
      "<div style='margin-top:4px;max-height:220px;overflow:auto'>", midwives_html, "</div>",
      "<div style='color:#666;font-size:11px;margin-top:7px'>Setting: ", esc(setting),
      ifelse(geographic_conflict, paste0("<br><b style='color:#b91c1c'>Geographic conflict: ", esc(geographic_conflict_detail), "</b>"), ""),
      ifelse(!is.na(facility_match_names), paste0("<br>Matched facility names: ", esc(facility_match_names)), ""),
      ifelse(!is.na(crosswalk_sources), paste0("<br>Facility sources: ", esc(crosswalk_sources)), ""),
      "<br>Name source: ", esc(name_source),
      "<br>Setting source: ", esc(setting_source),
      ifelse(!is.na(resolved_parent), paste0("<br>Parent organization: ", esc(resolved_parent)), ""),
      "<br>Evidence rows: ", esc(sources), "</div>",
      "</div>"
    ),
    label = paste0(site_label, " | ", n_midwives, " midwife",
                   ifelse(n_midwives == 1, "", "s"), " | ", midwives)
  )

stopifnot(nrow(site_map) > 0L)
stopifnot(all(is.finite(site_map$lat), is.finite(site_map$lon)))

colors <- c(
  "Hospital" = "#2B6CB0",
  "Clinic/practice" = "#D97706",
  "FQHC/community health" = "#2F855A",
  "Birth center" = "#805AD5",
  "Other facility" = "#C53030",
  "Other/unclassified" = "#718096"
)

# mysterymaps_map_base() adds providers that may require a Carto API key and an
# OpenStreetMap fallback. Use Esri's public street tiles here instead, so the
# saved widget has neither dependency.
m <- leaflet(options = leafletOptions(zoomControl = TRUE)) %>%
  addProviderTiles("Esri.WorldStreetMap", group = "Esri World Street Map") %>%
  addProviderTiles("Esri.WorldTopoMap", group = "Esri World Topographic Map") %>%
  addScaleBar(position = "bottomleft") %>%
  addLayersControl(
    baseGroups = c("Esri World Street Map", "Esri World Topographic Map"),
    options = layersControlOptions(collapsed = FALSE)
  ) %>%
  setView(lat = 39.8282, lng = -98.5795, zoom = 4) %>%
  addControl(
    html = HTML("<div class='mysterycall-map-title'>Midwifery work sites and associated midwives</div>"),
    position = "topleft"
  ) %>%
  addCircleMarkers(
    data = site_map,
    lng = ~lon, lat = ~lat,
    radius = ~pmin(12, 4 + sqrt(n_midwives) * 2),
    stroke = TRUE, weight = 0.8, color = "#ffffff",
    fillColor = ~unname(colors[setting]), fillOpacity = 0.72,
    popup = ~popup, label = ~label,
    group = "Work sites",
    clusterOptions = markerClusterOptions(disableClusteringAtZoom = 11)
  ) %>%
  addLegend(
    position = "bottomright", colors = unname(colors),
    labels = names(colors), title = "Site setting", opacity = 0.8
  ) %>%
  mysterymaps_name_search(
    group = "Work sites",
    placeholder = "Search midwife or work site",
    zoom = 12L
  ) %>%
  addControl(
    html = HTML(paste0(
      "<div style='background:rgba(255,255,255,.94);padding:8px 10px;",
      "font:12px/1.35 system-ui,sans-serif;max-width:310px;box-shadow:0 1px 5px rgba(0,0,0,.3)'>",
      "<b>Internal QA map</b><br>", format(nrow(site_map), big.mark = ","),
      " distinct physical sites; popup lists associated midwives. Exact addresses and names are included.",
      "</div>"
    )),
    position = "topright"
  )

htmlwidgets::saveWidget(m, OUT, selfcontained = TRUE)
cat(sprintf("Wrote %s (%s sites, %s midwife-site rows)\n",
            OUT, format(nrow(site_map), big.mark = ","),
            format(nrow(site_rows), big.mark = ",")))
cat("Name sources:\n")
print(site_map %>% count(name_source, sort = TRUE), n = Inf)
