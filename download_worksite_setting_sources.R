#!/usr/bin/env Rscript

#' Download public facility resources for the work-site setting crosswalk
#'
#' Downloads the pinned CMS hospital, rural health clinic, federally qualified
#' health center, dialysis, and HRSA health-center site files into `data/`.
#' It also downloads the CMS QIES Provider of Services file through the CMS
#' JSON API, the VA locator, the IHS facility workbook, and the SAMHSA
#' N-SUMHSS public-use file. Existing files are preserved by
#' default so a rebuild remains tied to the local input vintage. Set
#' `FORCE_DOWNLOAD=1` to refresh every resource.
#'
#' @file download_worksite_setting_sources.R
#' @details
#' The downloaded files are consumed by [build_worksite_setting_crosswalk.R].
#' Birth-center evidence is maintained separately in
#' `artifacts/cabc_accredited_birth_centers_master.csv`. The script creates
#' `data/additional_facility_lists.csv` as a normalized input for the national
#' directories. State licensing and DoD/TRICARE rows use the manifest/template
#' path because those sources do not publish one stable national address file;
#' their status is reported explicitly in the crosswalk registry.
#' @return No R object. Downloads are written to `data/`; the script stops if a
#'   download is missing or empty.
#' @seealso [build_worksite_setting_crosswalk.R]

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readxl)
  library(readr)
  library(rvest)
  library(stringr)
})

DATA <- "data"
dir.create(DATA, recursive = TRUE, showWarnings = FALSE)
force <- identical(Sys.getenv("FORCE_DOWNLOAD", "0"), "1")

resources <- data.frame(
  file = c(
    "CMS_Hospital_General_Information.csv",
    "CMS_RHC_Enrollments_2026-07-17.csv",
    "CMS_FQHC_Enrollments.csv",
    "HRSA_Health_Center_Service_Delivery_and_LookAlike_Sites.csv",
    "CMS_Dialysis_Facility_Listing.csv"
  ),
  url = c(
    "https://data.cms.gov/provider-data/sites/default/files/resources/893c372430d9d71a1c52737d01239d47_1785189955/Hospital_General_Information.csv",
    "https://data.cms.gov/sites/default/files/2026-07/7ac03830-a6c6-41bd-93cb-ca06d37d2a80/RHC_Enrollments_2026.07.17.csv",
    "https://data.cms.gov/sites/default/files/2026-07/151f844e-b8cc-4df2-b13e-bc2387951fbd/FQHC_Enrollments_2026.07.17.csv",
    "https://data.hrsa.gov/DataDownload/DD_Files/Health_Center_Service_Delivery_and_LookAlike_Sites.csv",
    "https://data.cms.gov/provider-data/sites/default/files/resources/c04d84bc5c641284494bee4f20f17f9c_1781625941/DFC_FACILITY.csv"
  ),
  stringsAsFactors = FALSE
)

for (i in seq_len(nrow(resources))) {
  dest <- file.path(DATA, resources$file[[i]])
  if (file.exists(dest) && !force) {
    message("Keeping existing: ", dest)
    next
  }
  message("Downloading: ", resources$file[[i]])
  tmp <- tempfile(tmpdir = DATA)
  download.file(resources$url[[i]], tmp, mode = "wb", quiet = TRUE)
  if (!file.exists(tmp) || file.info(tmp)$size == 0) {
    stop("Download failed or produced an empty file: ", dest)
  }
  file.rename(tmp, dest)
}

# CMS exposes the current POS file through its public JSON API rather than a
# stable CSV URL. Convert the API response to the local CSV contract.
pos_dest <- file.path(DATA, "CMS_POS_QIES.csv")
if (force || !file.exists(pos_dest)) {
  pos_url <- paste0("https://data.cms.gov/data-api/v1/dataset/",
                    "8ba0f9b4-9493-4aa0-9f82-44ea9468d1b5/data?size=50000")
  pos_json <- tempfile(fileext = ".json")
  download.file(pos_url, pos_json, mode = "wb", quiet = TRUE)
  pos <- fromJSON(pos_json, flatten = TRUE)
  write_csv(as.data.frame(pos), pos_dest, na = "")
  unlink(pos_json)
  message("Wrote: ", pos_dest)
} else {
  message("Keeping existing: ", pos_dest)
}

# HIFLD exposes urgent-care locations through a public ArcGIS REST layer.
hifld_dest <- file.path(DATA, "HIFLD_Urgent_Care_Facilities.csv")
if (force || !file.exists(hifld_dest)) {
  hifld_url <- paste0(
    "https://services.arcgis.com/0ZRg6WRC7mxSLyKX/ArcGIS/rest/services/",
    "HIFLD/FeatureServer/4/query?where=1%3D1&outFields=*",
    "&returnGeometry=false&f=json"
  )
  hifld_json <- tempfile(fileext = ".json")
  download.file(hifld_url, hifld_json, mode = "wb", quiet = TRUE)
  hifld <- fromJSON(hifld_json, flatten = TRUE)
  if (!is.null(hifld$error)) stop("HIFLD download returned an error")
  hifld_rows <- as.data.frame(hifld$features, stringsAsFactors = FALSE)
  names(hifld_rows) <- sub("^attributes\\.", "", names(hifld_rows))
  write_csv(hifld_rows, hifld_dest, na = "")
  unlink(hifld_json)
  message("Wrote: ", hifld_dest)
} else {
  message("Keeping existing: ", hifld_dest)
}

supplemental <- file.path(DATA, "additional_facility_lists.csv")
if (!file.exists(supplemental)) {
  write_csv(data.frame(
    source = character(), source_id = character(), facility_name = character(),
    parent_organization = character(), street = character(), city = character(),
    state = character(), zip = character(), site_setting = character(),
    ccn = character(), source_url = character(), source_vintage = character(),
    source_confidence = character(), stringsAsFactors = FALSE
  ), supplemental, na = "")
  message("Created supplemental input template: ", supplemental)
}

empty_supplemental <- function() tibble(
  source = character(), source_id = character(), facility_name = character(),
  parent_organization = character(), street = character(), city = character(),
  state = character(), zip = character(), site_setting = character(),
  ccn = character(), source_url = character(), source_vintage = character(),
  source_confidence = character()
)
append_supplemental <- function(rows) {
  if (!nrow(rows)) return(invisible(NULL))
  old <- read_csv(supplemental, col_types = cols(.default = col_character()),
                  show_col_types = FALSE, progress = FALSE)
  write_csv(bind_rows(old, rows) %>% distinct(), supplemental, na = "")
}

# These sources are intentionally normalized into the same source contract as
# the state-specific manifest. Some public directories publish city/state but
# not a street address; those rows remain source evidence but cannot produce an
# address match. They are retained so coverage is visible rather than silently
# treated as a missing download.
va_html <- file.path(DATA, "VA_facility_directory.html")
va_url <- "https://discover.va.gov/va-locator-facility-list/"
if (force || !file.exists(va_html)) download.file(va_url, va_html, mode = "wb", quiet = TRUE)
if (file.exists(va_html) && file.info(va_html)$size > 0) {
  va <- html_table(read_html(va_html), fill = TRUE)[[1]]
  append_supplemental(va %>% transmute(
    source = "VA facility directory", source_id = as.character(`Facility ID`),
    facility_name = as.character(Name), parent_organization = "Department of Veterans Affairs",
    street = NA_character_, city = as.character(City), state = as.character(State),
    zip = NA_character_, site_setting = "Other facility", ccn = NA_character_,
    source_url = va_url, source_vintage = "VA locator page", source_confidence = "moderate"))
}

ihs_xlsx <- file.path(DATA, "IHS_facilities.xlsx")
ihs_url <- "https://www.ihs.gov/sites/locations/themes/responsive2017/display_objects/documents/ihs_facilities.xlsx"
if (force || !file.exists(ihs_xlsx)) download.file(ihs_url, ihs_xlsx, mode = "wb", quiet = TRUE)
if (file.exists(ihs_xlsx) && file.info(ihs_xlsx)$size > 0) {
  ihs <- read_excel(ihs_xlsx, skip = 3, col_names = FALSE, .name_repair = "minimal")
  names(ihs) <- paste0("ihs_", seq_along(ihs))
  names(ihs)[1:10] <- c("facility_id", "facility_code", "area", "service_unit",
                          "facility_name", "facility_type", "street", "city", "state", "zip")
  append_supplemental(ihs %>% transmute(
    source = "Indian Health Service facilities", source_id = as.character(facility_id),
    facility_name = as.character(facility_name), parent_organization = "Indian Health Service",
    street = as.character(street), city = as.character(city), state = as.character(state),
    zip = as.character(zip), site_setting = if_else(
      str_detect(str_to_upper(as.character(facility_type)), "HOSPITAL"), "Hospital",
      "FQHC/community health"), ccn = NA_character_, source_url = ihs_url,
    source_vintage = "2023-06-15", source_confidence = "moderate"))
}

nsumhss_zip <- file.path(DATA, "SAMHSA_NSUMHSS_2024.zip")
nsumhss_url <- "https://www.samhsa.gov/data/system/files/media-puf-file/N-SUMHSS-2024-DS0001-bndl-data-csv_v1.zip"
if (force || !file.exists(nsumhss_zip)) download.file(nsumhss_url, nsumhss_zip, mode = "wb", quiet = TRUE)
if (file.exists(nsumhss_zip) && file.info(nsumhss_zip)$size > 0) {
  nsumhss_csv <- tempfile(fileext = ".csv")
  unzip(nsumhss_zip, files = "NSUMHSS_2024_PUF_CSV.csv", exdir = dirname(nsumhss_csv))
  extracted <- file.path(dirname(nsumhss_csv), "NSUMHSS_2024_PUF_CSV.csv")
  if (file.exists(extracted)) {
    sam <- read_csv(extracted, col_types = cols(.default = col_character()),
                    show_col_types = FALSE, progress = FALSE)
    append_supplemental(sam %>% transmute(
      source = "SAMHSA behavioral-health facilities", source_id = as.character(MPRID),
      facility_name = NA_character_, parent_organization = "SAMHSA",
      street = NA_character_, city = NA_character_, state = as.character(LOCATIONSTATE),
      zip = NA_character_, site_setting = "Other facility", ccn = NA_character_,
      source_url = nsumhss_url, source_vintage = "2024", source_confidence = "moderate"))
  }
}

state_manifest <- file.path(DATA, "state_facility_source_manifest.csv")
if (!file.exists(state_manifest)) {
  write_csv(data.frame(
    source = character(), state = character(), source_type = character(),
    url = character(), local_file = character(), cleaner = character(),
    stringsAsFactors = FALSE
  ), state_manifest, na = "")
  message("Created state-source manifest template: ", state_manifest)
}

if (file.exists(state_manifest)) {
  manifest <- read_csv(state_manifest, col_types = cols(.default = col_character()),
                       show_col_types = FALSE, progress = FALSE)
  if (nrow(manifest)) {
    for (i in seq_len(nrow(manifest))) {
      if (!nzchar(manifest$url[[i]]) || !nzchar(manifest$local_file[[i]])) next
      dest <- file.path(DATA, manifest$local_file[[i]])
      if (file.exists(dest) && !force) next
      message("Downloading state source: ", manifest$source[[i]], " / ", manifest$state[[i]])
      download.file(manifest$url[[i]], dest, mode = "wb", quiet = TRUE)
    }
  }
}

message("Source downloads ready. Run build_worksite_setting_crosswalk.R next.")
