#!/usr/bin/env Rscript
#' @title Step 01: County-Level Covariate Base Table (GEOID-keyed)
#'
#' @description
#' Downloads and merges every county-level data source used by the midwifery
#' workforce analysis into a single table keyed on `GEOID` — the 5-digit
#' state + county FIPS code that every downstream join uses.
#'
#' This is the *denominator and context* half of the analysis. The *numerator*
#' (counts of CNMs/CMs from `midwives.csv` and OB/GYNs from NPPES) is attached
#' downstream, once certifications carry a practice county.
#'
#' @section Sources:
#' \itemize{
#'   \item \strong{ACS 5-year 2019-2023} (tidycensus): population, women 15-44,
#'     births in the past 12 months, income, poverty, insurance coverage.
#'   \item \strong{tigris counties}: name, state, land area, centroid.
#'   \item \strong{USDA ERS RUCC 2023}: rural-urban continuum code 1-9.
#'   \item \strong{NCHS Urban-Rural 2013}: 6-level classification.
#'   \item \strong{CDC/ATSDR SVI 2022}: overall social vulnerability percentile.
#'   \item \strong{County Health Rankings 2025}: low birth weight, infant
#'     mortality, teen births, primary care physicians, percent rural.
#' }
#'
#' @section Reused Infrastructure:
#' `R/join_safety.R` and its dependency `R/safe_divide.R` are vendored verbatim
#' from the isochrones repo, so every merge here gets the same coverage and
#' cardinality contracts that pipeline enforces. The loader prefers a live
#' `~/isochrones` checkout (so upstream fixes flow through) and falls back to
#' the vendored copy, then to an inline equivalent.
#'
#' @section Runtime:
#' ~2-4 minutes cold (downloads ~16 MB), ~30 seconds with `data/` populated.
#'
#' @family step-functions
#' @concept census-acs
#' @concept county-covariates
#'
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(readr)
  library(readxl)
  library(stringr)
  library(purrr)
  library(glue)
  library(tidyr)
  library(cli)
  library(checkmate)
  library(janitor)
  library(tidycensus)
  library(tigris)
  library(sf)
})

options(tigris_use_cache = TRUE, timeout = 600)

ACS_YEAR <- 2023L
ACS_SURVEY <- "acs5"
DATA_DIR <- here::here("data")
OUT_CSV <- file.path(DATA_DIR, "county_base.csv")

# ---------------------------------------------------------------------------
# Reused infrastructure: safe joins from the isochrones pipeline
# ---------------------------------------------------------------------------

#' Load `safe_left_join()` from the isochrones repo, or define a local stand-in
#'
#' The isochrones version writes a per-join coverage report; the fallback keeps
#' the same contract (unique right keys, minimum coverage) without the report.
#'
#' @return Invisibly `TRUE` if the shared module was sourced.
#' @keywords internal
#' @noRd
load_join_safety <- function() {
  # join_safety.R sources here::here("R", "safe_divide.R"), so the local copy
  # must be reachable from this project root regardless of which copy we load.
  candidates <- c(
    vendored = here::here("R", "join_safety.R"),
    upstream = path.expand("~/isochrones/R/join_safety.R")
  )
  for (nm in names(candidates)) {
    path <- candidates[[nm]]
    if (!file.exists(path)) next
    ok <- tryCatch({
      source(path, local = FALSE)
      TRUE
    }, error = function(e) {
      cli::cli_alert_warning("{nm} join_safety.R failed to source: {conditionMessage(e)}")
      FALSE
    })
    if (ok && exists("safe_left_join", mode = "function")) {
      cli::cli_alert_success("Reusing safe_left_join() ({nm} copy from isochrones)")
      return(invisible(TRUE))
    }
  }

  # Fallback: same guarantees, no report file.
  safe_left_join <<- function(left, right, by, label_right = "right",
                              min_coverage = NULL, expect_unique_right = TRUE, ...) {
    checkmate::assert_data_frame(left)
    checkmate::assert_data_frame(right)
    checkmate::assert_character(by, min.len = 1L)

    if (expect_unique_right && anyDuplicated(right[by]) > 0L) {
      stop(glue::glue("safe_left_join: duplicate join keys in '{label_right}'"), call. = FALSE)
    }
    out <- dplyr::left_join(left, right, by = by)
    if (nrow(out) != nrow(left)) {
      stop(glue::glue("safe_left_join: row explosion joining '{label_right}' ",
                      "({nrow(left)} -> {nrow(out)})"), call. = FALSE)
    }
    probe <- setdiff(names(right), by)[1]
    coverage <- if (is.na(probe)) 1 else mean(!is.na(out[[probe]]))
    if (!is.null(min_coverage) && coverage < min_coverage) {
      stop(glue::glue("safe_left_join: '{label_right}' coverage {round(coverage, 3)} ",
                      "< required {min_coverage}"), call. = FALSE)
    }
    cli::cli_alert_info("Joined {label_right}: {round(100 * coverage, 1)}% coverage")
    out
  }
  cli::cli_alert_warning("isochrones join_safety.R not found - using local safe_left_join()")
  invisible(FALSE)
}

#' Download a file once and cache it under `data/`
#'
#' @param url [character(1)]: source URL.
#' @param filename [character(1)]: basename to write under `data/`.
#' @param force [logical(1)]: re-download even if the file exists.
#' @return [character(1)] absolute path to the cached file.
#' @keywords internal
#' @noRd
download_cached <- function(url, filename, force = FALSE) {
  checkmate::assert_string(url, min.chars = 1)
  checkmate::assert_string(filename, min.chars = 1)

  dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
  dest <- file.path(DATA_DIR, filename)

  if (file.exists(dest) && !force && file.size(dest) > 0) {
    cli::cli_alert_info("Cached: {filename} ({round(file.size(dest) / 1e6, 1)} MB)")
    return(dest)
  }

  cli::cli_alert("Downloading {filename} ...")
  utils::download.file(url, dest, mode = "wb", quiet = TRUE)
  if (!file.exists(dest) || file.size(dest) == 0) {
    stop(glue::glue("Download produced an empty file: {filename}"), call. = FALSE)
  }
  cli::cli_alert_success("{filename} ({round(file.size(dest) / 1e6, 1)} MB)")
  dest
}

#' Coerce a FIPS column to a zero-padded 5-character GEOID
#'
#' @param x [vector]: numeric or character FIPS codes.
#' @return [character] 5-character GEOIDs.
#' @keywords internal
#' @noRd
as_geoid <- function(x) {
  stringr::str_pad(as.character(trunc(suppressWarnings(as.numeric(x)))),
                   width = 5, side = "left", pad = "0")
}

# ---------------------------------------------------------------------------
# ACS 5-year: denominators, births, socioeconomics
# ---------------------------------------------------------------------------

#' Pull the ACS county variables that anchor every per-capita rate
#'
#' `B13016_002` (women 15-50 who gave birth in the past 12 months) is the only
#' annual birth measure published for *every* county — CDC WONDER natality
#' suppresses counties with small counts. It is a survey estimate, not a vital
#' record, so treat small-county values as noisy.
#'
#' @return [tibble] one row per county, keyed on GEOID.
#' @keywords internal
#' @noRd
fetch_acs_county <- function() {
  if (!nzchar(Sys.getenv("CENSUS_API_KEY"))) {
    stop("CENSUS_API_KEY is unset. Add it to ~/.Renviron and restart R.", call. = FALSE)
  }

  # CYCLE 16. This said "B01001_030..039 are the female 15-19 ... 40-44 age
  # bands" and summed TEN variables. Both halves are wrong, verified against
  # the official ACS 2023 variable labels:
  #
  #   B01001_030E  Female: 15 to 17 years      <- not 15 to 19
  #   B01001_031E  Female: 18 and 19 years
  #   ...
  #   B01001_038E  Female: 40 to 44 years      <- the LAST band of 15-44
  #   B01001_039E  Female: 45 to 49 years      <- was being included
  #
  # So women aged 15-44 is 030..038, NINE variables. Including _039 added the
  # 45-49 band, making this column women 15-49 while every label, and the
  # general fertility rate built on it, says 15-44. An inflated denominator
  # UNDERSTATES the fertility rate in every county.
  #
  # R/12-district-profiles.R already used 30:38, so the same named quantity had
  # two different definitions in one project -- and the district one was right.
  women_labels <- paste0("w", 30:38)

  detail_vars <- c(
    population       = "B01003_001",
    female_total     = "B01001_026",
    median_hh_income = "B19013_001",
    poverty_num      = "B17001_002",
    poverty_den      = "B17001_001",
    women_15_50      = "B13016_001",
    births_past_12mo = "B13016_002",
    rlang::set_names(sprintf("B01001_%03d", 30:38), women_labels)
  )

  cli::cli_alert("Fetching ACS {ACS_YEAR} {ACS_SURVEY} detailed tables ...")
  # output = "wide" appends E (estimate) and M (margin of error) to each label;
  # only the estimates are carried forward.
  detail <- tidycensus::get_acs(
    geography = "county", variables = detail_vars, year = ACS_YEAR,
    survey = ACS_SURVEY, output = "wide", cache_table = TRUE
  ) |>
    dplyr::select(GEOID, acs_name = NAME,
                  dplyr::all_of(paste0(names(detail_vars), "E"))) |>
    dplyr::rename_with(~ stringr::str_remove(.x, "E$"), .cols = -c(GEOID, acs_name))

  cli::cli_alert("Fetching ACS {ACS_YEAR} {ACS_SURVEY} subject tables ...")
  subject <- tidycensus::get_acs(
    geography = "county",
    variables = c(pct_uninsured       = "S2701_C05_001",
                  pct_below_poverty   = "S1701_C03_001",
                  pct_public_coverage = "S2704_C03_001"),
    year = ACS_YEAR, survey = ACS_SURVEY, output = "wide", cache_table = TRUE
  ) |>
    dplyr::select(GEOID,
                  pct_uninsured = pct_uninsuredE,
                  pct_below_poverty = pct_below_povertyE,
                  pct_public_coverage = pct_public_coverageE)

  detail |>
    dplyr::mutate(
      # CYCLE 7, class N1. rowSums(na.rm = TRUE) over the ten female age bands
      # scored a suppressed band as 0 women, shrinking the DENOMINATOR of the
      # general fertility rate and inflating it. This is the same construction
      # found in 12-district-profiles.R (cycle 3) and 03-geography-hierarchy.R
      # (cycle 5); a denominator assembled from parts must not treat an absent
      # part as an empty one. NA when every band is missing, observed sum
      # otherwise, with the gap counted so an understated denominator is visible.
      women_15_44 = {
        .b <- dplyr::across(dplyr::all_of(paste0("w", 30:38)))
        ifelse(rowSums(!is.na(.b)) == 0L, NA_real_, rowSums(.b, na.rm = TRUE))
      },
      women_15_44_bands_missing = rowSums(is.na(dplyr::across(dplyr::all_of(paste0("w", 30:38))))),
      pct_poverty = 100 * poverty_num / poverty_den,
      general_fertility_rate = 1000 * births_past_12mo / women_15_44
    ) |>
    dplyr::select(-dplyr::all_of(paste0("w", 30:38)), -poverty_num, -poverty_den) |>
    safe_left_join(subject, by = "GEOID", label_right = "acs_subject",
                   min_coverage = 0.98,
                   use_enhanced_metrics = FALSE, write_report = FALSE)
}

# ---------------------------------------------------------------------------
# Geography, rurality, vulnerability, health outcomes
# ---------------------------------------------------------------------------

#' County geography from tigris: name, state, land area, centroid
#'
#' @return [tibble] one row per county (all states and territories).
#' @keywords internal
#' @noRd
fetch_county_geography <- function() {
  cli::cli_alert("Fetching tigris county geography ...")
  shp <- tigris::counties(cb = TRUE, year = ACS_YEAR, progress_bar = FALSE)

  # The cartographic-boundary file carries no INTPTLAT/LON, so derive an
  # interior point. point_on_surface (not centroid) keeps the marker inside
  # concave or multi-part counties.
  pts <- suppressWarnings(sf::st_coordinates(sf::st_point_on_surface(
    sf::st_geometry(sf::st_transform(shp, 4326))
  )))

  shp |>
    sf::st_drop_geometry() |>
    dplyr::transmute(
      GEOID,
      county_name = NAME,
      state = STUSPS,
      land_sq_mi = ALAND / 2589988.11,
      lat = pts[, "Y"],
      lon = pts[, "X"]
    ) |>
    dplyr::as_tibble()
}

#' USDA ERS rural-urban continuum codes (2023 vintage)
#' @keywords internal
#' @noRd
fetch_rucc <- function() {
  path <- download_cached(
    paste0("https://www.ers.usda.gov/sites/default/files/_laserfiche/",
           "DataFiles/53251/Ruralurbancontinuumcodes2023.xlsx"),
    "rucc_2023.xlsx"
  )
  readxl::read_excel(path, sheet = 1) |>
    dplyr::transmute(GEOID = as_geoid(FIPS), rucc_2023 = as.integer(RUCC_2023)) |>
    # CYCLE 5. Cycle 1 built build_rucc_lookup() because a bare distinct() let
    # file order decide whether a county was metropolitan. That fix never
    # reached this reader. Conflicting codes for one FIPS now stop the run
    # instead of being resolved by workbook sort order.
    unique() |>
    assert_no_key_conflict("GEOID", "RUCC 2023 workbook")
}

#' NCHS 6-level urban-rural classification (2013 vintage)
#'
#' Older FIPS vintage than RUCC: Connecticut's planning regions and a handful
#' of re-coded AK/PR units will not match. Prefer `rucc_2023` for modeling.
#' @keywords internal
#' @noRd
fetch_nchs_urcodes <- function() {
  path <- download_cached(
    "https://www.cdc.gov/nchs/data/data_acces_files/NCHSURCodes2013.xlsx",
    "nchs_urcodes_2013.xlsx"
  )
  readxl::read_excel(path, sheet = 1) |>
    dplyr::transmute(GEOID = as_geoid(`FIPS code`),
                     nchs_urban_rural_2013 = as.integer(`2013 code`)) |>
    dplyr::distinct(GEOID, .keep_all = TRUE)
}

#' CDC/ATSDR Social Vulnerability Index, overall percentile
#'
#' SVI encodes missing values as -999; those become NA here.
#' @keywords internal
#' @noRd
fetch_svi <- function() {
  path <- download_cached(
    "https://svi.cdc.gov/Documents/Data/2022/csv/states_counties/SVI_2022_US_county.csv",
    "svi_2022_county.csv"
  )
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE) |>
    dplyr::transmute(GEOID = as_geoid(FIPS),
                     svi_overall_pctile = dplyr::if_else(RPL_THEMES < 0, NA_real_,
                                                         RPL_THEMES)) |>
    dplyr::distinct(GEOID, .keep_all = TRUE)
}

#' County Health Rankings maternal and access measures
#'
#' Infant mortality is suppressed below roughly 10 deaths, so it is populated
#' for only about a third of counties. Do not model it at county grain without
#' multi-year pooling.
#' @keywords internal
#' @noRd
fetch_county_health_rankings <- function() {
  path <- download_cached(
    paste0("https://www.countyhealthrankings.org/sites/default/files/media/",
           "document/analytic_data2025_v2.csv"),
    "chr_2025_analytic.csv"
  )
  wanted <- c(
    pct_low_birth_weight    = "Low Birth Weight raw value",
    infant_mortality_per_1k = "Infant Mortality raw value",
    teen_birth_rate         = "Teen Births raw value",
    pcp_per_100k            = "Primary Care Physicians raw value",
    chr_pct_uninsured       = "Uninsured raw value",
    pct_rural               = "% Rural raw value"
  )

  raw <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()),
                         progress = FALSE)
  wanted <- wanted[wanted %in% names(raw)]

  raw |>
    dplyr::transmute(GEOID = as_geoid(`5-digit FIPS Code`),
                     !!!rlang::set_names(rlang::syms(unname(wanted)), names(wanted))) |>
    # The file carries a state-rollup row per state (county part "000"); drop it.
    dplyr::filter(stringr::str_sub(GEOID, 3, 5) != "000") |>
    dplyr::mutate(dplyr::across(-GEOID, ~ suppressWarnings(as.numeric(.x)))) |>
    dplyr::distinct(GEOID, .keep_all = TRUE)
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

#' Build the GEOID-keyed county base table and write it to `data/`
#'
#' @param out_csv [character(1)]: output path.
#' @return [tibble] the merged table, invisibly.
#' @export
build_county_base <- function(out_csv = OUT_CSV) {
  checkmate::assert_string(out_csv, min.chars = 1)
  load_join_safety()

  base <- fetch_county_geography() |>
    safe_left_join(fetch_acs_county(), by = "GEOID",
                   label_right = "acs", min_coverage = 0.98,
                   use_enhanced_metrics = FALSE, write_report = FALSE) |>
    dplyr::mutate(pop_density_sq_mi = population / land_sq_mi) |>
    safe_left_join(fetch_rucc(), by = "GEOID",
                   label_right = "rucc_2023", min_coverage = 0.95,
                   use_enhanced_metrics = FALSE, write_report = FALSE) |>
    safe_left_join(fetch_nchs_urcodes(), by = "GEOID",
                   label_right = "nchs_urcodes_2013", min_coverage = 0.90,
                   use_enhanced_metrics = FALSE, write_report = FALSE) |>
    safe_left_join(fetch_svi(), by = "GEOID",
                   label_right = "svi_2022", min_coverage = 0.90,
                   use_enhanced_metrics = FALSE, write_report = FALSE) |>
    safe_left_join(fetch_county_health_rankings(), by = "GEOID",
                   label_right = "county_health_rankings", min_coverage = 0.85,
                   use_enhanced_metrics = FALSE, write_report = FALSE) |>
    dplyr::arrange(GEOID)

  dir.create(dirname(out_csv), showWarnings = FALSE, recursive = TRUE)
  readr::write_csv(base, out_csv)

  cli::cli_h2("county_base")
  cli::cli_alert_success("{nrow(base)} counties x {ncol(base)} columns -> {out_csv}")

  completeness <- base |>
    dplyr::summarise(dplyr::across(dplyr::everything(), ~ mean(!is.na(.x)))) |>
    tidyr::pivot_longer(dplyr::everything(), names_to = "column",
                        values_to = "complete") |>
    dplyr::arrange(complete)
  print(completeness, n = Inf)

  sparse <- dplyr::filter(completeness, complete < 0.75)
  if (nrow(sparse) > 0) {
    cli::cli_alert_warning(
      "Sparse columns (pool years or drop before modeling): {paste(sparse$column, collapse = ', ')}"
    )
  }

  invisible(base)
}

if (identical(environment(), globalenv()) && !interactive()) {
  build_county_base()
}
