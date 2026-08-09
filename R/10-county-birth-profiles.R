#!/usr/bin/env Rscript
#' @title Step 10: County birth + midwifery profiles, with narrative sentences
#'
#' @description
#' Assembles the county-level birth statistics that bear on midwifery care and
#' renders two to four plain sentences per county.
#'
#' @section How CDC WONDER enters, and what it cannot cover:
#' Midwife-attended births come from the WONDER county x CNM/CM export ingested
#' by R/11, joined here when present. WONDER publishes county natality only for
#' counties of 100,000+ residents, pooling the rest by state, so it covers 579
#' of 3,235 counties. The exclusion is by POPULATION, which removes almost
#' exactly the rural counties a midwifery access analysis is about.
#'
#' The sentences therefore distinguish three states that must never collapse
#' into "no midwife-attended births": a published count, a SUPPRESSED count
#' (1-9, not zero), and a county WONDER does not report separately at all.
#' Every other measure is complete for all 3,235 counties, or is a count we
#' produced ourselves and characterise as such.
#'
#' @section The midwife counts are an UNDERCOUNT, and the sentences say so:
#' Midwife counts come from the AMCB roster after NPI linkage and geocoding.
#' Each stage loses people, so a county's count is the number of AMCB-certified
#' midwives we could LOCATE there, not the number who practise there. Two
#' consequences are enforced in the wording:
#' \itemize{
#'   \item A county with no located midwife is never described as having none.
#'     It is described as having none \emph{in the linked cohort}.
#'   \item Ratios are labelled as located-midwife ratios, never as supply.
#' }
#' Non-AMCB midwives (CPMs, CMs certified elsewhere) are out of scope entirely.
#'
#' Output : artifacts/county_profiles/{county_birth_profiles.csv,
#'          county_sentences.csv,manifest.json}
#'
#' @family step-functions
#' @concept county-profiles
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(cli); library(jsonlite)
})

# The variety-sentence engine is CANONICAL in mufflyt/isochrones
# (R/variety_sentences.R, PR #519). It is loaded, never copied: a second
# definition would drift from the one the urogyn maps use.
source(file.path("R", "lib", "isochrones_dep.R"))
source(file.path("R", "lib", "ob_hospitals.R"))
load_variety_sentence_engine(quiet = TRUE)

# Rank threshold for superlatives. A county ranked 1,600th of 3,235 is not
# interesting, and asserting a rank for every county would imply precision the
# underlying estimates do not carry.
SUPERLATIVE_N <- 10L

ART <- "artifacts"; OUT <- file.path(ART, "county_profiles")
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

BASE <- file.path("data", "county_base.csv")
# The FROZEN geography artifact, not the live one: these profiles are an
# analysis, and analyses read frozen inputs (see R/05-stage-progression.R).
GEO  <- file.path(ART, "midwives_geography_FROZEN.csv")

sha256_of <- function(p) sub(" .*$", "",
                             system2("shasum", c("-a", "256", shQuote(p)), stdout = TRUE)[1])

#' Format a number for prose, returning NULL when unusable
#' @keywords internal
#' @noRd
fmt <- function(x, digits = 0, big = TRUE) {
  if (is.null(x) || length(x) != 1L || is.na(x)) return(NULL)
  formatC(round(x, digits), format = "f", digits = digits,
          big.mark = if (big) "," else "")
}

RUCC_LABEL <- c(
  "1" = "a metro county in a large metro area (1 million+)",
  "2" = "a metro county in a medium metro area (250,000-1 million)",
  "3" = "a metro county in a small metro area (under 250,000)",
  "4" = "a nonmetro county with a large urban population, adjacent to a metro area",
  "5" = "a nonmetro county with a large urban population, not adjacent to a metro area",
  "6" = "a nonmetro county with a small urban population, adjacent to a metro area",
  "7" = "a nonmetro county with a small urban population, not adjacent to a metro area",
  "8" = "a completely rural county, adjacent to a metro area",
  "9" = "a completely rural county, not adjacent to a metro area")

#' Render the sentences for one county
#'
#' Structure follows the urogyn county summaries in isochrones: a place-type
#' LEAD, an always-present SPINE (there, drive time to the nearest provider;
#' here, midwifery care), then a deterministically ROTATED pool of context
#' facts so neighbouring counties on a choropleth emphasise a different mix.
#' Superlatives are added only at the extremes, where "the 4th-highest" is
#' informative rather than noise.
#' @keywords internal
#' @noRd
county_sentences <- function(r, n_counties) {
  # A: identity and place type. RUCC is missing for territories and for
  # counties added since the 2023 vintage; [[ ]] on an absent key errors.
  geo <- unname(RUCC_LABEL[as.character(r$rucc_2023)])
  if (length(geo) != 1L || is.na(geo)) geo <- NULL
  births <- fmt(r$births_past_12mo); women <- fmt(r$women_15_44)
  a <- if (!is.null(geo) && !is.null(births) && !is.null(women)) {
    sprintf("%s is %s, home to %s women aged 15-44, with about %s births in the past 12 months.",
            r$county_label, geo, women, births)
  } else if (!is.null(births)) {
    sprintf("%s recorded about %s births in the past 12 months.", r$county_label, births)
  } else {
    sprintf("%s.", r$county_label)
  }

  # B: the midwifery spine, always present. Phrased as ASCERTAINMENT, never as
  # supply: the count is midwives we could locate after roster linkage and
  # geocoding, so a zero is "none located", not "none practising".
  b <- if (r$n_midwives == 0) {
    paste0("No AMCB-certified nurse-midwife in the linked cohort could be located here, ",
           "which reflects roster, linkage and geocoding coverage as much as who practises here.")
  } else {
    tail_bits <- c(
      if (!is.null(fmt(r$midwives_per_10k_women, 1)))
        sprintf("%s per 10,000 women aged 15-44", fmt(r$midwives_per_10k_women, 1)),
      if (!is.null(fmt(r$births_per_midwife)))
        sprintf("roughly %s births per located midwife", fmt(r$births_per_midwife)))
    sprintf("%s AMCB-certified nurse-midwi%s located here%s%s.",
            fmt(r$n_midwives), if (r$n_midwives == 1) "fe was" else "ves were",
            if (length(tail_bits)) " -- " else "", oxford_join(tail_bits))
  }

  # C: midwife-attended births. Three states that must NEVER collapse into
  # "no midwife-attended births": published, suppressed (1-9, not zero), and
  # not reported separately (WONDER publishes only counties of 100,000+).
  cc <- if (!is.null(r$cnm_births_2016_2024) && !is.na(r$cnm_births_2016_2024)) {
    share <- fmt(r$cnm_share_of_births_pct, 1)
    sprintf("CDC WONDER records %s births attended by a certified nurse-midwife here over 2016-2024%s%s.",
            fmt(r$cnm_births_2016_2024),
            if (!is.null(share)) sprintf(", about %s%% of recent births", share) else "",
            if (isTRUE(r$ct_apportioned))
              " (apportioned from Connecticut's legacy counties, so an estimate rather than a count)" else "")
  } else if (isTRUE(r$wonder_county_reported)) {
    paste0("CDC WONDER suppressed the midwife-attended birth count for this county, ",
           "meaning it is between 1 and 9 -- not zero.")
  } else {
    paste0("CDC WONDER does not report this county separately: it publishes county natality ",
           "only for counties of 100,000 or more residents and pools the rest by state, so ",
           "midwife-attended births here are unpublished, not absent.")
  }

  # D: rotating context pool. mm_rotate_facts() seeds on the FIPS, so a county
  # always shows the same facts while adjacent counties start at a different
  # offset -- variety across the map, stability across rebuilds.
  pool <- c(
    if (!is.null(fmt(r$general_fertility_rate, 1)))
      sprintf("a general fertility rate of %s per 1,000 women aged 15-44", fmt(r$general_fertility_rate, 1)),
    if (!is.null(fmt(r$teen_birth_rate, 1)))
      sprintf("a teen birth rate of %s per 1,000", fmt(r$teen_birth_rate, 1)),
    if (!is.null(fmt(100 * r$pct_low_birth_weight, 1)))
      sprintf("%s%% of births low birth weight", fmt(100 * r$pct_low_birth_weight, 1)),
    if (!is.null(fmt(r$infant_mortality_per_1k, 1)))
      sprintf("an infant mortality rate of %s per 1,000", fmt(r$infant_mortality_per_1k, 1)),
    if (!is.null(fmt(r$pct_uninsured, 0)))
      sprintf("%s%% of residents uninsured", fmt(r$pct_uninsured, 0)),
    if (!is.null(fmt(r$median_hh_income)))
      sprintf("a median household income of $%s", fmt(r$median_hh_income)),
    # UNITS: pct_below_poverty is ALREADY a percentage (1.7-64.7), unlike
    # pct_low_birth_weight and svi_overall_pctile which are proportions.
    if (!is.null(fmt(r$pct_below_poverty, 0)))
      sprintf("a %s%% poverty rate", fmt(r$pct_below_poverty, 0)),
    # MISNAMED COLUMN: county_base$pcp_per_100k holds a PER-CAPITA rate
    # (0-0.006), not a per-100,000 rate. Denver 0.00130 -> 130 per 100k, Cook
    # 92, Van Zandt 8, against CHR's ~55-80 national -- so the scale is right
    # and the name is wrong. Printing it unscaled rendered every county as
    # "0 primary care physicians per 100,000 residents".
    if (!is.null(fmt(1e5 * r$pcp_per_100k, 0)))
      sprintf("%s primary care physicians per 100,000 residents", fmt(1e5 * r$pcp_per_100k, 0)),
    if (!is.null(fmt(100 * r$svi_overall_pctile, 0)))
      sprintf("a social vulnerability index at the %s percentile nationally",
              format_ordinal(round(100 * r$svi_overall_pctile))),
    if (!is.null(fmt(100 * r$pct_rural, 0)))
      sprintf("a %s%% rural population", fmt(100 * r$pct_rural, 0)),
    if (!is.null(r$pop_density_sq_mi) && !is.na(r$pop_density_sq_mi))
      sprintf("about %s residents per square mile", density_number(r$pop_density_sq_mi)),
    # Reported obstetric capacity. Phrased as "reporting obstetric services"
    # because a hospital with no OB code has not said "no" -- it has said
    # nothing, and that silence is commonest in small rural counties.
    if (!is.null(r$n_hosp_ob) && r$n_hosp_ob > 0)
      sprintf("%s hospital%s reporting obstetric services", fmt(r$n_hosp_ob),
              if (r$n_hosp_ob > 1) "s" else ""),
    if (!is.null(r$n_hosp_active) && r$n_hosp_active > 0 && r$n_hosp_ob == 0)
      sprintf("%s active hospital%s, none of which reports obstetric services",
              fmt(r$n_hosp_active), if (r$n_hosp_active > 1) "s" else ""))

  parts <- c(a, b, cc)
  pick <- mm_rotate_facts(pool, r$GEOID, 3)
  if (length(pick)) parts <- c(parts, sprintf("It has %s.", oxford_join(pick)))

  # E: superlatives, only at the extremes. A county ranked 1,600th of 3,235 is
  # not interesting; asserting a rank for every county would be noise and would
  # imply precision the underlying estimates do not carry.
  sup <- c(
    if (!is.na(r$rank_mw_high) && r$rank_mw_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_mw_high, n_counties,
                            "density of located nurse-midwives", "high", "county", "counties"),
    if (!is.na(r$rank_cnm_high) && r$rank_cnm_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_cnm_high, n_counties,
                            "share of births attended by a nurse-midwife", "high", "county", "counties"),
    if (!is.na(r$rank_births_high) && r$rank_births_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_births_high, n_counties,
                            "births", "most", "county", "counties"),
    if (!is.na(r$rank_gfr_high) && r$rank_gfr_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_gfr_high, n_counties,
                            "general fertility rate", "high", "county", "counties"))
  if (length(sup)) parts <- c(parts, sprintf("That is %s.", oxford_join(sup)))

  paste(parts, collapse = " ")
}

#' Ordinal suffix
#' @keywords internal
#' @noRd
scales_ord <- function(n) {
  n <- round(n)
  if (n %% 100 %in% 11:13) return("th")
  switch(as.character(n %% 10), "1" = "st", "2" = "nd", "3" = "rd", "th")
}

run_profiles <- function() {
  stopifnot(file.exists(BASE), file.exists(GEO))
  cli::cli_h2("Loading pinned inputs")

  base <- read_csv(BASE, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(GEOID = col_character(), .default = col_guess()))

  # Fold in the WONDER county x CNM ingest (R/11) when it has been produced, so
  # the sentences carry every measure we hold rather than a subset. Re-running
  # R/10 alone stays valid: the midwife-attended clause degrades to the
  # "not reported separately" wording rather than erroring.
  # Obstetric-service hospitals, exact at county level (POS carries county
  # FIPS). A missing OB code is "unknown", never "no" -- see R/lib/ob_hospitals.R.
  ob <- build_ob_hospital_counts()
  base <- left_join(base, ob, by = "GEOID", relationship = "one-to-one") %>%
    mutate(across(c(n_hosp_active, n_hosp_ob, n_hosp_ob_unknown), ~ coalesce(.x, 0L)))
  cli::cli_alert_info("counties with >=1 obstetric-service hospital: {sum(base$n_hosp_ob > 0)}")

  wonder_county <- file.path(OUT, "county_cnm_births.csv")
  if (file.exists(wonder_county)) {
    wc <- read_csv(wonder_county, show_col_types = FALSE, progress = FALSE,
                   col_types = cols(GEOID = col_character(), .default = col_guess())) %>%
      select(GEOID, cnm_births_2016_2024, cnm_share_of_births_pct,
             wonder_county_reported, ct_apportioned)
    base <- left_join(base, wc, by = "GEOID", relationship = "one-to-one")
    cli::cli_alert_info("WONDER CNM births joined for {sum(!is.na(base$cnm_births_2016_2024))} counties")
  }
  geo <- read_csv(GEO, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = col_character()))

  n_roster <- nrow(geo)
  n_located <- sum(!is.na(geo$county_best))

  mw <- geo %>%
    filter(!is.na(county_best)) %>%
    count(county_best, name = "n_midwives") %>%
    rename(GEOID = county_best)

  # A midwife county that is absent from the county spine would be silently
  # dropped by a left join and its midwives would vanish from every total.
  stopifnot(all(mw$GEOID %in% base$GEOID))

  prof <- base %>%
    left_join(mw, by = "GEOID", relationship = "one-to-one") %>%
    mutate(
      n_midwives = coalesce(n_midwives, 0L),
      county_label = paste0(county_name, ", ", state),
      midwives_per_10k_women = if_else(!is.na(women_15_44) & women_15_44 > 0,
                                       1e4 * n_midwives / women_15_44, NA_real_),
      births_per_midwife = if_else(n_midwives > 0 & !is.na(births_past_12mo),
                                   births_past_12mo / n_midwives, NA_real_),
      # A county with births but no located midwife is the row worth surfacing;
      # it is a candidate for follow-up, NOT an established care desert.
      no_located_midwife_with_births = n_midwives == 0 &
        !is.na(births_past_12mo) & births_past_12mo > 0)

  # Every midwife with a county must survive into exactly one county row.
  stopifnot(
    nrow(prof) == nrow(base),
    sum(prof$n_midwives) == n_located,
    !any(duplicated(prof$GEOID)))
  cli::cli_alert_success(
    "Join invariants passed: {nrow(prof)} counties, all {n_located} located midwives retained.")

  # Ranks for the superlative clause. mm_rank() takes the MINIMUM rank on ties,
  # so two joint-highest counties are both "the highest" rather than 1st and
  # 2nd -- it never asserts an order the data does not support.
  prof <- prof %>%
    mutate(
      rank_mw_high     = mm_rank(midwives_per_10k_women),
      rank_cnm_high    = mm_rank(cnm_share_of_births_pct),
      rank_births_high = mm_rank(births_past_12mo),
      rank_gfr_high    = mm_rank(general_fertility_rate))

  n_counties <- nrow(prof)
  prof$sentences <- vapply(seq_len(nrow(prof)),
                           function(i) county_sentences(as.list(prof[i, ]), n_counties),
                           character(1))

  write_csv(prof, file.path(OUT, "county_birth_profiles.csv"), na = "")
  write_csv(select(prof, GEOID, county_label, state, n_midwives, births_past_12mo, sentences),
            file.path(OUT, "county_sentences.csv"), na = "")

  cli::cli_h2("Coverage")
  cli::cli_alert_info("roster rows: {n_roster}; located to a county: {n_located} ({round(100*n_located/n_roster,1)}%)")
  cli::cli_alert_info("counties with >=1 located midwife: {sum(prof$n_midwives > 0)} of {nrow(prof)}")
  cli::cli_alert_info("counties with births but no located midwife: {sum(prof$no_located_midwife_with_births)}")

  cli::cli_h2("Example profiles")
  ex <- prof %>%
    filter(!is.na(births_past_12mo)) %>%
    arrange(desc(n_midwives)) %>%
    slice(1) %>%
    bind_rows(prof %>% filter(n_midwives > 0, rucc_2023 >= 7) %>%
                arrange(desc(births_past_12mo)) %>% slice(1)) %>%
    bind_rows(prof %>% filter(no_located_midwife_with_births) %>%
                arrange(desc(births_past_12mo)) %>% slice(1))
  for (i in seq_len(nrow(ex))) cat("\n*", ex$sentences[i], "\n")

  # National WONDER benchmark, when it has been pulled. It is national ONLY
  # because the API refuses sub-national natality outright; see below.
  wonder_path <- file.path(ART, "wonder", "national_births_by_attendant_year.csv")
  wonder_ctx <- NULL
  if (file.exists(wonder_path)) {
    w <- read_csv(wonder_path, show_col_types = FALSE, progress = FALSE)
    latest <- w %>% filter(year == max(year))
    cnm <- latest %>% filter(grepl("CNM", attendant)) %>% pull(births)
    wonder_ctx <- list(
      year = max(w$year),
      cnm_births = cnm,
      cnm_share_pct = round(100 * cnm / sum(latest$births), 2),
      source = "CDC WONDER Natality D66, national totals")
    cli::cli_alert_info(
      "National benchmark {wonder_ctx$year}: CNM/CM attended {wonder_ctx$cnm_share_pct}% of US births")
  }

  manifest <- list(
    analysis = "County birth + midwifery profiles with narrative sentences",
    wonder_national_benchmark = wonder_ctx,
    wonder_county_unavailable_because = paste(
      "The WONDER API refuses sub-national natality entirely:",
      "'Only national data are available for this dataset when using the WONDER",
      "web service... your query [must] not group results by region, division,",
      "state or county.' This is an API restriction, NOT the <10 births",
      "suppression rule. County x attendant requires a manual export from the",
      "WONDER web UI under its data-use agreement."),
    midwife_source = "AMCB roster after NPI linkage and geocoding -- an UNDERCOUNT of practising midwives",
    wonder_natality_excluded_because =
      "county-level natality sub-totals are suppressed below 10 births, which removes precisely the low-volume rural counties this analysis is about",
    inputs = list(
      county_base = list(path = BASE, sha256 = sha256_of(BASE), rows = nrow(base)),
      geography = list(path = GEO, sha256 = sha256_of(GEO), rows = n_roster,
                       located = n_located)),
    git_commit = tryCatch(system2("git", c("rev-parse", "HEAD"), stdout = TRUE)[1],
                          error = function(e) NA_character_),
    counties = nrow(prof),
    counties_with_located_midwife = sum(prof$n_midwives > 0),
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_json(manifest, file.path(OUT, "manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("manifest written (input SHAs + git commit pinned)")

  invisible(prof)
}

if (identical(environment(), globalenv()) && !interactive()) run_profiles()
