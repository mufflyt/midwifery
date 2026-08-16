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
# CMS ROTATES THE RESOURCE ID ON EVERY REFRESH, so a hardcoded download URL
# rots silently. This one did: the pinned id _1782750576 began returning 404
# after the dataset was refreshed on 2026-07-31 to _1785521778, which is why
# tests/test_match_npi_to_hospitals.R sits in the nightly exception registry
# and why regenerating the hospital artifacts was blocked.
#
# Resolved from the provider-data catalog instead, with the last known id as a
# fallback so an unreachable catalog degrades to "try the old URL" rather than
# to no URL at all.
DEFAULT_DAC_URL_FALLBACK <- "https://data.cms.gov/provider-data/sites/default/files/resources/b7c4080ae144663e43353a9c35cd3f53_1785521778/Facility_Affiliation.csv"

resolve_facility_affiliation_url <- function() {
  out <- tryCatch({
    u <- paste0("https://data.cms.gov/provider-data/api/1/metastore/",
                "schemas/dataset/items?show-reference-ids=true")
    j <- jsonlite::fromJSON(u, simplifyVector = FALSE)
    hit <- Filter(function(x) grepl("affiliation", tolower(x$title %||% "")), j)
    urls <- unlist(lapply(hit, function(x)
      unlist(lapply(x$distribution %||% list(), function(d) {
        dd <- d$data %||% d
        dd$downloadURL %||% dd$accessURL %||% NULL
      }))))
    urls <- grep("Facility_Affiliation", urls, value = TRUE)
    if (length(urls)) urls[1] else NULL
  }, error = function(e) NULL)
  if (is.null(out) || !nzchar(out)) DEFAULT_DAC_URL_FALLBACK else out
}

DEFAULT_DAC_URL <- resolve_facility_affiliation_url()

# The individual Medicare ENROLLMENT register, which is a different file from
# DEFAULT_DAC_PATH above -- that one is facility AFFILIATION. Conflating them
# was the defect docs/HANDOFF_is_enrolled_dac.md describes.
#
# NAMED WITH ITS VINTAGE ON PURPOSE. A 2024-05 copy of this file also exists on
# an external volume, and reaching for it produced a measurement that was wrong
# twice over: it understated enrollment (3,912 rather than 5,931) and it
# manufactured a 570-NPI "anomaly" that was only a two-year gap between the
# register and the affiliation file. An unversioned name invites exactly that
# mistake; the version in the filename makes staleness visible at the call site.
#
# Gitignored at 840 MB. The subset law in
# tests/test_is_enrolled_dac_semantics.R (C1) catches a stale register: every
# affiliated NPI must appear in it, and none may sit outside.
DEFAULT_DAC_NATIONAL_PATH <- "DAC_NationalDownloadableFile_2026-06.csv"
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
#' Individual Medicare enrollment, independent of facility affiliation
#'
#' @param npi character vector to classify.
#' @param enrolled_individual_npis character vector of NPIs appearing in the DAC
#'   National Downloadable File, which is the enrollment register. NULL when no
#'   register was supplied.
#' @return logical, or NA where enrollment could not be established at all.
#'   NA is deliberate: absence of a register is not evidence of non-enrollment.
dac_enrollment_flag <- function(npi, enrolled_individual_npis) {
  if (is.null(enrolled_individual_npis) || !length(enrolled_individual_npis)) {
    return(rep(NA, length(npi)))
  }
  as.character(npi) %in% as.character(enrolled_individual_npis)
}

#' @param dac_national_npis character vector of NPIs from the DAC National
#'   Downloadable File -- the individual Medicare ENROLLMENT register. Supplied
#'   separately from `dac_path`, which is the facility-AFFILIATION file, because
#' Load the individual Medicare ENROLLMENT register
#'
#' Defined here rather than in each caller. It was pasted into all three
#' hospital-attribution scripts and ci_hygiene H4 caught it -- three copies of
#' "where enrollment comes from" is precisely how two of them would later
#' disagree about it.
#'
#' @param path DAC National Downloadable File. Named with its vintage on
#'   purpose; an unversioned copy on an external volume is what produced a
#'   measurement against a two-year-old register.
#' @return character vector of NPIs, or NULL when the register is absent, which
#'   leaves is_enrolled_dac as NA rather than FALSE.
load_dac_national_npis <- function(
    path = Sys.getenv("DAC_NATIONAL_FILE", DEFAULT_DAC_NATIONAL_PATH)) {
  if (!file.exists(path)) {
    warning("enrollment register not found at ", path,
            "; is_enrolled_dac will be NA", call. = FALSE)
    return(NULL)
  }
  suppressPackageStartupMessages({library(DBI); library(duckdb)})
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT CAST(NPI AS VARCHAR) AS npi
     FROM read_csv_auto('%s', header=TRUE, all_varchar=TRUE, ignore_errors=TRUE)",
    path))$npi
}

#'   conflating the two was the defect this parameter exists to prevent. NULL
#'   leaves `is_enrolled_dac` as NA rather than FALSE.
match_npi_to_hospitals <- function(npis,
                                   dac_path = DEFAULT_DAC_PATH,
                                   hospital_path = DEFAULT_HOSPITAL_PATH,
                                   include_unmatched = TRUE,
                                   dac_national_npis = NULL) {
  
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
  
  # The enrollment register, if one was supplied. Read from the DAC National
  # Downloadable File rather than the affiliation file; see the note at the
  # assembly step below.
  enrolled_individual_npis <- if (!is.null(dac_national_npis)) {
    unique(stringr::str_trim(as.character(dac_national_npis)))
  } else NULL

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
  #
  # SEMANTIC DEFECT FIXED 2026-08-16. `is_enrolled_dac` was
  #
  #     is_enrolled_dac = npi %in% enrolled_npis
  #
  # where enrolled_npis came from dac_filtered -- the FACILITY-AFFILIATION
  # file. That file lists only clinicians who hold a facility affiliation, so
  # every Medicare-enrolled clinician WITHOUT hospital privileges was labelled
  # not enrolled. Affiliation was standing in for enrollment, and the two are
  # different questions.
  #
  # Measured on the 17,054-NPI crosswalk against
  # DAC_NationalDownloadableFile_2026-06.csv, the enrollment register:
  #
  #     in the national register (truly enrolled)   5,931
  #     in the facility-affiliation file            1,665
  #     enrolled with NO facility affiliation       4,266   <- were FALSE
  #
  # The flag understated Medicare enrollment by a factor of 3.56, and any
  # Table 1 row or comparison built on it was wrong. docs/HANDOFF_is_enrolled_dac.md
  # estimated 3,319 affected; the measured figure is 4,266.
  #
  # VINTAGE MATTERS, and getting it wrong cost me a false anomaly. My first
  # measurement used a 2024-05 copy of this file sitting on an external volume
  # and reported 3,912 enrolled, 2,817 mislabelled, and 570 NPIs that had a
  # facility affiliation but no entry in the register -- which I flagged as
  # unexplained. Against the correct 2026-06 file that 570 is ZERO: they were
  # simply providers who enrolled between the two vintages.
  #
  # The right relationship is a strict subset -- you cannot hold a facility
  # affiliation without being enrolled -- and it holds exactly: all 1,665
  # affiliated NPIs appear in the register. Any nonzero count outside it means
  # the register is older than the affiliation file, not that the data is
  # strange. tests/test_is_enrolled_dac_semantics.R asserts the subset.
  #
  # The two variables are now SEPARATE and neither implies the other:
  #
  #     is_enrolled_dac         individual Medicare enrollment, from the
  #                             national register, independent of any facility
  #     has_hospital_privilege  facility affiliation, unchanged
  #
  # NA IS NOT FALSE. When no enrollment register is supplied the flag is NA,
  # not FALSE -- "we did not look" and "we looked and they are not enrolled"
  # are different claims, and collapsing them is how the original defect read
  # as a finding rather than as missing data.
  base_df <- tibble::tibble(npi = unique_npis) %>%
    mutate(
      is_enrolled_dac = dac_enrollment_flag(npi, enrolled_individual_npis)
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
