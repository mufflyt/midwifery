#!/usr/bin/env Rscript

#' Build the address-to-setting crosswalk for midwifery work sites
#'
#' Reads Trilliant work-site records and joins them to public facility
#' evidence using an exact normalized street, city, state, and ZIP5 key. The
#' source-level output retains all evidence rows many-to-many, while the
#' best-match output provides one consolidated row per matched physical site.
#'
#' @file build_worksite_setting_crosswalk.R
#' @details
#' Available facility layers include CMS hospitals, rural health clinics,
#' FQHC enrollments, QIES Provider of Services, and dialysis facilities; HRSA
#' health-center service-delivery sites; and CABC accredited birth centers.
#' The cohort-linked NPPES Type-2 organization artifact is also included at the
#' corresponding NPPES practice locations.
#' Additional SAMHSA, VA, and IHS rows are read from
#' `data/additional_facility_lists.csv`; state-license and DoD/TRICARE rows are
#' read from the same contract when supplied. Source names and
#' addresses are written in title case, state abbreviations remain uppercase,
#' and ZIP codes remain five-digit strings. The source registry records source
#' row counts and distinguishes available layers from configured layers with
#' no local rows.
#'
#' @return No R object. Writes `artifacts/worksite_address_setting_crosswalk.csv`,
#'   `artifacts/worksite_address_setting_best_match.csv`, and
#'   `artifacts/worksite_setting_source_registry.csv`.
#' @seealso [download_worksite_setting_sources.R]

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

ART <- "artifacts"
DATA <- "data"
dir.create(ART, recursive = TRUE, showWarnings = FALSE)

clean <- function(x) str_squish(str_to_upper(coalesce(as.character(x), "")))
title_case <- function(x) {
  y <- str_to_title(str_squish(coalesce(as.character(x), "")))
  # Preserve common health-care acronyms and local organization abbreviations.
  y <- str_replace_all(y, "\\bFqhc\\b", "FQHC")
  y <- str_replace_all(y, "\\bHrsa\\b", "HRSA")
  y <- str_replace_all(y, "\\bCms\\b", "CMS")
  y <- str_replace_all(y, "\\bCabc\\b", "CABC")
  y <- str_replace_all(y, "\\bNemhs\\b", "NEMHS")
  y <- str_replace_all(y, "\\bVa\\b", "VA")
  y <- str_replace_all(y, "\\bDod\\b", "DoD")
  y <- str_replace_all(y, "\\bIhs\\b", "IHS")
  na_if(y, "")
}
zip5 <- function(x) str_extract(clean(x), "[0-9]{5}")
street_key <- function(x) {
  x <- clean(x)
  x <- str_replace_all(x, "[^A-Z0-9 ]", " ")
  x <- str_replace_all(x, "\\b(STREET|ST)\\b", "ST")
  x <- str_replace_all(x, "\\b(AVENUE|AVE)\\b", "AVE")
  x <- str_replace_all(x, "\\b(ROAD|RD)\\b", "RD")
  x <- str_replace_all(x, "\\b(BOULEVARD|BLVD)\\b", "BLVD")
  x <- str_replace_all(x, "\\b(DRIVE|DR)\\b", "DR")
  x <- str_replace_all(x, "\\b(HIGHWAY|HWY)\\b", "HWY")
  str_squish(x)
}
address_key <- function(street, city, state, zip) {
  paste(street_key(street), clean(city), clean(state), zip5(zip), sep = "|")
}
first_nonempty <- function(x) {
  x <- x[!is.na(x) & nzchar(str_squish(as.character(x)))]
  if (length(x)) x[[1L]] else NA_character_
}
first_finite <- function(x) {
  x <- x[is.finite(x)]
  if (length(x)) x[[1L]] else NA_real_
}

work <- read_csv(file.path(ART, "midwife_work_sites_long.csv"),
                 show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = col_character())) %>%
  mutate(lat = as.numeric(lat), lon = as.numeric(lon)) %>%
  filter(!is.na(site_id), !is.na(street), nzchar(str_squish(street)),
         !is.na(city), nzchar(str_squish(city)), !is.na(state),
         nzchar(str_squish(state)), !is.na(zip5), nzchar(str_squish(zip5)))
work_sites <- work %>%
  group_by(site_id, street, city, state, zip5) %>%
  summarise(
    worksite_street = first_nonempty(street), worksite_city = first_nonempty(city),
    worksite_state = first_nonempty(state), worksite_zip5 = first_nonempty(zip5),
    worksite_lat = first_finite(lat), worksite_lon = first_finite(lon), .groups = "drop"
  ) %>%
  select(site_id, worksite_street, worksite_city, worksite_state, worksite_zip5,
         worksite_lat, worksite_lon) %>%
  mutate(worksite_address_key = address_key(worksite_street, worksite_city,
                                             worksite_state, worksite_zip5))

source_rows <- list()
add_source <- function(d) source_rows[[length(source_rows) + 1L]] <<- d

# Explicit NPPES Type-2 organization evidence at the cohort's own practice
# locations. This is the address-linked cohort subset, not the full national
# NPPES organization registry.
nppes_org_path <- file.path(ART, "midwife_org_person.csv")
if (file.exists(nppes_org_path)) {
  nppes_org <- read_csv(nppes_org_path,
                        col_types = cols(.default = col_character()),
                        show_col_types = FALSE, progress = FALSE) %>%
    select(certification_number, org_npi, organization_name, loc_type) %>%
    distinct()
  nppes_locations <- work %>%
    mutate(loc_type = case_when(
      str_starts(source, "nppes_") ~ str_remove(str_remove(source, "^nppes_"), "_location$"),
      TRUE ~ NA_character_
    )) %>%
    filter(!is.na(loc_type), !is.na(street), !is.na(city), !is.na(state), !is.na(zip5)) %>%
    select(certification_number, loc_type, street, city, state, zip5) %>%
    distinct()
  nppes_source <- nppes_org %>%
    inner_join(nppes_locations, by = c("certification_number", "loc_type")) %>%
    transmute(
      source = "NPPES Type-2 organizations",
      source_id = as.character(org_npi), facility_name = as.character(organization_name),
      parent_organization = as.character(organization_name), street, city, state,
      zip = zip5, site_setting = case_when(
        str_detect(str_to_upper(coalesce(organization_name, "")), "HOSPITAL") ~ "Hospital",
        str_detect(str_to_upper(coalesce(organization_name, "")), "BIRTH CENTER") ~ "Birth center",
        str_detect(str_to_upper(coalesce(organization_name, "")), "FQHC|COMMUNITY HEALTH") ~ "FQHC/community health",
        TRUE ~ "Clinic/practice"
      ),
      ccn = NA_character_,
      source_url = "https://npiregistry.cms.hhs.gov/search/generateAdvancedSearch.do",
      source_vintage = "cohort-linked NPPES artifact",
      source_confidence = "moderate"
    ) %>%
    distinct(source, source_id, street, city, state, zip, .keep_all = TRUE)
  add_source(nppes_source)
}

cms_hosp <- read_csv(file.path(DATA, "CMS_Hospital_General_Information.csv"),
                     col_types = cols(.default = col_character()),
                     show_col_types = FALSE, progress = FALSE) %>%
  transmute(
    source = "CMS Hospital General Information",
    source_id = as.character(`Facility ID`),
    facility_name = as.character(`Facility Name`),
    street = as.character(Address), city = as.character(`City/Town`),
    state = as.character(State), zip = as.character(`ZIP Code`),
    site_setting = "Hospital", parent_organization = as.character(`Hospital Ownership`),
    ccn = as.character(`Facility ID`),
    source_url = "https://data.cms.gov/provider-data/dataset/xubh-q36u",
    source_vintage = "local CMS hospital file", source_confidence = "high"
  )
add_source(cms_hosp)

rhcp <- file.path(DATA, "CMS_RHC_Enrollments_2026-07-17.csv")
if (file.exists(rhcp)) {
  rhc <- read_csv(rhcp, col_types = cols(.default = col_character()),
                  show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      source = "CMS Rural Health Clinic Enrollments",
      source_id = as.character(`ENROLLMENT ID`),
      facility_name = coalesce(as.character(`DOING BUSINESS AS NAME`),
                               as.character(`ORGANIZATION NAME`)),
      street = as.character(`ADDRESS LINE 1`), city = as.character(CITY),
      state = as.character(STATE), zip = as.character(`ZIP CODE`),
      site_setting = "Clinic/practice",
      parent_organization = as.character(`ORGANIZATION NAME`),
      ccn = as.character(CCN),
      source_url = "https://catalog.data.gov/dataset/rural-health-clinic-enrollments",
      source_vintage = "2026-07-17", source_confidence = "high"
    )
  add_source(rhc)
}

fqhcp <- file.path(DATA, "CMS_FQHC_Enrollments.csv")
if (file.exists(fqhcp)) {
  fqhc <- read_csv(fqhcp, col_types = cols(.default = col_character()),
                   show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      source = "CMS FQHC Enrollments",
      source_id = as.character(`ENROLLMENT ID`),
      facility_name = coalesce(as.character(`DOING BUSINESS AS NAME`),
                               as.character(`ORGANIZATION NAME`)),
      street = as.character(`ADDRESS LINE 1`), city = as.character(CITY),
      state = as.character(STATE), zip = as.character(`ZIP CODE`),
      site_setting = "FQHC/community health",
      parent_organization = as.character(`ORGANIZATION NAME`),
      ccn = as.character(CCN),
      source_url = "https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/federally-qualified-health-center-enrollments",
      source_vintage = "2026-07-17", source_confidence = "high"
    )
  add_source(fqhc)
}

hrsa_path <- file.path(DATA, "HRSA_Health_Center_Service_Delivery_and_LookAlike_Sites.csv")
if (file.exists(hrsa_path)) {
  # The HRSA export has one consistently empty trailing field omitted from
  # data rows; the address and facility fields used here are unaffected.
  hrsa <- suppressWarnings(
    suppressMessages(
      read_csv(hrsa_path, col_types = cols(.default = col_character()),
               show_col_types = FALSE, progress = FALSE)
    )
  ) %>%
    transmute(
      source = "HRSA Health Center Service Delivery Sites",
      source_id = as.character(`BPHC Assigned Number`),
      facility_name = as.character(`Site Name`),
      street = as.character(`Site Address`), city = as.character(`Site City`),
      state = as.character(`Site State Abbreviation`), zip = as.character(`Site Postal Code`),
      site_setting = "FQHC/community health",
      parent_organization = as.character(`Health Center Name`), ccn = NA_character_,
      source_url = "https://data.hrsa.gov/topics/health-centers/",
      source_vintage = "2026-08-27", source_confidence = "high"
    )
  add_source(hrsa)
}

cabc_path <- file.path(ART, "cabc_accredited_birth_centers_master.csv")
if (file.exists(cabc_path)) {
  cabc <- read_csv(cabc_path, col_types = cols(.default = col_character()),
                   name_repair = "minimal", show_col_types = FALSE,
                   progress = FALSE) %>%
    mutate(
      parsed_zip = coalesce(zip5(zip_code), zip5(full_address)),
      parsed_street = str_squish(str_extract(full_address, "^[^,]+"))
    ) %>%
    transmute(
      source = "CABC accredited birth centers",
      source_id = as.character(bc_id), facility_name = as.character(facility_name),
      street = parsed_street, city = as.character(city), state = as.character(state),
      zip = parsed_zip, site_setting = "Birth center", parent_organization = NA_character_,
      ccn = NA_character_,
      source_url = "https://birthcenteraccreditation.org/find-accredited-birth-centers/",
      source_vintage = "current CABC master", source_confidence = "high"
    )
  add_source(cabc)
}

pos_path <- file.path(DATA, "CMS_POS_QIES.csv")
if (file.exists(pos_path)) {
  pos <- read_csv(pos_path, col_types = cols(.default = col_character()),
                  show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      source = "CMS Provider of Services QIES",
      source_id = as.character(PRVDR_NUM), facility_name = as.character(FAC_NAME),
      street = as.character(ST_ADR), city = as.character(CITY_NAME),
      state = as.character(STATE_CD), zip = as.character(ZIP_CD),
      site_setting = case_when(
        str_detect(str_to_upper(as.character(FAC_NAME)), "HOSPITAL") ~ "Hospital",
        TRUE ~ "Other facility"
      ),
      parent_organization = NA_character_, ccn = as.character(PRVDR_NUM),
      source_url = "https://data.cms.gov/provider-characteristics/hospitals-and-other-facilities/provider-of-services-file-quality-improvement-and-evaluation-system",
      source_vintage = "Q1 2026", source_confidence = "high"
    )
  add_source(pos)
}

dialysis_path <- file.path(DATA, "CMS_Dialysis_Facility_Listing.csv")
if (file.exists(dialysis_path)) {
  dialysis <- read_csv(dialysis_path, col_types = cols(.default = col_character()),
                       show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      source = "CMS Dialysis Facility Listing",
      source_id = as.character(`CMS Certification Number (CCN)`),
      facility_name = as.character(`Facility Name`),
      street = as.character(`Address Line 1`),
      city = as.character(`City/Town`), state = as.character(State),
      zip = as.character(`ZIP Code`), site_setting = "Other facility",
      parent_organization = as.character(`Chain Organization`),
      ccn = as.character(`CMS Certification Number (CCN)`),
      source_url = "https://data.cms.gov/provider-data/dataset/23ew-n7w9",
      source_vintage = "2026-07-15", source_confidence = "high"
    )
  add_source(dialysis)
}

hifld_path <- file.path(DATA, "HIFLD_Urgent_Care_Facilities.csv")
if (file.exists(hifld_path)) {
  hifld <- read_csv(hifld_path, col_types = cols(.default = col_character()),
                    show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      source = "HIFLD Urgent Care Facilities",
      source_id = as.character(ID), facility_name = as.character(NAME),
      street = as.character(ADDRESS), city = as.character(CITY),
      state = as.character(STATE), zip = as.character(ZIP),
      site_setting = "Clinic/practice", parent_organization = NA_character_,
      ccn = NA_character_,
      source_url = "https://catalog.data.gov/dataset/urgent-care-facilities",
      source_vintage = "HIFLD ArcGIS layer", source_confidence = "moderate"
    )
  add_source(hifld)
}

supplemental_path <- file.path(DATA, "additional_facility_lists.csv")
if (file.exists(supplemental_path)) {
  supplemental <- read_csv(supplemental_path,
                           col_types = cols(.default = col_character()),
                           show_col_types = FALSE, progress = FALSE)
  if (nrow(supplemental)) add_source(supplemental %>%
    transmute(source, source_id, facility_name, parent_organization, street,
              city, state, zip, site_setting, ccn, source_url, source_vintage,
              source_confidence))
}

optional_sources <- tibble(
  source = c("State-licensed birth centers", "State-licensed clinic facilities",
             "SAMHSA behavioral-health facilities",
             "VA facility directory", "DoD/TRICARE military treatment facilities",
             "Indian Health Service facilities"),
  expected_file = c("data/state_facility_source_manifest.csv", "data/state_facility_source_manifest.csv",
                    "data/additional_facility_lists.csv",
                    "data/additional_facility_lists.csv", "data/additional_facility_lists.csv",
                    "data/additional_facility_lists.csv"),
  site_setting = c("Birth center", "Clinic/practice", "Other facility", "Other facility", "Other facility", "Other facility"),
  source_url = c(
    "https://www.cdc.gov/nchs/",
    "https://www.cdc.gov/nchs/",
    "https://www.samhsa.gov/data/data-we-collect/n-sumhss-national-substance-use-and-mental-health-services-survey",
    "https://www.va.gov/directory/guide/home.asp?isflash=0",
    "https://tricare.mil/mtf",
    "https://www.ihs.gov/locations/"
  ),
  source_status = "supplemental template; source-specific rows pending"
)

crosswalk <- bind_rows(source_rows) %>%
  mutate(
    street = as.character(street), city = as.character(city),
    state = clean(state), zip5 = zip5(zip),
    address_key = address_key(street, city, state, zip5),
    source_row_id = paste(source, source_id, sep = "|")
  ) %>%
  left_join(work_sites, by = c("address_key" = "worksite_address_key"),
            relationship = "many-to-many") %>%
  mutate(
    address_match = if_else(!is.na(site_id), "exact normalized address + ZIP5", "no work-site match"),
    match_confidence = if_else(!is.na(site_id), source_confidence, "source-only")
  ) %>%
  select(source, source_id, facility_name, parent_organization, street, city, state, zip5,
         address_key, site_setting, ccn, source_url, source_vintage, source_confidence,
         site_id, worksite_street, worksite_city, worksite_state, worksite_zip5,
         worksite_lat, worksite_lon, address_match, match_confidence) %>%
  mutate(
    facility_name = title_case(facility_name),
    parent_organization = title_case(parent_organization),
    street = title_case(street),
    city = title_case(city),
    state = str_to_upper(state),
    worksite_street = title_case(worksite_street),
    worksite_city = title_case(worksite_city),
    worksite_state = str_to_upper(worksite_state)
  )

best <- crosswalk %>%
  filter(!is.na(site_id)) %>%
  group_by(site_id) %>%
  summarise(
    worksite_street = first(worksite_street), worksite_city = first(worksite_city),
    worksite_state = first(worksite_state), worksite_zip5 = first(worksite_zip5),
    worksite_lat = first(worksite_lat), worksite_lon = first(worksite_lon),
    matched_names = title_case(paste(sort(unique(facility_name)), collapse = "; ")),
    matched_settings = paste(sort(unique(site_setting)), collapse = "; "),
    matched_sources = paste(sort(unique(source)), collapse = "; "),
    best_setting = case_when(
      any(site_setting == "Hospital") ~ "Hospital",
      any(site_setting == "Birth center") ~ "Birth center",
      any(site_setting == "FQHC/community health") ~ "FQHC/community health",
      any(site_setting == "Clinic/practice") ~ "Clinic/practice",
      TRUE ~ "Other facility"
    ),
    .groups = "drop"
  ) %>%
  mutate(
    worksite_street = title_case(worksite_street),
    worksite_city = title_case(worksite_city),
    worksite_state = str_to_upper(worksite_state)
  )

registry <- bind_rows(
  crosswalk %>% group_by(source, source_url) %>%
    summarise(n_source_rows = n(), n_matched_rows = sum(!is.na(site_id)),
              .groups = "drop") %>%
    mutate(expected_file = NA_character_, source_status = "available") %>%
    select(source, expected_file, source_status, source_url,
           n_source_rows, n_matched_rows),
  optional_sources %>%
    left_join(crosswalk %>% count(source, name = "n_source_rows") %>%
                mutate(n_matched_rows = 0L), by = "source") %>%
    mutate(n_source_rows = coalesce(n_source_rows, 0L),
           n_matched_rows = coalesce(n_matched_rows, 0L),
           source_status = if_else(n_source_rows > 0L, "available",
                                   "configured; no local rows")) %>%
    select(source, expected_file, source_status, source_url,
           n_source_rows, n_matched_rows)
) %>% distinct(source, .keep_all = TRUE)

write_csv(crosswalk, file.path(ART, "worksite_address_setting_crosswalk.csv"), na = "")
write_csv(best, file.path(ART, "worksite_address_setting_best_match.csv"), na = "")
write_csv(registry, file.path(ART, "worksite_setting_source_registry.csv"), na = "")

cat("Source rows:", nrow(crosswalk), "\n")
cat("Source rows matched to work sites:", sum(!is.na(crosswalk$site_id)), "\n")
cat("Distinct matched work sites:", nrow(best), "\n")
cat("\nBy setting:\n")
print(crosswalk %>% count(site_setting, sort = TRUE), n = Inf)
cat("\nWrote crosswalk, best-match view, and source registry.\n")
