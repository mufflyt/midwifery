#!/usr/bin/env Rscript
#' @title Step 10: County birth + midwifery profiles, with narrative sentences
#'
#' @description
#' Assembles the county-level birth statistics that bear on midwifery care and
#' renders two to four plain sentences per county.
#'
#' @section Why CDC WONDER natality is NOT the source here:
#' The obvious source for "births attended by a midwife" is CDC WONDER
#' Natality, which carries an Attendant variable (MD, DO, CNM/CM, other
#' midwife). It is deliberately not used, for one reason: WONDER suppresses
#' county-level sub-totals below 10 births. Midwife-attended births are a small
#' share of an already small denominator, so the suppressed cells fall almost
#' entirely on low-volume rural counties -- exactly the counties a midwifery
#' access analysis exists to describe. A variable that is present in metro
#' counties and blank in rural ones would not be a measure of midwifery care;
#' it would be a measure of county size wearing a midwifery label. Every
#' measure below is instead complete for all 3,235 counties, or is a count we
#' produced ourselves and can characterise honestly.
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
#' @keywords internal
#' @noRd
county_sentences <- function(r) {
  s <- character(0)

  # 1. What kind of place, and how many births.
  # RUCC is missing for territories and for counties added since the 2023
  # vintage; [[ ]] on an absent key errors rather than returning NULL.
  geo <- unname(RUCC_LABEL[as.character(r$rucc_2023)])
  if (length(geo) != 1L || is.na(geo)) geo <- NULL
  place <- if (!is.null(geo)) sprintf("%s is %s", r$county_label, geo) else
    sprintf("%s", r$county_label)
  births <- fmt(r$births_past_12mo)
  women <- fmt(r$women_15_44)
  if (!is.null(births) && !is.null(women)) {
    s <- c(s, sprintf("%s, home to %s women aged 15-44, with about %s births in the past 12 months.",
                      place, women, births))
  } else {
    s <- c(s, sprintf("%s.", place))
  }

  # 2. Fertility and birth risk, only the parts that are observed.
  bits <- character(0)
  if (!is.null(fmt(r$general_fertility_rate, 1)))
    bits <- c(bits, sprintf("a general fertility rate of %s births per 1,000 women aged 15-44",
                            fmt(r$general_fertility_rate, 1)))
  if (!is.null(fmt(r$teen_birth_rate, 1)))
    bits <- c(bits, sprintf("a teen birth rate of %s per 1,000", fmt(r$teen_birth_rate, 1)))
  # UNITS: county_base stores pct_low_birth_weight and svi_overall_pctile as
  # PROPORTIONS (0-1), while pct_uninsured is already a percentage (0-44).
  # Printing the proportions unscaled produced "0.1% of births low birth
  # weight" for Cook County -- a figure two orders of magnitude off that still
  # looked like a plausible number, which is exactly how a unit error survives
  # review.
  if (!is.null(fmt(100 * r$pct_low_birth_weight, 1)))
    bits <- c(bits, sprintf("%s%% of births low birth weight",
                            fmt(100 * r$pct_low_birth_weight, 1)))
  if (length(bits)) {
    s <- c(s, sprintf("The county has %s.",
                      paste(bits, collapse = if (length(bits) == 2) " and " else ", ")))
  }

  # 3. Located midwives -- phrased as ascertainment, never as supply.
  if (r$n_midwives == 0) {
    s <- c(s, paste0("No AMCB-certified nurse-midwife in the linked cohort could be located ",
                     "in this county, which reflects roster, linkage and geocoding coverage ",
                     "as much as it reflects who practises here."))
  } else {
    per <- fmt(r$midwives_per_10k_women, 1)
    ratio <- fmt(r$births_per_midwife)
    tail_bits <- character(0)
    if (!is.null(per)) tail_bits <- c(tail_bits, sprintf("%s per 10,000 women aged 15-44", per))
    if (!is.null(ratio)) tail_bits <- c(tail_bits, sprintf("roughly %s births per located midwife", ratio))
    s <- c(s, sprintf("%s AMCB-certified nurse-midwi%s located here%s%s.",
                      fmt(r$n_midwives), if (r$n_midwives == 1) "fe was" else "ves were",
                      if (length(tail_bits)) " -- " else "",
                      paste(tail_bits, collapse = ", ")))
  }

  # 4. Access context, when observed.
  acc <- character(0)
  if (!is.null(fmt(r$pct_uninsured, 1)))
    acc <- c(acc, sprintf("%s%% of residents are uninsured", fmt(r$pct_uninsured, 1)))
  if (!is.null(fmt(100 * r$svi_overall_pctile, 0)))
    acc <- c(acc, sprintf("social vulnerability sits at the %s%s percentile nationally",
                          fmt(100 * r$svi_overall_pctile),
                          scales_ord(100 * r$svi_overall_pctile)))
  if (length(acc)) s <- c(s, sprintf("%s.", paste(acc, collapse = ", and ")))

  paste(s, collapse = " ")
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

  prof$sentences <- vapply(seq_len(nrow(prof)),
                           function(i) county_sentences(as.list(prof[i, ])),
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
