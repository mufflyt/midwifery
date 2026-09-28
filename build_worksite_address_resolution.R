#!/usr/bin/env Rscript

# Resolve unnamed physical work sites to organization/facility names without
# changing the underlying Trilliant or NPPES fields. Outputs are person-level
# and therefore remain in ignored artifacts/ files.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

ART <- "artifacts"
dir.create(ART, recursive = TRUE, showWarnings = FALSE)

long <- read_csv(file.path(ART, "midwife_work_sites_long.csv"),
                 show_col_types = FALSE, progress = FALSE) %>%
  mutate(
    certification_number = as.character(certification_number),
    site_id = na_if(str_squish(as.character(site_id)), ""),
    loc_type = if_else(
      str_starts(source, "nppes_"),
      str_remove(str_remove(source, "^nppes_"), "_location$"),
      NA_character_
    )
  )

cohort <- read_csv(file.path(ART, "amcb_npi_linkage_FROZEN.csv"),
                   col_select = c(certification_number, first_name, last_name),
                   show_col_types = FALSE, progress = FALSE) %>%
  transmute(
    certification_number = as.character(certification_number),
    midwife_name = str_squish(paste(coalesce(first_name, ""), coalesce(last_name, "")))
  ) %>%
  distinct(certification_number, .keep_all = TRUE)

nonempty <- function(x) !is.na(x) & nzchar(str_squish(as.character(x)))
first_nonempty <- function(x) {
  x <- x[nonempty(x)]
  if (length(x)) x[[1L]] else NA_character_
}
collapse_unique <- function(x) {
  x <- sort(unique(x[nonempty(x)]))
  if (length(x)) paste(x, collapse = "; ") else NA_character_
}
address_key <- function(street, city, state, zip5) {
  str_squish(str_to_upper(paste(street, city, state, zip5)))
}
first_finite <- function(x) {
  x <- x[is.finite(x)]
  if (length(x)) x[[1L]] else NA_real_
}

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

rows <- long %>%
  filter(!is.na(site_id), !is.na(street), nzchar(str_squish(street)),
         !is.na(city), nzchar(str_squish(city)), !is.na(state),
         nzchar(str_squish(state)), !is.na(zip5), nzchar(str_squish(zip5))) %>%
  left_join(cohort, by = "certification_number") %>%
  left_join(nppes_org, by = c("certification_number", "loc_type"))

sites <- rows %>%
  group_by(site_id) %>%
  summarise(
    street = first_nonempty(street), city = first_nonempty(city),
    state = first_nonempty(state), zip5 = first_nonempty(zip5),
    lat = first_finite(lat), lon = first_finite(lon),
    n_midwives = n_distinct(certification_number),
    midwives = collapse_unique(midwife_name),
    trilliant_site_name = first_nonempty(site_name),
    organization_directory_name = first_nonempty(matched_org_name),
    hospital_at_address_name = first_nonempty(addr_hospital_name),
    birth_center_at_address_name = first_nonempty(addr_birth_center_name),
    nppes_type2_name = first_nonempty(nppes_org_name),
    facility_type = collapse_unique(facility_type),
    evidence_rows = collapse_unique(source),
    .groups = "drop"
  ) %>%
  mutate(
    address_key = address_key(street, city, state, zip5),
    resolved_site_name = case_when(
      nonempty(trilliant_site_name) ~ trilliant_site_name,
      nonempty(organization_directory_name) ~ organization_directory_name,
      nonempty(hospital_at_address_name) ~ hospital_at_address_name,
      nonempty(birth_center_at_address_name) ~ birth_center_at_address_name,
      nonempty(nppes_type2_name) ~ nppes_type2_name,
      TRUE ~ NA_character_
    ),
    resolution_source = case_when(
      nonempty(trilliant_site_name) ~ "Trilliant/site directory",
      nonempty(organization_directory_name) ~ "Organization-directory match",
      nonempty(hospital_at_address_name) ~ "Hospital-at-address evidence",
      nonempty(birth_center_at_address_name) ~ "Birth-center-at-address evidence",
      nonempty(nppes_type2_name) ~ "NPPES Type-2 organization at provider address",
      TRUE ~ "No local organization name resolved"
    ),
    confidence = case_when(
      nonempty(trilliant_site_name) | nonempty(organization_directory_name) |
        nonempty(hospital_at_address_name) | nonempty(birth_center_at_address_name) ~ "high",
      nonempty(nppes_type2_name) ~ "moderate",
      TRUE ~ "unresolved"
    ),
    review_status = if_else(confidence == "unresolved", "needs targeted lookup", "accepted local evidence"),
    source_url = NA_character_,
    parent_organization = NA_character_,
    resolved_site_setting = NA_character_,
    setting_source = NA_character_
  )

# Manually reviewed public evidence is kept as an explicit, reproducible
# override rather than silently replacing a source field.
overrides <- tibble(
  address_key = c("301 KNAPP ST WOLF POINT MT 59201",
                  "302 4TH AVE HAVRE MT 59501"),
  resolved_site_name = c("NEMHS - Listerud Rural Health Clinic",
                         "Hill County Health Department / Bullhook Clinic"),
  parent_organization = c("Northeast Montana Health Services (NEMHS)",
                          "Hill County"),
  resolved_site_setting = c("Clinic/practice", "Clinic/practice"),
  setting_source = c("CMS RHC list", "NPPES Type-2 + Montana public-health provider list"),
  resolution_source = c("CMS RHC list + Providence provider directory",
                        "NPPES Type-2 organization + Montana VFC provider list"),
  source_url = c(
    paste(
      "https://www.cms.gov/outreach-and-education/medicare-learning-network-mln/mlnproducts/downloads/rhclistbyname.pdf",
      "https://phppd.providence.org/BaseSearch/Provider/View/114033572560444",
      sep = " ; "
    ),
    paste(
      "https://npiregistry.cms.hhs.gov/registry/provider-view/1962558338",
      "https://dphhs.mt.gov/assets/publichealth/Immunization/PhilProviderList.pdf",
      sep = " ; "
    )
  ),
  confidence = c("high", "high"),
  review_status = c("manually reviewed", "manually reviewed")
)

sites <- sites %>%
  left_join(overrides, by = "address_key", suffix = c("", ".override")) %>%
  mutate(
    resolved_site_name = coalesce(resolved_site_name.override, resolved_site_name),
    parent_organization = coalesce(parent_organization.override, parent_organization),
    resolution_source = coalesce(resolution_source.override, resolution_source),
    source_url = coalesce(source_url.override, source_url),
    confidence = coalesce(confidence.override, confidence),
    review_status = coalesce(review_status.override, review_status),
    resolved_site_setting = coalesce(
      resolved_site_setting.override,
      case_when(
        str_detect(coalesce(facility_type, ""), "hospital") ~ "Hospital",
        str_detect(coalesce(facility_type, ""), "birth_center") ~ "Birth center",
        str_detect(coalesce(facility_type, ""), "fqhc") ~ "FQHC/community health",
        str_detect(coalesce(facility_type, ""), "clinic") ~ "Clinic/practice",
        TRUE ~ "Other/unclassified"
      )
    ),
    setting_source = coalesce(setting_source.override, "Existing facility-type evidence"),
    name_status = if_else(confidence == "unresolved", "unresolved", "resolved"),
    setting_status = case_when(
      !is.na(resolved_site_setting.override) ~ "evidence-supported",
      str_detect(coalesce(facility_type, ""),
                 "hospital|birth_center|fqhc|clinic") ~ "evidence-supported",
      TRUE ~ "fallback"
    ),
    resolution_status = name_status
  ) %>%
  select(site_id, address_key, street, city, state, zip5, lat, lon, facility_type,
         n_midwives, midwives, resolved_site_name, parent_organization,
         resolved_site_setting, setting_source,
         resolution_status, name_status, setting_status, confidence,
         review_status, resolution_source,
         source_url, evidence_rows, trilliant_site_name,
         organization_directory_name, hospital_at_address_name,
         birth_center_at_address_name, nppes_type2_name)

write_csv(sites, file.path(ART, "worksite_address_resolution.csv"), na = "")
write_csv(filter(sites, resolution_status == "unresolved"),
          file.path(ART, "worksite_address_resolution_unresolved.csv"), na = "")

cat("Resolved sites by confidence/source:\n")
print(sites %>% count(resolution_status, confidence, resolution_source, sort = TRUE), n = Inf)
cat("Wrote artifacts/worksite_address_resolution.csv and unresolved queue\n")
