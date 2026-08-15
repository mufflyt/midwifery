#!/usr/bin/env Rscript
# =============================================================================
# Match NPI Individuals to Hospitals & Healthcare Facilities
# =============================================================================
# Function: match_npi_to_hospitals(npis, dac_path, hospital_path, include_unmatched)
#
# Links individual clinician NPIs (Type 1) to hospital affiliations and CMS
# Certification Numbers (CCNs) using the CMS Provider Data Catalog (DAC) and
# the geocoded OB Hospital Master registry.
#
# Handles alphanumeric CCN formats (e.g. "01T001" swing beds) via pad_ccn()
# to prevent silent drops from numeric coercion.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr)
})

source("R/lib/common_helpers.R")

DEFAULT_DAC_PATH <- "data/CMS_Facility_Affiliation.csv"
DEFAULT_DAC_URL <- "https://data.cms.gov/provider-data/sites/default/files/resources/b7c4080ae144663e43353a9c35cd3f53_1782750576/Facility_Affiliation.csv"
DEFAULT_HOSPITAL_PATH <- "artifacts/ob_hospitals_geocoded.csv"
DEFAULT_HOSP_INFO_URL <- "https://data.cms.gov/provider-data/sites/default/files/resources/893c372430d9d71a1c52737d01239d47_1777413958/Hospital_General_Information.csv"

#' Build OB Hospital Master Artifact from CMS Hospital General Information if missing
build_ob_hospitals_artifact <- function(target_path = DEFAULT_HOSPITAL_PATH) {
  if (file.exists(target_path)) return(TRUE)
  
  dir_name <- dirname(target_path)
  if (!dir.exists(dir_name)) {
    dir.create(dir_name, recursive = TRUE, showWarnings = FALSE)
  }
  
  raw_hosp_csv <- "data/CMS_Hospital_General_Information.csv"
  ensure_file_exists(raw_hosp_csv, DEFAULT_HOSP_INFO_URL)
  
  if (!file.exists(raw_hosp_csv)) {
    warning(sprintf("Unable to acquire CMS Hospital General Information data to build '%s'.", target_path), call. = FALSE)
    return(FALSE)
  }
  
  message(sprintf("[match_npi_to_hospitals] Building hospital master artifact '%s' from CMS General Information...", target_path))
  
  tryCatch({
    raw_df <- readr::read_csv(raw_hosp_csv, show_col_types = FALSE,
                              col_types = readr::cols(.default = readr::col_character()))
    
    # Map CMS columns to standard schema
    mapped <- raw_df %>%
      mutate(
        prvdr_num = pad_ccn(`Facility ID`),
        fac_name = `Facility Name`,
        geocode_address_1 = `Address`,
        geocode_city = `City/Town`,
        geocode_state = `State`,
        geocode_zip = `ZIP Code`,
        county_fips = `County/Parish`,
        latitude = NA_character_,
        longitude = NA_character_
      ) %>%
      filter(!is.na(prvdr_num)) %>%
      # One row per CCN. Prefer the record that actually names the facility and
      # carries a county, so the survivor is the most complete row rather than
      # whichever CMS happened to list first.
      arrange(prvdr_num, is.na(fac_name), is.na(county_fips), fac_name) %>%
      distinct(prvdr_num, .keep_all = TRUE)
    
    readr::write_csv(mapped, target_path)
    message(sprintf("[match_npi_to_hospitals] Successfully created hospital artifact '%s' (%d records).", target_path, nrow(mapped)))
    return(TRUE)
  }, error = function(e) {
    warning(sprintf("Failed to build hospital artifact: %s", e$message), call. = FALSE)
    return(FALSE)
  })
}

#' Auto-ensure dataset availability (Downloads missing DAC files & creates artifacts)
ensure_file_exists <- function(path, url = NULL) {
  if (file.exists(path)) return(TRUE)
  
  dir_name <- dirname(path)
  if (!dir.exists(dir_name)) {
    dir.create(dir_name, recursive = TRUE, showWarnings = FALSE)
  }
  
  if (!is.null(url)) {
    message(sprintf("[match_npi_to_hospitals] Missing file '%s'. Downloading from:\n  %s ...", path, url))
    tryCatch({
      utils::download.file(url, destfile = path, mode = "wb", quiet = TRUE)
      message(sprintf("[match_npi_to_hospitals] Successfully downloaded '%s'.", path))
      return(TRUE)
    }, error = function(e) {
      warning(sprintf("Failed to download '%s': %s", path, e$message), call. = FALSE)
      return(FALSE)
    })
  }
  return(FALSE)
}

#' Match NPI Individuals to their Affiliated Hospitals
#'
#' @param npis [character vector or data.frame]: Vector of 10-digit NPI strings,
#'   or a data frame containing an `npi` column.
#' @param dac_path [character(1)]: Path to the CMS Facility Affiliations CSV.
#' @param hospital_path [character(1)]: Path to the geocoded OB hospital master CSV.
#' @param include_unmatched [logical(1)]: If TRUE (default), returns a row for
#'   every input NPI, even if no hospital affiliation is found. If FALSE, returns
#'   only NPIs with verified hospital linkages.
#'
#' @return [tbl_df] Data frame with NPI, enrollment/privilege status, CCN,
#'   hospital name, location, and coordinates.
#' @export
match_npi_to_hospitals <- function(npis,
                                   dac_path = DEFAULT_DAC_PATH,
                                   hospital_path = DEFAULT_HOSPITAL_PATH,
                                   include_unmatched = TRUE) {
  
  # 0. Ensure datasets exist (Auto-download & artifact creation if missing)
  ensure_file_exists(dac_path, DEFAULT_DAC_URL)
  if (!file.exists(hospital_path)) {
    build_ob_hospitals_artifact(hospital_path)
  }

  # 1. Extract NPI vector from input
  if (is.data.frame(npis)) {
    if (!"npi" %in% names(npis)) {
      stop("Input data frame must contain an 'npi' column.", call. = FALSE)
    }
    input_npis <- as.character(npis$npi)
  } else {
    input_npis <- as.character(npis)
  }
  
  input_npis <- stringr::str_trim(input_npis)
  input_npis <- input_npis[!is.na(input_npis) & nzchar(input_npis)]
  unique_npis <- unique(input_npis)
  
  if (length(unique_npis) == 0) {
    warning("No valid NPIs provided to match_npi_to_hospitals().", call. = FALSE)
    return(tibble::tibble(
      npi = character(), is_enrolled_dac = logical(),
      has_hospital_privilege = logical(), n_hospitals = integer(),
      cms_ccn = character(), facility_type = character(),
      hospital_name = character(), hospital_city = character(),
      hospital_state = character(), hospital_county_fips = character(),
      hospital_latitude = numeric(), hospital_longitude = numeric()
    ))
  }

  # 2. Read OB Hospital Master Registry
  if (!file.exists(hospital_path)) {
    stop(sprintf("OB hospital master file not found: %s", hospital_path), call. = FALSE)
  }
  
  hospitals <- chr(hospital_path) %>%
    mutate(
      cms_ccn = pad_ccn(prvdr_num),
      hospital_latitude = as.numeric(latitude),
      hospital_longitude = as.numeric(longitude)
    ) %>%
    filter(!is.na(cms_ccn)) %>%
    select(
      cms_ccn,
      hospital_name = fac_name,
      hospital_address = geocode_address_1,
      hospital_city = geocode_city,
      hospital_state = geocode_state,
      hospital_zip = geocode_zip,
      hospital_county_fips = county_fips,
      hospital_latitude,
      hospital_longitude
    ) %>%
    # Prefer a geocoded hospital row over an un-geocoded one; a hospital with
    # no coordinates cannot be placed on a map.
    arrange(cms_ccn, is.na(hospital_latitude), hospital_name) %>%
    distinct(cms_ccn, .keep_all = TRUE)

  # 3. Read CMS Facility Affiliation dataset
  if (!file.exists(dac_path)) {
    stop(sprintf("CMS Facility Affiliation dataset not found: %s", dac_path), call. = FALSE)
  }
  
  dac_raw <- chr(dac_path)
  
  # Identify NPI and CCN column names dynamically
  npi_col <- names(dac_raw)[str_detect(names(dac_raw), regex("^npi$", ignore_case = TRUE))][1]
  ccn_col <- names(dac_raw)[str_detect(names(dac_raw), regex("ccn|certification", ignore_case = TRUE))][1]
  type_col <- names(dac_raw)[str_detect(names(dac_raw), regex("facility_type|type", ignore_case = TRUE))][1]
  
  if (is.na(npi_col)) {
    stop("CMS Facility Affiliation file lacks an NPI column.", call. = FALSE)
  }
  
  dac_filtered <- dac_raw %>%
    mutate(
      npi = stringr::str_trim(!!sym(npi_col)),
      cms_ccn = if (!is.na(ccn_col)) pad_ccn(!!sym(ccn_col)) else NA_character_,
      facility_type = if (!is.na(type_col)) !!sym(type_col) else NA_character_
    ) %>%
    filter(npi %in% unique_npis)

  enrolled_npis <- unique(dac_filtered$npi)

  # 4. Join affiliations to hospital master
  affils <- dac_filtered %>%
    filter(!is.na(cms_ccn)) %>%
    # hospital master is one row per CCN.
    left_join(hospitals, by = "cms_ccn", relationship = "many-to-one") %>%
    select(
      npi,
      facility_type,
      cms_ccn,
      hospital_name,
      hospital_address,
      hospital_city,
      hospital_state,
      hospital_zip,
      hospital_county_fips,
      hospital_latitude,
      hospital_longitude
    ) %>%
    # One affiliation per (provider, hospital). Same rule as above: the
    # placeable row wins.
    arrange(npi, cms_ccn, is.na(hospital_latitude), hospital_name) %>%
    distinct(npi, cms_ccn, .keep_all = TRUE)

  # 5. Calculate per-NPI privilege summary
  npi_summary <- affils %>%
    filter(!is.na(hospital_name) | !is.na(cms_ccn)) %>%
    group_by(npi) %>%
    summarise(n_hospitals = n_distinct(cms_ccn[!is.na(cms_ccn)]), .groups = "drop")

  # 6. Assemble complete output dataframe
  base_df <- tibble::tibble(npi = unique_npis) %>%
    mutate(
      is_enrolled_dac = npi %in% enrolled_npis
    ) %>%
    # npi_summary is summarised per npi; base_df is unique_npis.
    left_join(npi_summary, by = "npi", relationship = "many-to-one") %>%
    mutate(
      n_hospitals = dplyr::coalesce(n_hospitals, 0L),
      has_hospital_privilege = n_hospitals > 0L
    )
  
  out <- base_df %>%
    # DELIBERATE fan-out: one NPI holds many hospital affiliations, so the
    # output is affiliation-level, not provider-level. Declared so the row
    # multiplication is visibly intended rather than an accident.
    left_join(affils, by = "npi", relationship = "one-to-many")
  
  if (!include_unmatched) {
    out <- out %>% filter(has_hospital_privilege == TRUE)
  }
  
  out %>% arrange(npi, cms_ccn)
}

# Command-line execution support
if (sys.nframe() == 0) {
  cat("=== Testing match_npi_to_hospitals() ===\n")
  
  # Sample NPI test using Cleveland Clinic / Colorado / Johns Hopkins NPIs from cohort
  mw_file <- "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv"
  if (file.exists(mw_file)) {
    mws <- chr(mw_file) %>%
      filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
      head(20)
    
    cat(sprintf("Testing function on sample of %d cohort midwives...\n", nrow(mws)))
    res <- match_npi_to_hospitals(mws$npi)
    
    cat(sprintf("Total Output Rows: %d\n", nrow(res)))
    cat(sprintf("Midwives Enrolled in DAC: %d / %d\n", sum(unique(res$npi) %in% res$npi[res$is_enrolled_dac]), n_distinct(res$npi)))
    cat(sprintf("Midwives with Hospital Privileges: %d / %d\n\n", sum(unique(res$npi) %in% res$npi[res$has_hospital_privilege]), n_distinct(res$npi)))
    
    print(head(res %>% filter(has_hospital_privilege), 10))
  }
}
