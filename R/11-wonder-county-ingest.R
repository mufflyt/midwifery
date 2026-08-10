#!/usr/bin/env Rscript
#' @title Step 11: Ingest the CDC WONDER county x CNM/CM natality export
#'
#' @description
#' Reads the manual WONDER export of births attended by a Certified Nurse
#' Midwife (CNM/CM) by county of residence, 2016-2024, and joins it to the
#' county profile table.
#'
#' @section Why this file is a manual export and not an API pull:
#' The WONDER API refuses sub-national natality outright -- "Only national data
#' are available for this dataset when using the WONDER web service" -- so
#' county figures can only be produced through the web UI under its data-use
#' agreement. See R/lib/wonder_natality.R, which handles the national pulls the
#' API does allow.
#'
#' @section Two limits that are NOT the <10 suppression rule:
#' \enumerate{
#'   \item WONDER reports county-level natality only for counties with
#'     population >= 100,000. Every smaller county in a state is pooled into a
#'     single "Unidentified Counties" row. This is the binding constraint: it
#'     removes roughly four fifths of US counties, and it removes them by
#'     POPULATION, so the missing set is almost exactly the rural counties a
#'     midwifery access analysis is about. Suppression proper accounts for only
#'     a handful of additional cells.
#'   \item Connecticut 2022-2024 falls into "Unidentified Counties" because
#'     legacy-county population estimates do not exist for those years -- the
#'     same 2022 planning-region vintage break handled in R/03.
#' }
#' The pooled rows are RETAINED, not dropped: they carry real births that must
#' not silently vanish from state totals. They are simply not county-resolvable.
#'
#' @section Do not open the export in Numbers/Excel first:
#' The `County of Residence Code` column is a zero-padded FIPS string
#' ("01003"). Spreadsheet import coerces it to a number and strips the leading
#' zero, turning Alabama's 01003 into 1003, which then matches nothing. This
#' script reads the raw CSV as character and asserts the padding survived.
#'
#' Output : artifacts/county_profiles/county_cnm_births.csv
#'
#' @family step-functions
#' @concept county-profiles
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(cli); library(jsonlite)
})

source(file.path("R", "lib", "ct_county_crosswalk.R"))

ART  <- "artifacts"; OUT <- file.path(ART, "county_profiles")
# Vendored into the repo rather than read from ~/Downloads: the export is a
# manual, non-reproducible artifact (the API refuses sub-national natality), so
# an analysis that reads it from a user's download folder cannot be re-run by
# anyone else, or by this machine after a cleanup.
EXPORT <- Sys.getenv("WONDER_EXPORT",
                     file.path("data", "wonder", "natality_2016_2024_cnm_by_county.csv"))
PROFILES <- file.path(OUT, "county_birth_profiles.csv")

sha256_of <- function(p) sub(" .*$", "",
                             system2("shasum", c("-a", "256", shQuote(p)), stdout = TRUE)[1])

#' Read the WONDER export, keeping the footer's provenance
#' @keywords internal
#' @noRd
read_wonder_export <- function(path) {
  stopifnot(file.exists(path))
  raw <- readLines(path, warn = FALSE)

  # The footer is not decoration: it records the filter that defines what the
  # Births column COUNTS. Ingesting the table without it produces a column of
  # numbers with no stated meaning.
  attend <- grep("^\"Medical Attendant:", raw, value = TRUE)
  if (!length(attend)) {
    stop("Export footer has no 'Medical Attendant:' line. Refusing to guess ",
         "whether these are all births or midwife-attended births.", call. = FALSE)
  }
  attendant <- sub('^"Medical Attendant: (.*)"$', "\\1", attend[1])

  # Data rows end where the footer begins.
  last <- max(grep('^,"', raw))
  tbl <- read_csv(I(raw[seq_len(last)]), show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = col_character()))

  list(tbl = tbl, attendant = attendant,
       dataset = sub('^"Dataset: (.*)"$', "\\1",
                     grep("^\"Dataset:", raw, value = TRUE)[1]))
}

run_ingest <- function() {
  cli::cli_h2("Reading WONDER export")
  w <- read_wonder_export(EXPORT)
  cli::cli_alert_info("dataset  : {w$dataset}")
  cli::cli_alert_info("attendant: {w$attendant}")

  # The whole join depends on this filter meaning what we think it means.
  stopifnot(grepl("Nurse Midwife|CNM", w$attendant))

  d <- w$tbl %>%
    rename(county_label_wonder = `County of Residence`,
           GEOID = `County of Residence Code`,
           births_raw = Births) %>%
    mutate(
      pooled = grepl("Unidentified Counties", county_label_wonder),
      suppressed = grepl("^Suppressed$", births_raw, ignore.case = TRUE),
      # Suppressed cells are NA, never 0: a county with 1-9 midwife-attended
      # births is not a county with none, and treating it as zero would bias
      # every rate downward exactly where volumes are smallest.
      cnm_births_2016_2024 = if_else(suppressed, NA_real_,
                                     suppressed_to_num(births_raw)))

  # FIPS padding must survive; an unpadded code matches no county.
  ident <- d %>% filter(!pooled)
  stopifnot(all(nchar(ident$GEOID) == 5L))
  cli::cli_alert_success("FIPS codes are 5-character zero-padded ({nrow(ident)} identified counties)")

  prof <- read_csv(PROFILES, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(GEOID = col_character(), .default = col_guess()))

  # --- Connecticut: WONDER reports LEGACY counties, the spine uses 2022
  # planning regions. The mapping is many-to-many, so these rows are
  # APPORTIONED estimates, flagged as such, never presented as observations.
  ct_legacy <- ident %>% filter(GEOID %in% sprintf("090%02d", seq(1, 15, by = 2)))
  ident <- ident %>% filter(!GEOID %in% ct_legacy$GEOID)
  ct_app <- NULL
  if (nrow(ct_legacy)) {
    ct_app <- apportion_ct_legacy(ct_legacy, "GEOID", "cnm_births_2016_2024")
    cli::cli_alert_info(
      "CT: apportioned {format(sum(ct_legacy$cnm_births_2016_2024, na.rm=TRUE), big.mark=',')} legacy-county CNM births across {nrow(ct_app)} planning regions (weights = ACS women 15-44)")
    # CYCLE 4. suppressed = FALSE used to be hard-coded here, stamping every
    # apportioned row as an observation -- including rows derived from a legacy
    # county WONDER had suppressed. Suppression now propagates through
    # apportion_ct_legacy() as NA, so it is read back off the value rather than
    # asserted.
    ident <- bind_rows(ident, mutate(ct_app,
                                     suppressed = is.na(cnm_births_2016_2024)))
  }
  ident <- ident %>% mutate(ct_apportioned = coalesce(ct_apportioned, FALSE))

  unmatched <- setdiff(ident$GEOID, prof$GEOID)
  if (length(unmatched)) {
    cli::cli_alert_warning("{length(unmatched)} WONDER counties absent from the profile spine: {paste(head(unmatched,5), collapse=', ')}")
  } else {
    cli::cli_alert_success("every WONDER county now joins the profile spine")
  }

  joined <- prof %>%
    left_join(select(ident, GEOID, cnm_births_2016_2024, suppressed, ct_apportioned),
              by = "GEOID", relationship = "one-to-one") %>%
    mutate(ct_apportioned = coalesce(ct_apportioned, FALSE)) %>%
    mutate(
      wonder_county_reported = !is.na(cnm_births_2016_2024) | coalesce(suppressed, FALSE),
      # ACS births are a 12-month count; WONDER covers 9 birth years. Comparing
      # them requires putting both on the same footing.
      cnm_births_per_year = cnm_births_2016_2024 / 9,
      cnm_share_of_births_pct = if_else(
        !is.na(cnm_births_per_year) & !is.na(births_past_12mo) & births_past_12mo > 0,
        100 * cnm_births_per_year / births_past_12mo, NA_real_))

  stopifnot(nrow(joined) == nrow(prof), !any(duplicated(joined$GEOID)))

  pooled_births <- sum(d$cnm_births_2016_2024[d$pooled], na.rm = TRUE)
  ident_births  <- sum(ident$cnm_births_2016_2024, na.rm = TRUE)

  cli::cli_h2("Coverage of the WONDER export")
  cli::cli_alert_info("identified counties: {nrow(ident)} of {nrow(prof)} ({round(100*nrow(ident)/nrow(prof),1)}%)")
  cli::cli_alert_info("suppressed cells: {sum(ident$suppressed)}")
  cli::cli_alert_info("CNM births in identified counties: {format(ident_births, big.mark=',')}")
  cli::cli_alert_info("CNM births pooled into 'Unidentified Counties': {format(pooled_births, big.mark=',')} ({round(100*pooled_births/(pooled_births+ident_births),1)}% of the total)")

  write_csv(joined, file.path(OUT, "county_cnm_births.csv"), na = "")

  manifest <- list(
    analysis = "CDC WONDER county x CNM/CM natality ingest",
    dataset = w$dataset, attendant_filter = w$attendant,
    export = list(path = EXPORT, sha256 = sha256_of(EXPORT), rows = nrow(d)),
    identified_counties = nrow(ident),
    pooled_rows = sum(d$pooled),
    suppressed_cells = sum(ident$suppressed),
    cnm_births_identified = ident_births,
    cnm_births_pooled = pooled_births,
    county_reporting_threshold = "population >= 100,000; smaller counties pooled per state",
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_json(manifest, file.path(OUT, "wonder_ingest_manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("written: {file.path(OUT, 'county_cnm_births.csv')}")

  invisible(joined)
}

#' Parse a WONDER count, returning NA for any non-numeric marker
#' @keywords internal
#' @noRd
suppressed_to_num <- function(x) {
  v <- suppressWarnings(as.numeric(gsub(",", "", trimws(x))))
  v
}

if (identical(environment(), globalenv()) && !interactive()) run_ingest()
