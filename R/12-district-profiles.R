#!/usr/bin/env Rscript
#' @title Step 12: Congressional-district midwifery profiles and sentences
#'
#' @description
#' Builds a district-level table and renders map prose for each congressional
#' district, using the CANONICAL variety-sentence engine in mufflyt/isochrones
#' (`R/variety_sentences.R`). No sentence generator is defined here; this file
#' supplies data and vocabulary only.
#'
#' @section What is exact, and what is deliberately absent:
#' Districts do not nest inside counties, so each input behaves differently and
#' the honest treatment differs:
#' \itemize{
#'   \item **ACS measures** -- pulled at district level directly from the Census
#'     API. Exact; no crosswalk, no apportionment.
#'   \item **Located midwives** -- assigned by point-in-polygon on their
#'     geocoded coordinates against TIGER district boundaries. Exact for every
#'     midwife who has coordinates.
#'   \item **RUCC, SVI, County Health Rankings** -- county-defined, and a
#'     district spanning a metro core and a rural fringe has no single value.
#'     OMITTED rather than population-weighted into a number that would read as
#'     measured.
#'   \item **CDC WONDER midwife-attended births** -- county-only, and already
#'     limited to the 579 counties WONDER reports at all. Pushing them to
#'     districts would apportion across non-nesting boundaries on a base that is
#'     four-fifths missing. OMITTED; the county profiles (R/10) remain the place
#'     to read them.
#' }
#'
#' @section Boundary vintage:
#' ACS 2023 reports **118th Congress** districts; the roster is the **119th**.
#' Several states redistricted in between, so in those states a sitting member
#' is attached to statistics describing slightly different ground. Disclosed on
#' every row via `boundary_vintage`, not silently reconciled -- there is no ACS
#' release on 119th boundaries yet.
#'
#' Output : artifacts/district_profiles/{district_profiles.csv,
#'          district_sentences.csv,manifest.json}
#'
#' @family step-functions
#' @concept district-profiles
#' @author Tyler Muffly, MD + Claude Code
#' @export

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(sf); library(cli); library(jsonlite)
})

source(file.path("R", "lib", "isochrones_dep.R"))
source(file.path("R", "lib", "congress_roster.R"))
load_variety_sentence_engine(quiet = TRUE)

ART <- "artifacts"; OUT <- file.path(ART, "district_profiles")
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
GEO <- file.path(ART, "midwives_geography_FROZEN.csv")
SUPERLATIVE_N <- 10L
ACS_YEAR <- 2023L

sha256_of <- function(p) sub(" .*$", "",
                             system2("shasum", c("-a", "256", shQuote(p)), stdout = TRUE)[1])

fmt <- function(x, digits = 0, big = TRUE) {
  if (is.null(x) || length(x) != 1L || is.na(x)) return(NULL)
  formatC(round(x, digits), format = "f", digits = digits,
          big.mark = if (big) "," else "")
}

# Variables verified against the Census metadata API rather than recalled:
# an early draft used B13002_005 (married women 20-34) for unmarried births and
# C27007_004 (MALE under 19) for women's Medicaid. Both were wrong and both
# would have produced plausible-looking numbers.
ACS_VARS <- c(
  women_15_44_       = sprintf("B01001_%03dE", 30:38),  # summed
  births_12mo        = "B13016_002E",   # women 15-50 with a birth in past 12 months
  births_unmarried   = "B13002_007E",   # ... of whom unmarried
  medicaid_f_19_64   = "C27007_017E",   # female 19-64 WITH Medicaid/means-tested
  medicaid_f_denom   = "C27007_016E",   # female 19-64 total
  median_hh_income   = "B19013_001E",
  poverty_n          = "B17001_002E",
  poverty_d          = "B17001_001E",
  no_internet_n      = "B28002_013E",
  no_internet_d      = "B28002_001E")

census_key <- function() {
  k <- Sys.getenv("CENSUS_API_KEY")
  if (!nzchar(k)) stop("CENSUS_API_KEY not set (it lives in ~/.Renviron; note Rscript --vanilla ignores it).",
                       call. = FALSE)
  k
}

#' Pull one ACS variable set for all congressional districts
#' @keywords internal
#' @noRd
acs_cd <- function(vars, dataset = "acs/acs5") {
  # NAME is always requested: it carries the district label AND the boundary
  # vintage ("Congressional District 1 (118th Congress), Colorado"), which is
  # the only in-band evidence of which districts these actually are.
  u <- sprintf("https://api.census.gov/data/%d/%s?get=%s&for=congressional%%20district:*&in=state:*&key=%s",
               ACS_YEAR, dataset, paste(c("NAME", vars), collapse = ","), census_key())
  j <- jsonlite::fromJSON(u)
  d <- as.data.frame(j[-1, , drop = FALSE], stringsAsFactors = FALSE)
  names(d) <- j[1, ]
  d[vars] <- lapply(d[vars], function(x) suppressWarnings(as.numeric(x)))
  # Census encodes suppressed/unavailable as large negatives, not NA. Left
  # unchecked these become real-looking values (a median income of -666,666,666).
  d[vars] <- lapply(d[vars], function(x) ifelse(x < -1e6, NA_real_, x))
  d$GEOID <- paste0(d$state, d$`congressional district`)
  d
}

run_districts <- function() {
  cli::cli_h2("ACS at district level ({ACS_YEAR} 5-year, 118th Congress boundaries)")
  women <- acs_cd(unname(ACS_VARS[grep("^women_15_44_", names(ACS_VARS))]))
  women$women_15_44 <- rowSums(women[unname(ACS_VARS[grep("^women_15_44_", names(ACS_VARS))])], na.rm = TRUE)
  core <- acs_cd(c("B13016_002E", "B13002_007E", "C27007_017E", "C27007_016E",
                   "B19013_001E", "B17001_002E", "B17001_001E",
                   "B28002_013E", "B28002_001E",
                   # Births by maternal age: the 15-19 and 35+ tails are what
                   # bear on risk and on which model of care fits.
                   "B13016_003E", "B13016_007E", "B13016_008E", "B13016_009E",
                   # Uninsured WOMEN, brackets 19-25 / 26-34 / 35-44 with their
                   # denominators. B27001 has no 15-18 split (its bracket is
                   # 6-18), so this is 19-44 and is labelled 19-44 -- not
                   # silently reported as 15-44.
                   "B27001_039E", "B27001_042E", "B27001_045E",
                   "B27001_037E", "B27001_040E", "B27001_043E"))
  subj <- acs_cd(c("S2701_C05_001E",     # percent uninsured, all ages
                   "S1101_C01_004E",     # average family size
                   "S1401_C02_001E",     # percent 3+ enrolled in school
                   "S1501_C02_014E",     # percent 25+ high school or higher
                   "S1501_C02_015E"),    # percent 25+ bachelor's or higher
                 dataset = "acs/acs5/subject")

  d <- women[, c("GEOID", "state", "congressional district", "NAME", "women_15_44")] %>%
    # Carry every requested variable through rather than a hand-maintained
    # subset: the earlier explicit list silently dropped the new columns and
    # failed downstream with "object not found".
    left_join(core[, setdiff(names(core), c("NAME", "state", "congressional district"))],
              by = "GEOID") %>%
    left_join(subj[, setdiff(names(subj), c("NAME", "state", "congressional district"))],
              by = "GEOID") %>%
    rename(state_fips = state, cd = `congressional district`,
           births_12mo = B13016_002E, births_unmarried = B13002_007E,
           medicaid_women = C27007_017E, medicaid_women_denom = C27007_016E,
           median_hh_income = B19013_001E, pct_uninsured = S2701_C05_001E,
           avg_family_size = S1101_C01_004E, pct_enrolled_school = S1401_C02_001E,
           pct_hs_or_higher = S1501_C02_014E, pct_bachelors_or_higher = S1501_C02_015E)

  # The Medicaid denominator was inferred from table position, so prove it.
  bad <- sum(d$medicaid_women > d$medicaid_women_denom, na.rm = TRUE)
  stopifnot(bad == 0)
  cli::cli_alert_success("C27007_016E confirmed as the denominator (0 of {nrow(d)} districts exceed it)")

  d <- d %>%
    mutate(
      pct_medicaid_women = 100 * medicaid_women / medicaid_women_denom,
      pct_births_unmarried = 100 * births_unmarried / births_12mo,
      pct_poverty = 100 * B17001_002E / B17001_001E,
      pct_no_internet = 100 * B28002_013E / B28002_001E,
      gfr = 1000 * births_12mo / women_15_44,
      births_teen = B13016_003E,
      pct_births_teen = 100 * B13016_003E / births_12mo,
      births_35plus = B13016_007E + B13016_008E + B13016_009E,
      pct_births_35plus = 100 * (B13016_007E + B13016_008E + B13016_009E) / births_12mo,
      women_19_44_uninsured = B27001_039E + B27001_042E + B27001_045E,
      women_19_44_total = B27001_037E + B27001_040E + B27001_043E,
      pct_women_19_44_uninsured = 100 * women_19_44_uninsured / women_19_44_total,
      district_label = sub(" \\(.*", "", sub("^Congressional District ", "", NAME)),
      state_abbr = NA_character_)
  # B27001 bracket totals were inferred from table position, same as C27007.
  stopifnot(sum(d$women_19_44_uninsured > d$women_19_44_total, na.rm = TRUE) == 0)
  # Age-specific births must not exceed the total they are drawn from.
  stopifnot(sum(d$births_teen + d$births_35plus > d$births_12mo, na.rm = TRUE) == 0)
  cli::cli_alert_success("B27001 bracket denominators and B13016 age splits are internally consistent")
  cli::cli_alert_info("districts: {nrow(d)}")

  # ---- midwives by point-in-polygon ---------------------------------------
  cli::cli_h2("Assigning located midwives to districts")
  mw <- read_csv(GEO, show_col_types = FALSE, progress = FALSE,
                 col_types = cols(.default = col_character())) %>%
    mutate(latitude = as.numeric(latitude), longitude = as.numeric(longitude)) %>%
    filter(!is.na(latitude), !is.na(longitude))

  cds <- tigris::congressional_districts(cb = TRUE, year = ACS_YEAR, progress_bar = FALSE) %>%
    st_transform(4326)
  pts <- st_as_sf(mw, coords = c("longitude", "latitude"), crs = 4326)
  old_s2 <- sf::sf_use_s2(); sf::sf_use_s2(FALSE); on.exit(sf::sf_use_s2(old_s2), add = TRUE)
  hit <- st_join(pts, cds[, c("GEOID")], join = st_within)

  n_assigned <- sum(!is.na(hit$GEOID))
  cli::cli_alert_info("midwives with coordinates: {nrow(mw)}; inside a district: {n_assigned} ({round(100*n_assigned/nrow(mw),1)}%)")

  mw_cd <- st_drop_geometry(hit) %>% filter(!is.na(GEOID)) %>%
    count(GEOID, name = "n_midwives")

  # "ZZ" is not a district: TIGER/ACS emit it for unassigned water area. These
  # rows carry zero population and would otherwise dilute every rank and appear
  # on the map as a district with no midwives.
  n_zz <- sum(d$cd == "ZZ")
  d <- d %>% filter(cd != "ZZ")
  if (n_zz) cli::cli_alert_info("dropped {n_zz} 'ZZ' water/unassigned pseudo-districts")

  d <- d %>% left_join(mw_cd, by = "GEOID") %>%
    mutate(n_midwives = coalesce(n_midwives, 0L),
           midwives_per_10k_women = if_else(women_15_44 > 0,
                                            1e4 * n_midwives / women_15_44, NA_real_),
           births_per_midwife = if_else(n_midwives > 0 & births_12mo > 0,
                                        births_12mo / n_midwives, NA_real_))

  # ---- representative badge ------------------------------------------------
  reps <- load_house_roster() %>%
    # ACS codes the DC / PR / territory delegate seats as district "98"; the
    # roster codes them 0 -> "00". Without this they never join and read as
    # "no representative" rather than "non-voting delegate".
    mutate(district = if_else(state_abbr %in% c("DC", "PR", "VI", "GU", "AS", "MP"),
                              "98", district))
  fips <- tigris::fips_codes %>% distinct(state, state_code)
  d <- d %>%
    left_join(fips, by = c("state_fips" = "state_code")) %>%
    mutate(state_abbr = state) %>% select(-state) %>%
    left_join(reps, by = c("state_abbr", "cd" = "district")) %>%
    mutate(
      district_display = if_else(state_abbr %in% c("DC", "PR"), state_abbr,
                                 sprintf("%s-%s", state_abbr, cd)),
      rep_badge = mm_rep_badge(rep_name, party, district_display, url,
                               role = coalesce(role, "Rep.")),
      # A missing member here is a VACANCY, not a data gap: CA-14, FL-20,
      # GA-13 and TX-23 are absent from the current roster because the seat is
      # unfilled. Saying so is more accurate than a blank badge.
      seat_vacant = is.na(rep_name),
      boundary_vintage = sprintf("ACS %d on 118th Congress boundaries; roster is 119th Congress",
                                 ACS_YEAR))
  cli::cli_alert_info("districts matched to a sitting member: {sum(!is.na(d$rep_name))} of {nrow(d)}")

  # ---- ranks + sentences ---------------------------------------------------
  d <- d %>% mutate(
    rank_mw_high       = mm_rank(midwives_per_10k_women),
    rank_births_high   = mm_rank(births_12mo),
    rank_medicaid_high = mm_rank(pct_medicaid_women),
    rank_gfr_high      = mm_rank(gfr),
    rank_uninsw_high   = mm_rank(pct_women_19_44_uninsured))

  n_d <- nrow(d)
  d$sentences <- vapply(seq_len(n_d), function(i) district_sentences(as.list(d[i, ]), n_d),
                        character(1))

  write_csv(select(d, -any_of("geometry")), file.path(OUT, "district_profiles.csv"), na = "")
  write_csv(select(d, GEOID, district_display, rep_name, party, n_midwives,
                   births_12mo, sentences, rep_badge),
            file.path(OUT, "district_sentences.csv"), na = "")

  cli::cli_h2("Examples")
  ex <- d %>% arrange(desc(n_midwives)) %>% slice(1) %>%
    bind_rows(d %>% filter(n_midwives == 0) %>% arrange(desc(births_12mo)) %>% slice(1)) %>%
    bind_rows(d %>% arrange(desc(pct_medicaid_women)) %>% slice(1))
  for (i in seq_len(nrow(ex))) cat("\n*", ex$sentences[i], "\n")

  manifest <- list(
    analysis = "Congressional-district midwifery profiles",
    engine = "mufflyt/isochrones R/variety_sentences.R (canonical; not reimplemented)",
    acs_year = ACS_YEAR,
    boundary_vintage = d$boundary_vintage[1],
    omitted = list(
      county_defined = "RUCC, SVI, County Health Rankings -- no single value for a district spanning metro and rural counties",
      wonder = "CDC WONDER CNM births -- county-only and already limited to 579 counties; apportioning across non-nesting boundaries on a four-fifths-missing base would manufacture precision"),
    inputs = list(geography = list(path = GEO, sha256 = sha256_of(GEO), rows = nrow(mw)),
                  roster = list(path = LEG_CACHE, sha256 = sha256_of(LEG_CACHE))),
    districts = n_d,
    midwives_assigned = n_assigned,
    git_commit = tryCatch(system2("git", c("rev-parse", "HEAD"), stdout = TRUE)[1],
                          error = function(e) NA_character_),
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  write_json(manifest, file.path(OUT, "manifest.json"), auto_unbox = TRUE)
  cli::cli_alert_success("written to {OUT}")
  invisible(d)
}

#' Render the sentences for one district
#' @keywords internal
#' @noRd
district_sentences <- function(r, n_d) {
  a <- sprintf("%s covers about %s women aged 15-44, with roughly %s births in the past 12 months.",
               r$district_display, fmt(r$women_15_44), fmt(r$births_12mo))

  b <- if (r$n_midwives == 0) {
    # Plain statement; the ascertainment caveat belongs once in the notes,
    # not repeated per district. See R/10 for the full reasoning.
    "No certified nurse-midwife was located in this district."
  } else {
    tail_bits <- c(
      if (!is.null(fmt(r$midwives_per_10k_women, 1)))
        sprintf("%s per 10,000 women aged 15-44", fmt(r$midwives_per_10k_women, 1)),
      if (!is.null(fmt(r$births_per_midwife)))
        sprintf("roughly %s births per located midwife", fmt(r$births_per_midwife)))
    sprintf("%s certified nurse-midwi%s located here%s%s.",
            fmt(r$n_midwives), if (r$n_midwives == 1) "fe was" else "ves were",
            if (length(tail_bits)) " -- " else "", oxford_join(tail_bits))
  }

  pool <- c(
    if (!is.null(fmt(r$pct_medicaid_women, 0)))
      sprintf("%s%% of women aged 19-64 on Medicaid or other means-tested coverage",
              fmt(r$pct_medicaid_women, 0)),
    if (!is.null(fmt(r$pct_births_unmarried, 0)))
      sprintf("%s%% of recent births to unmarried women", fmt(r$pct_births_unmarried, 0)),
    if (!is.null(fmt(r$gfr, 1)))
      sprintf("a general fertility rate of %s per 1,000 women aged 15-44", fmt(r$gfr, 1)),
    if (!is.null(fmt(r$pct_uninsured, 1)))
      sprintf("%s%% of residents uninsured", fmt(r$pct_uninsured, 1)),
    if (!is.null(fmt(r$median_hh_income)))
      sprintf("a median household income of $%s", fmt(r$median_hh_income)),
    if (!is.null(fmt(r$pct_poverty, 0)))
      sprintf("a %s%% poverty rate", fmt(r$pct_poverty, 0)),
    if (!is.null(fmt(r$pct_no_internet, 0)))
      sprintf("%s%% of households without internet access", fmt(r$pct_no_internet, 0)),
    if (!is.null(fmt(r$pct_women_19_44_uninsured, 0)))
      sprintf("%s%% of women aged 19-44 uninsured", fmt(r$pct_women_19_44_uninsured, 0)),
    if (!is.null(fmt(r$pct_births_teen, 1)))
      sprintf("%s%% of recent births to women under 20", fmt(r$pct_births_teen, 1)),
    if (!is.null(fmt(r$pct_births_35plus, 0)))
      sprintf("%s%% of recent births to women 35 or older", fmt(r$pct_births_35plus, 0)),
    if (!is.null(fmt(r$avg_family_size, 2)))
      sprintf("an average family size of %s", fmt(r$avg_family_size, 2)),
    if (!is.null(fmt(r$pct_enrolled_school, 1)))
      sprintf("%s%% of residents aged 3 and over enrolled in school", fmt(r$pct_enrolled_school, 1)),
    if (!is.null(fmt(r$pct_hs_or_higher, 1)))
      sprintf("%s%% of adults with a high school diploma or more", fmt(r$pct_hs_or_higher, 1)),
    if (!is.null(fmt(r$pct_bachelors_or_higher, 1)))
      sprintf("%s%% of adults holding a bachelor's degree or more", fmt(r$pct_bachelors_or_higher, 1)))

  if (isTRUE(r$seat_vacant)) {
    b <- paste(b, "The seat is currently vacant.")
  }
  parts <- c(a, b)
  pick <- mm_rotate_facts(pool, r$GEOID, 3)
  if (length(pick)) parts <- c(parts, sprintf("It has %s.", oxford_join(pick)))

  sup <- c(
    if (!is.na(r$rank_mw_high) && r$rank_mw_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_mw_high, n_d, "density of located nurse-midwives",
                            "high", "congressional district", "districts"),
    if (!is.na(r$rank_medicaid_high) && r$rank_medicaid_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_medicaid_high, n_d,
                            "share of women on Medicaid", "high",
                            "congressional district", "districts"),
    if (!is.na(r$rank_births_high) && r$rank_births_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_births_high, n_d, "births", "most",
                            "congressional district", "districts"),
    if (!is.na(r$rank_gfr_high) && r$rank_gfr_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_gfr_high, n_d, "general fertility rate", "high",
                            "congressional district", "districts"),
    if (!is.na(r$rank_uninsw_high) && r$rank_uninsw_high <= SUPERLATIVE_N)
      mm_superlative_phrase(r$rank_uninsw_high, n_d,
                            "share of women aged 19-44 without health insurance", "high",
                            "congressional district", "districts"))
  if (length(sup)) parts <- c(parts, sprintf("That is %s.", oxford_join(sup)))

  paste(parts, collapse = " ")
}

if (identical(environment(), globalenv()) && !interactive()) run_districts()
