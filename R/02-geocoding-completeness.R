#!/usr/bin/env Rscript
#' @title Step 02: Geocoding Completeness / Differential Missingness Audit
#'
#' @description
#' Answers the only question that decides whether county-level workforce
#' statistics are defensible: **is the geocoded subset a random sample of the
#' matched roster, or is it systematically different?**
#'
#' Produces completeness rates by state, rurality, and midwife characteristics,
#' so the residual missingness after NPPES + Healthgrades can be judged as
#' ignorable, weightable, or grounds for explicit restriction.
#'
#' @section The circularity this avoids:
#' RUCC is a COUNTY attribute, and county is derived from coordinates — so for
#' un-geocoded midwives it is missing by construction. Cross-tabulating
#' completeness by RUCC using only geocoded records would condition on the
#' outcome and always report 100%.
#'
#' The escape: 11,188 of the 11,196 un-geocoded matched midwives still carry a
#' practice ZIP from NPPES. ZIP -> county -> RUCC yields a rurality proxy that
#' is observable REGARDLESS of geocoding success, which is exactly what a
#' missingness analysis requires.
#'
#' @section Known limitation:
#' ZIP codes are USPS delivery routes; ZCTAs are Census tabulation areas. They
#' are not identical, and a ZIP spanning a county line is assigned here to the
#' county holding the largest share of its land area. This is the standard
#' approximation and is fine for stratifying missingness; it is NOT good enough
#' to assign a midwife to a county for the analysis itself. Coordinates remain
#' the only acceptable source for that.
#'
#' @section Interpretation — what a gradient does and does not establish:
#' A rurality gradient establishes that rural midwives are less likely to enter
#' the precisely geocoded analytic sample. It does NOT by itself establish the
#' direction or magnitude of bias in a county workforce RATE: some missing rural
#' providers belong to counties already represented, others to counties that
#' currently appear to have zero midwives. State the finding as "unadjusted
#' county estimates would disproportionately omit rural midwives and may
#' therefore systematically underestimate rural workforce availability" — not as
#' a demonstrated understatement.
#'
#' Weighting does not solve county ASSIGNMENT. Inverse-probability weights can
#' restore the expected NUMBER of providers represented by observed rural
#' midwives, supporting estimands like "X% of the workforce practices in
#' nonmetropolitan areas". They cannot say whether a missing provider belongs to
#' county A or neighbouring county B, so per-county rates remain the weaker
#' claim.
#'
#' Restriction to well-ascertained states is a SENSITIVITY analysis, not the
#' primary estimator: it converts a national workforce study into a convenience
#' sample and can still leave differential rural ascertainment within the
#' retained states.
#'
#' The correction model should be richer than the three RUCC categories. Because
#' geocoding probability is strongly tied to source-data quality (match tier
#' spans 42.9% Gold to 17.8% Lead), fit a person-level model on covariates
#' observable regardless of geocoding success:
#'   geocoded ~ rurality * match_tier + state + credential +
#'              certification_decade + amcb_status
#' then build stabilised weights, inspect their distribution, and prespecify
#' truncation. This script produces the descriptive centrepiece; it is not the
#' correction model.
#'
#' Inputs : midwives_geocoded.csv, data/county_base.csv,
#'          data/zcta_county_2020.txt, healthgrades_midwives.csv (optional)
#' Output : artifacts/geocoding_completeness_{state,rucc,characteristics}.csv
#'
#' @family step-functions
#' @concept missingness
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(cli)
})

DATA <- "data"; ART <- "artifacts"
dir.create(ART, showWarnings = FALSE)

pad5 <- function(x) str_pad(as.character(x), 5, "left", "0")

#' ZIP (approximated by ZCTA) -> county GEOID, largest-land-area wins
#'
#' @return [tibble] zip5, GEOID.
#' @keywords internal
#' @noRd
load_zip_county <- function() {
  f <- file.path(DATA, "zcta_county_2020.txt")
  if (!file.exists(f)) {
    stop("Missing ", f, ". Download the Census ZCTA-county relationship file.",
         call. = FALSE)
  }
  read_delim(f, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
    filter(!is.na(GEOID_ZCTA5_20), !is.na(GEOID_COUNTY_20)) %>%
    transmute(zip5 = pad5(GEOID_ZCTA5_20),
              GEOID = pad5(GEOID_COUNTY_20),
              land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
    group_by(zip5) %>%
    slice_max(land, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(zip5, GEOID)
}

#' Completeness rate with a Wilson score interval
#'
#' Wilson rather than Wald: several strata have small denominators, where the
#' normal approximation produces intervals that run past 0 or 1.
#'
#' @param df [data.frame]: rows with a logical `geocoded`.
#' @param ... grouping columns.
#' @return [tibble] n, n_geocoded, pct, ci_low, ci_high.
#' @keywords internal
#' @noRd
completeness <- function(df, ...) {
  df %>%
    group_by(...) %>%
    summarise(n = n(), n_geocoded = sum(geocoded), .groups = "drop") %>%
    mutate(pct = 100 * n_geocoded / n,
           z = 1.96,
           p = n_geocoded / n,
           denom = 1 + z^2 / n,
           centre = (p + z^2 / (2 * n)) / denom,
           halfw = z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom,
           ci_low = 100 * pmax(0, centre - halfw),
           ci_high = 100 * pmin(1, centre + halfw)) %>%
    select(-z, -p, -denom, -centre, -halfw) %>%
    arrange(desc(n))
}

build_completeness <- function() {
  g <- read_csv("midwives_geocoded.csv", show_col_types = FALSE)
  cb <- read_csv(file.path(DATA, "county_base.csv"), show_col_types = FALSE,
                 col_types = cols(GEOID = col_character()))

  # Denominator is the MATCHED roster: a midwife with no NPI has no address to
  # geocode, so counting them as "missing geocode" would conflate two different
  # failures (matching vs geocoding) and overstate this one.
  m <- g %>% filter(!is.na(npi)) %>% mutate(geocoded = !is.na(latitude))

  # Stage 3+: ascertainment is COUNTY resolution (county_best), not coordinate
  # possession. Same strata, same code path, different numerator -- so the
  # stage table stays a like-for-like comparison of what each stage achieved.
  if (nzchar(Sys.getenv("ASCERTAIN_FROM_GEOGRAPHY")) &&
      file.exists("midwives_geography.csv")) {
    gg <- read_csv("midwives_geography.csv", show_col_types = FALSE,
                   col_types = cols(.default = col_character())) %>%
      select(certification_number, county_best) %>%
      distinct(certification_number, .keep_all = TRUE)
    m <- m %>%
      left_join(gg, by = "certification_number") %>%
      mutate(geocoded = !is.na(county_best))
    cli::cli_alert_info("Ascertainment = county_best (geography hierarchy), not raw coordinates")
  }

  # Optional: treat a Healthgrades address as recovered coverage, so the table
  # reports completeness AFTER supplementary evidence rather than before.
  hg_ids <- character(0)
  if (file.exists("healthgrades_midwives.csv")) {
    hg <- read_csv("healthgrades_midwives.csv", show_col_types = FALSE)
    if ("hg_status" %in% names(hg)) {
      hg_ids <- hg %>% filter(hg_status == "ok", !is.na(hg_lat)) %>%
        pull(certification_number) %>% unique() %>% as.character()
    }
  }
  m <- m %>% mutate(
    geocoded_hg = geocoded | as.character(certification_number) %in% hg_ids)

  # Rurality proxy observable for geocoded and un-geocoded alike.
  zc <- load_zip_county()
  m <- m %>%
    mutate(zip5 = pad5(str_sub(str_remove_all(practice_zip, "[^0-9]"), 1, 5))) %>%
    left_join(zc, by = "zip5", suffix = c("", ".zip")) %>%
    mutate(GEOID_proxy = coalesce(GEOID.zip, GEOID)) %>%
    left_join(select(cb, GEOID, rucc_2023, state_cb = state),
              by = c("GEOID_proxy" = "GEOID")) %>%
    mutate(rucc_cat = case_when(
      rucc_2023 %in% 1:3 ~ "Metro (RUCC 1-3)",
      rucc_2023 %in% 4:6 ~ "Nonmetro, adjacent (4-6)",
      rucc_2023 %in% 7:9 ~ "Nonmetro, remote (7-9)",
      TRUE               ~ "Unknown"))

  cli::cli_h2("Geocoding completeness — matched roster")
  cli::cli_alert_info("matched {nrow(m)} | geocoded {sum(m$geocoded)} ({round(100*mean(m$geocoded),1)}%) | +Healthgrades {sum(m$geocoded_hg)} ({round(100*mean(m$geocoded_hg),1)}%)")
  cli::cli_alert_info("rurality proxy resolved for {sum(m$rucc_cat != 'Unknown')} of {nrow(m)}")

  by_rucc <- completeness(m, rucc_cat)
  by_state <- completeness(m, practice_state)
  by_char <- bind_rows(
    completeness(m, status) %>% rename(level = status) %>% mutate(variable = "AMCB status"),
    completeness(m, certification) %>% rename(level = certification) %>% mutate(variable = "credential"),
    completeness(m, match_tier) %>% rename(level = match_tier) %>% mutate(variable = "match tier"),
    completeness(mutate(m, cert_decade = paste0(
      substr(certification_date, nchar(certification_date) - 3, nchar(certification_date) - 1), "0s")),
      cert_decade) %>% rename(level = cert_decade) %>% mutate(variable = "certification decade")
  ) %>% select(variable, level, n, n_geocoded, pct, ci_low, ci_high)

  write_csv(by_rucc, file.path(ART, "geocoding_completeness_rucc.csv"))
  write_csv(by_state, file.path(ART, "geocoding_completeness_state.csv"))
  write_csv(by_char, file.path(ART, "geocoding_completeness_characteristics.csv"))

  cli::cli_h3("By rurality (ZIP-derived, observable regardless of geocoding)")
  print(as.data.frame(by_rucc %>% mutate(across(pct:ci_high, ~ round(.x, 1)))))

  cli::cli_h3("By characteristic")
  print(as.data.frame(by_char %>% mutate(across(pct:ci_high, ~ round(.x, 1)))), row.names = FALSE)

  cli::cli_h3("By state (10 lowest completeness, n >= 50)")
  print(as.data.frame(by_state %>% filter(n >= 50) %>% arrange(pct) %>% head(10) %>%
                        mutate(across(pct:ci_high, ~ round(.x, 1)))))

  known <- by_rucc %>% filter(rucc_cat != "Unknown")
  spread <- max(known$pct) - min(known$pct)
  # Report the absolute difference with its CI. Deliberately NOT "the intervals
  # do not overlap" -- CI overlap is not a valid inferential test, and the
  # gradient plus the multivariable missingness model carry the argument.
  hi <- known %>% filter(pct == max(pct)); lo <- known %>% filter(pct == min(pct))
  se <- sqrt(hi$pct/100 * (1 - hi$pct/100) / hi$n +
               lo$pct/100 * (1 - lo$pct/100) / lo$n) * 100
  cli::cli_alert_info(
    "Absolute difference {hi$rucc_cat} vs {lo$rucc_cat}: {round(spread,1)} pp (95% CI {round(spread - 1.96*se,1)} to {round(spread + 1.96*se,1)})")
  cli::cli_alert(if (spread >= 10) {
    "Missingness is DIFFERENTIAL by rurality -- treat geographic ascertainment as a first-order design problem, not a supplemental sensitivity."
  } else {
    "Missingness is close to uniform across rurality strata."
  })

  # Stage-specific ascertainment: appended, never overwritten, so the methods
  # can show empirically whether each enrichment source improves GEOGRAPHIC
  # ascertainment or merely adds metropolitan sample.
  stage <- Sys.getenv("COMPLETENESS_STAGE", unset = "unlabelled")
  row <- known %>%
    select(rucc_cat, pct) %>%
    tidyr::pivot_wider(names_from = rucc_cat, values_from = pct) %>%
    mutate(stage = stage, n_matched = nrow(m), rural_gap_pp = -spread) %>%
    relocate(stage)
  hist_f <- file.path(ART, "geocoding_completeness_by_stage.csv")
  write_csv(row, hist_f, append = file.exists(hist_f))
  cli::cli_alert_success("stage '{stage}' appended to {hist_f}")

  invisible(list(rucc = by_rucc, state = by_state, characteristics = by_char))
}

if (identical(environment(), globalenv()) && !interactive()) build_completeness()
