#!/usr/bin/env Rscript
#' @title Step 03: County Geography Hierarchy (exact -> unambiguous ZIP)
#'
#' @description
#' Builds two parallel county variables against the frozen Stage 2 roster, so
#' every county-level finding can be run twice and compared:
#'
#' \describe{
#'   \item{\code{county_exact}}{County from coordinate/street-level evidence
#'     ONLY. The conservative geography.}
#'   \item{\code{county_best}}{\code{county_exact}, then ZIPs that map to
#'     exactly one county. The best-supported geography.}
#' }
#'
#' Every midwife keeps \code{geo_source}, \code{geo_precision} and
#' \code{geo_ambiguity}, so any downstream analysis can restrict or stratify on
#' provenance rather than trusting a single collapsed column.
#'
#' @section What is deliberately NOT done here:
#' \itemize{
#'   \item Multi-county ZIPs stay \strong{unresolved}. Largest-land-area
#'     assignment would manufacture precision: only ~5% of the un-geocoded are
#'     materially ambiguous, so preserving that uncertainty is cheap and
#'     honest. A business-address-ratio allocation (HUD USPS crosswalk) is the
#'     right eventual answer for a practice-location estimand; population
#'     weighting answers a different question ("where residents live").
#'   \item Healthgrades is not merged -- it is its own stage, so its effect on
#'     rural ascertainment can be measured rather than assumed.
#'   \item No IPW. Ascertainment must be measured before it is corrected.
#' }
#'
#' @section Internal validation:
#' Midwives holding BOTH exact coordinates and a unique-ZIP county form a
#' validation sample for the fallback. Coverage is not evidence; AGREEMENT is.
#' If the two assignments disagree at more than a trivial rate, `county_best`
#' is not validated and the run stops short of endorsing it.
#'
#' Inputs : artifacts/frozen_stage2/midwives_with_nppes.csv,
#'          midwives_geocoded.csv, data/zcta_county_2020.txt
#' Output : midwives_geography.csv,
#'          artifacts/geography_class_counts.csv,
#'          artifacts/zip_fallback_validation.csv
#'
#' @family step-functions
#' @concept geography
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(cli)
})

DATA <- "data"; ART <- "artifacts"
FROZEN <- file.path(ART, "frozen_stage2", "midwives_with_nppes.csv")
dir.create(ART, showWarnings = FALSE)

pad5 <- function(x) str_pad(as.character(x), 5, "left", "0")

#' ZIP -> county with the ambiguity retained
#'
#' Returns one row per ZIP carrying the county count and, when that count is 1,
#' the county. Multi-county ZIPs deliberately carry `GEOID = NA`: the caller
#' must not be able to reach a county for them by accident.
#'
#' @return [tibble] zip5, n_county, GEOID_unique, top_land_share.
#' @keywords internal
#' @noRd
zip_county_unique <- function() {
  f <- file.path(DATA, "zcta_county_2020.txt")
  if (!file.exists(f)) stop("Missing ", f, call. = FALSE)
  read_delim(f, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
    filter(!is.na(GEOID_ZCTA5_20), !is.na(GEOID_COUNTY_20)) %>%
    transmute(zip5 = pad5(GEOID_ZCTA5_20), GEOID = pad5(GEOID_COUNTY_20),
              land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
    group_by(zip5) %>%
    summarise(n_county = n(),
              top_land_share = max(land) / sum(land),
              GEOID_unique = if (n() == 1L) first(GEOID) else NA_character_,
              .groups = "drop")
}

build_geography <- function() {
  if (!file.exists(FROZEN)) {
    stop("Frozen Stage 2 roster not found: ", FROZEN,
         ". Run the matcher and freeze before Stage 3.", call. = FALSE)
  }
  roster <- read_csv(FROZEN, show_col_types = FALSE)
  geo <- read_csv("midwives_geocoded.csv", show_col_types = FALSE)
  # The analysis universe. A county GEOID absent from here is unusable no
  # matter how confidently it was derived.
  cb <- read_csv(file.path(DATA, "county_base.csv"), show_col_types = FALSE,
                 col_types = cols(GEOID = col_character()))

  coords <- geo %>%
    select(certification_number, latitude, longitude, GEOID_coord = GEOID,
           quality_score, geocode_match) %>%
    distinct(certification_number, .keep_all = TRUE)

  zc <- zip_county_unique()

  m <- roster %>%
    filter(!is.na(npi)) %>%
    left_join(coords, by = "certification_number") %>%
    mutate(zip5 = pad5(str_sub(str_remove_all(practice_zip, "[^0-9]"), 1, 5))) %>%
    left_join(zc, by = "zip5")

  m <- m %>%
    mutate(
      has_exact = !is.na(GEOID_coord),
      # VINTAGE GUARD (found by the validation check below): the ZCTA-county
      # relationship file is 2020, but county_base.csv is built from tigris
      # 2023. Connecticut replaced counties with PLANNING REGIONS in 2022, so
      # the crosswalk yields 09001/09003/... while the analysis universe holds
      # 09110/09170/... Those GEOIDs describe the same ground under two
      # vintages, but they do not join, and emitting them would silently drop
      # 189 Connecticut midwives at the county merge. A unique-ZIP county that
      # is not in the analysis universe is treated as unresolved, not assigned.
      zip_in_universe = GEOID_unique %in% cb$GEOID,
      has_uniq_zip = !is.na(GEOID_unique) & zip_in_universe,

      county_exact = GEOID_coord,

      county_best = case_when(
        has_exact    ~ GEOID_coord,
        has_uniq_zip ~ GEOID_unique,
        TRUE         ~ NA_character_),

      geo_source = case_when(
        has_exact                  ~ "coordinate",
        has_uniq_zip               ~ "zip_unique",
        # BEFORE zip_multi_county: a vintage-mismatched ZIP is unambiguous in
        # the crosswalk, so it would otherwise be mislabelled "ambiguous" and
        # two very different problems would be conflated in the class counts.
        !is.na(GEOID_unique) & !zip_in_universe ~ "zip_vintage_mismatch",
        !is.na(n_county)           ~ "zip_multi_county",
        !is.na(zip5) & zip5 != "NANANANAN" ~ "zip_not_in_crosswalk",
        TRUE                       ~ "no_geography"),

      geo_precision = case_when(
        geo_source == "coordinate"  ~ "point",
        geo_source == "zip_unique"  ~ "county",
        TRUE                        ~ "none"),

      # Ambiguity is recorded even for resolved rows: a coordinate row whose ZIP
      # spans counties is still worth flagging, because it is the population
      # where a future ZIP-based method would be least trustworthy.
      geo_ambiguity = case_when(
        is.na(n_county)   ~ "zip_unmapped",
        n_county == 1     ~ "unambiguous",
        top_land_share >= 0.8 ~ "multi_county_dominant",
        TRUE              ~ "multi_county_split"))

  # --- Class counts --------------------------------------------------------
  classes <- m %>%
    mutate(geo_class = case_when(
      geo_source == "coordinate"       ~ "1_exact_coordinate",
      geo_source == "zip_unique"       ~ "2_unambiguous_zip_fallback",
      geo_source == "zip_multi_county" ~ "3_ambiguous_zip_unresolved",
      geo_source == "zip_vintage_mismatch" ~ "4_zip_vintage_mismatch",
      TRUE                             ~ "5_completely_unresolved")) %>%
    count(geo_class, name = "n") %>%
    mutate(pct = round(100 * n / sum(n), 1))

  cli::cli_h2("Geography classes (frozen Stage 2 matched roster, n = {nrow(m)})")
  print(as.data.frame(classes), row.names = FALSE)
  write_csv(classes, file.path(ART, "geography_class_counts.csv"))

  cli::cli_alert_info(
    "county_exact resolved: {sum(!is.na(m$county_exact))} ({round(100*mean(!is.na(m$county_exact)),1)}%)")
  cli::cli_alert_info(
    "county_best  resolved: {sum(!is.na(m$county_best))} ({round(100*mean(!is.na(m$county_best)),1)}%)")

  # --- Internal validation: does unique-ZIP county agree with coordinates? --
  # Validation uses every row with BOTH sources, including vintage-mismatched
  # ones, so the raw figure is not flattered by excluding known-hard cases.
  val <- m %>% filter(has_exact, !is.na(GEOID_unique)) %>%
    mutate(agree = GEOID_coord == GEOID_unique,
           vintage_artifact = !zip_in_universe)

  n_val <- nrow(val); n_agree <- sum(val$agree)
  pct_agree <- 100 * n_agree / n_val
  # Wilson interval: the decision hinges on this number, so report it with
  # uncertainty rather than as a point estimate.
  z <- 1.96; p <- n_agree / n_val
  den <- 1 + z^2 / n_val
  ctr <- (p + z^2 / (2 * n_val)) / den
  hw <- z * sqrt(p * (1 - p) / n_val + z^2 / (4 * n_val^2)) / den

  cli::cli_h2("ZIP-fallback validation against exact geography")
  cli::cli_alert_info("RAW agreement {n_agree}/{n_val} = {round(pct_agree,2)}% (95% CI {round(100*(ctr-hw),2)}-{round(100*(ctr+hw),2)})")
  usable <- val %>% filter(!vintage_artifact)
  cli::cli_alert_info(
    "Excluding vintage-mismatched rows (which are never assigned a county): {sum(usable$agree)}/{nrow(usable)} = {round(100*mean(usable$agree),2)}%")

  disc <- val %>% filter(!agree)
  if (nrow(disc) > 0) {
    by_rucc <- disc %>% count(geo_ambiguity, name = "n_discordant")
    by_state <- disc %>% count(practice_state, sort = TRUE, name = "n") %>% head(8)
    by_tier <- disc %>% count(match_tier, sort = TRUE, name = "n")
    cli::cli_h3("Discordant cases: {nrow(disc)}")
    print(as.data.frame(by_rucc), row.names = FALSE)
    print(as.data.frame(by_tier), row.names = FALSE)
    print(as.data.frame(by_state), row.names = FALSE)
    write_csv(
      disc %>% select(certification_number, npi, practice_state, practice_zip,
                      GEOID_coord, GEOID_unique, quality_score, geocode_match,
                      match_tier, geo_ambiguity),
      file.path(ART, "zip_fallback_discordant.csv"))
  }

  write_csv(tibble(n_validation = n_val, n_agree = n_agree,
                   pct_agree = pct_agree,
                   ci_low = 100 * (ctr - hw), ci_high = 100 * (ctr + hw)),
            file.path(ART, "zip_fallback_validation.csv"))

  out <- m %>%
    select(certification_number, npi, practice_state, practice_zip,
           latitude, longitude, quality_score, geocode_match,
           county_exact, county_best, geo_source, geo_precision, geo_ambiguity,
           zip_n_county = n_county, zip_top_land_share = top_land_share)
  write_csv(out, "midwives_geography.csv", na = "")
  cli::cli_alert_success("midwives_geography.csv written ({nrow(out)} rows)")

  # The gate the instructions asked for: coverage is not evidence, agreement is.
  if (pct_agree < 95) {
    cli::cli_alert_danger(
      "Agreement {round(pct_agree,2)}% is below 95%: ZIP fallback is NOT validated. Do not treat county_best as the primary geography until the discordance is explained.")
  } else {
    cli::cli_alert_success(
      "Agreement {round(pct_agree,2)}%: unique-ZIP county reproduces coordinate-derived county empirically, not merely by logical argument.")
  }

  invisible(list(data = out, classes = classes, agreement = pct_agree))
}

if (identical(environment(), globalenv()) && !interactive()) build_geography()
