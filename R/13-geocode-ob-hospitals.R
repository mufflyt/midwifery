#!/usr/bin/env Rscript
#' @title Step 13: Geocode hospitals reporting obstetric services
#'
#' @description
#' Assigns coordinates to the CMS Provider of Services hospitals that report an
#' obstetric service, so obstetric capacity can be measured at congressional
#' district level (POS carries county FIPS but no coordinates) and so travel
#' time to the nearest birthing hospital becomes computable.
#'
#' @section Canonical functions, not local ones:
#' Geocoding uses \code{geocode_all_addresses()} from mufflyt/isochrones, and
#' cache keys use \code{canonical_address_key()} from the same repo. Neither is
#' reimplemented here.
#'
#' Picking the right level took three attempts, worth recording:
#' \itemize{
#'   \item \code{geocode_addresses()} is documented as "CANONICAL GEOCODING
#'     WRAPPER - USE THIS FOR ALL GEOCODING" and its body immediately calls
#'     \code{.Deprecated()}. Choosing by docstring gets the deprecated one.
#'   \item \code{geocode_all_addresses()}, its replacement, enforces a
#'     PHYSICIAN-pipeline invariant -- it aborts without an \code{npi} column.
#'     Hospitals have no NPI in POS. That guard exists for a documented reason
#'     (\code{HALL_OF_SHAME_GEOCODING.md}), so it is respected rather than
#'     switched off with \code{enforce_validation = FALSE}.
#'   \item \code{census_batch_geocode()} is the right level: generic addresses,
#'     no cohort assumptions, the same Census batch API underneath.
#' }
#' Reuse means finding the function whose contract matches the data, not
#' forcing the data to satisfy a contract written for something else.
#'
#' HALL OF SHAME #23/#38 record what re-deriving instead would cost: #23
#' produced 724 false coverage gaps out of 3,637 locations; #38 was a 100%
#' cache miss from a 5-dp key against a 6-dp canonical function.
#'
#' @section Reuse before regeneration:
#' The isochrones DuckDB geocode cache already holds 55,843 addresses, covering
#' 364 of these 2,784 hospitals (13.1%). \code{geocode_all_addresses()} checks
#' that cache before any API call, so this run pays for the remainder only. The
#' cache is opened READ-ONLY here: this analysis is a consumer of that cache,
#' not an owner of it, and a concurrent isochrones run must not find it locked.
#'
#' Output : artifacts/ob_hospitals_geocoded.csv
#'
#' @family step-functions
#' @concept county-profiles
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(cli); library(jsonlite)
  library(DBI); library(duckdb)
})

source(file.path("R", "lib", "isochrones_dep.R"))
source(file.path("R", "lib", "ob_hospitals.R"))

ISO   <- isochrones_home()
CACHE <- file.path("/Users/tylermuffly/isochrones", "data", "geocoding_cache.duckdb")
POS   <- file.path("data", "cms_pos_hospital.csv")
OUT   <- file.path("artifacts", "ob_hospitals_geocoded.csv")

sha256_of <- function(p) sub(" .*$", "",
                             system2("shasum", c("-a", "256", shQuote(p)), stdout = TRUE)[1])

#' Evaluate an expression with the working directory set to the isochrones repo
#'
#' The isochrones geocoding stack resolves its internal dependencies with
#' \code{here::here("R", ...)}, which detects the project root of whoever is
#' CALLING. Invoked from midwifery it looks for
#' \code{midwifery/R/clustering_functions_improved.R} and dies. The chain is
#' several files deep -- preprocessing pulls clustering and log_safe,
#' postprocessing pulls them again -- so pre-sourcing each one by absolute path
#' does not fix it: the nested here() calls still fire.
#'
#' Setting the working directory is therefore the only fix available from this
#' side. It is scoped and always restored, so relative output paths in this
#' script keep resolving against midwifery.
#'
#' The real fix belongs upstream: a library that cannot be called from another
#' project is not reusable, and here::here() inside a sourced module is the
#' reason. Worth a small isochrones PR.
#' @keywords internal
#' @noRd
with_iso_wd <- function(expr) {
  old <- getwd()
  setwd(ISO)
  on.exit(setwd(old), add = TRUE)
  force(expr)
}

#' Load the canonical geocoding stack, aborting if unavailable
#' @keywords internal
#' @noRd
load_geocoding_stack <- function() {
  # geocoding_preprocessing.R and geocoding_postprocessing.R are pre-sourced
  # deliberately. geocode_all_addresses() lazy-loads them via
  # here::here("R", ...), which resolves against the CALLER's project root --
  # midwifery, not isochrones -- and dies with "cannot open file
  # .../midwifery/R/geocoding_preprocessing.R". Both lazy-loads are guarded by
  # exists(), so loading them from the isochrones path first makes the guard
  # skip. The alternative, setwd() into another repo mid-run, would break every
  # relative output path in this script.
  f <- c(file.path(ISO, "R", "geocode_cache_utils.R"),
         file.path(ISO, "R", "census_geocode_enhanced.R"))
  missing <- f[!file.exists(f)]
  if (length(missing)) {
    stop("Canonical geocoding functions not found:\n  ",
         paste(missing, collapse = "\n  "),
         "\nSet ISOCHRONES_HOME to a checkout that has them. ",
         "Deliberately no local fallback -- a second geocoder would drift.",
         call. = FALSE)
  }
  with_iso_wd(suppressWarnings(suppressMessages(for (p in f) source(p, chdir = FALSE))))
  for (fn in c("canonical_address_key", "census_batch_geocode")) {
    if (!exists(fn, mode = "function")) {
      stop("Sourced the isochrones geocoding stack but ", fn, "() is undefined.",
           call. = FALSE)
    }
  }
  invisible(TRUE)
}

#' The OB-service hospitals needing coordinates
#' @keywords internal
#' @noRd
ob_hospital_addresses <- function(path = POS) {
  h <- read_csv(path, show_col_types = FALSE, progress = FALSE,
                col_types = cols(.default = col_character()))
  h %>%
    filter(PRVDR_CTGRY_SBTYP_CD %in% HOSPITAL_SUBTYPES,
           is.na(PGM_TRMNTN_CD) | PGM_TRMNTN_CD == "00",
           OB_SRVC_CD %in% c("1", "2", "3")) %>%
    # One row per provider: POS carries superseded records, and geocoding the
    # same hospital repeatedly would waste API calls and inflate any count.
    arrange(PRVDR_NUM, desc(CRTFCTN_DT)) %>%
    distinct(PRVDR_NUM, .keep_all = TRUE) %>%
    transmute(
      prvdr_num = PRVDR_NUM,
      fac_name  = FAC_NAME,
      ob_srvc_cd = OB_SRVC_CD,
      county_fips = paste0(FIPS_STATE_CD, FIPS_CNTY_CD),
      # Column names the canonical geocoder expects.
      geocode_address_1 = ST_ADR,
      geocode_city      = CITY_NAME,
      geocode_state     = STATE_CD,
      geocode_zip       = ZIP_CD)
}

run_geocode <- function() {
  load_geocoding_stack()
  cli::cli_alert_success("canonical geocoding stack loaded from {ISO}")

  ob <- ob_hospital_addresses()
  stopifnot(nrow(ob) > 0, !any(duplicated(ob$prvdr_num)))
  cli::cli_alert_info("OB-service hospitals: {nrow(ob)}")

  ob$address_key <- canonical_address_key(ob$geocode_address_1, ob$geocode_city,
                                          ob$geocode_state, ob$geocode_zip)

  # READ-ONLY. This analysis consumes the isochrones cache; it does not own it,
  # and must not hold a write lock a concurrent isochrones run would block on.
  con <- dbConnect(duckdb::duckdb(), CACHE, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  cached <- dbGetQuery(con, "
    SELECT address_hash, latitude, longitude, county_fips AS cache_county_fips,
           geocoder_provenance, quality_score
    FROM geocoding_cache WHERE latitude IS NOT NULL AND longitude IS NOT NULL")

  hit <- ob %>% inner_join(cached, by = c("address_key" = "address_hash"),
                           relationship = "many-to-one")
  todo <- ob %>% filter(!address_key %in% cached$address_hash)
  cli::cli_alert_info("cache hits: {nrow(hit)} ({round(100*nrow(hit)/nrow(ob),1)}%); to geocode: {nrow(todo)}")

  geocoded <- NULL
  if (nrow(todo) > 0) {
    cli::cli_h2("Geocoding {nrow(todo)} addresses via the canonical wrapper")
    # Census batch takes id/street/city/state/zip. Batched at 8,000 -- below
    # the API's 10,000 ceiling -- and run inside the isochrones working
    # directory because the module still resolves helpers via here::here().
    batch_in <- todo %>%
      transmute(id = prvdr_num, street = geocode_address_1, city = geocode_city,
                state = geocode_state, zip = geocode_zip)
    geocoded <- with_iso_wd(census_batch_geocode(batch_in))
  }

  # COLUMN NAMES DIFFER BETWEEN THE TWO SOURCES and nothing warns you: the
  # DuckDB cache returns latitude/longitude, census_batch_geocode() returns
  # lat/lon. Counting only latitude/longitude reported "364 of 2,784 geocoded"
  # on a run where the Census API had in fact matched 2,054 -- a successful
  # batch presented as a near-total failure. Unify before anything counts.
  out <- bind_rows(
    hit %>% mutate(source = "cache"),
    if (!is.null(geocoded))
      todo %>% inner_join(as.data.frame(geocoded), by = c("prvdr_num" = "id")) %>%
        mutate(source = "geocoded")) %>%
    mutate(latitude  = coalesce(latitude, lat),
           longitude = coalesce(longitude, lon)) %>%
    select(-any_of(c("lat", "lon")))

  # Every hospital accounted for: geocoding may FAIL for a row, but it must not
  # make one disappear. A silently shorter table understates obstetric capacity.
  stopifnot(nrow(out) >= nrow(hit))
  n_coord <- sum(!is.na(out$latitude) & !is.na(out$longitude))
  cli::cli_alert_info("with coordinates: {n_coord} of {nrow(ob)} ({round(100*n_coord/nrow(ob),1)}%)")

  write_csv(out, OUT, na = "")
  manifest <- list(
    analysis = "OB-service hospital geocoding",
    geocoder = "isochrones::census_batch_geocode (canonical)",
    key_function = "isochrones::canonical_address_key (canonical)",
    isochrones_home = ISO,
    pos = list(path = POS, sha256 = sha256_of(POS)),
    hospitals = nrow(ob), cache_hits = nrow(hit), geocoded = nrow(todo),
    with_coordinates = n_coord,
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_json(manifest, paste0(OUT, ".manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("written: {OUT}")
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) run_geocode()
