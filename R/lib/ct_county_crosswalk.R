#!/usr/bin/env Rscript
#' @title Connecticut legacy county -> 2022 planning region weights
#'
#' @description
#' Connecticut replaced its eight legacy counties (09001-09015) with nine
#' councils of government / planning regions (09110-09190) for the 2022
#' vintage. CDC WONDER still reports natality by LEGACY county; ACS 2023,
#' tigris 2023 and therefore `data/county_base.csv` use planning regions. The
#' two geographies describe the same ground and do not join.
#'
#' @section Why this is apportionment and not a lookup:
#' The mapping is many-to-many. Seven of the eight legacy counties split across
#' two or three planning regions; only Middlesex (09007) maps wholly into one.
#' There is therefore NO exact conversion of a legacy-county birth count into
#' planning-region counts -- any such figure is an estimate, and this module
#' labels it as one rather than presenting apportioned values as observations.
#'
#' @section Choice of weight:
#' Tracts are the shared unit: the crosswalk carries both the 2020 tract id
#' (nested in legacy counties) and the 2022 tract id (nested in planning
#' regions). Weights are the ACS share of WOMEN AGED 15-44, not total
#' population and not tract counts. Births are approximately proportional to
#' women of reproductive age; they are not proportional to tract count, which
#' would implicitly assume every tract contributes equally.
#'
#' The weight is still an assumption: it apportions births as if fertility were
#' uniform across a legacy county. Fertility varies within counties, so a
#' planning region containing systematically younger or higher-fertility towns
#' is under- or over-credited. This is a bounded error on a small state, and it
#' is disclosed on every apportioned row.
#'
#' @family geography
#' @author Tyler Muffly, MD + Claude Code
#' @name ct_county_crosswalk
NULL

CT_XWALK      <- file.path("data", "ct_tract_crosswalk_2022.csv")
CT_WEIGHTS    <- file.path("data", "ct_legacy_to_region_weights.csv")
# ACS female age bands spanning 15-44 (B01001_030E .. B01001_038E).
CT_ACS_VARS   <- sprintf("B01001_%03dE", 30:38)

#' Build (or load) the legacy-county -> planning-region weight table
#'
#' @param refresh [logical(1)]: re-pull from the Census API even if cached.
#' @return [data.frame] `county_fips_2020`, `ce_fips_2022`, `women_15_44`,
#'   `weight` (shares summing to 1 within each legacy county).
#' @family geography
#' @export
build_ct_legacy_to_region_weights <- function(refresh = FALSE) {
  if (!refresh && file.exists(CT_WEIGHTS)) {
    return(readr::read_csv(CT_WEIGHTS, show_col_types = FALSE, progress = FALSE,
                           col_types = readr::cols(county_fips_2020 = readr::col_character(),
                                                   ce_fips_2022 = readr::col_character(),
                                                   .default = readr::col_double())))
  }
  key <- Sys.getenv("CENSUS_API_KEY")
  if (!nzchar(key)) {
    stop("build_ct_legacy_to_region_weights: CENSUS_API_KEY not set. ",
         "It lives in ~/.Renviron; note that Rscript --vanilla does not read it.",
         call. = FALSE)
  }
  stopifnot(file.exists(CT_XWALK))

  url <- sprintf("https://api.census.gov/data/2023/acs/acs5?get=%s&for=tract:*&in=state:09&key=%s",
                 paste(CT_ACS_VARS, collapse = ","), key)
  j <- jsonlite::fromJSON(url)
  acs <- as.data.frame(j[-1, , drop = FALSE], stringsAsFactors = FALSE)
  names(acs) <- j[1, ]
  acs[CT_ACS_VARS] <- lapply(acs[CT_ACS_VARS], as.numeric)

  # ACS 2023 returns PLANNING-REGION tracts (county 110..190), so the join is
  # on the crosswalk's 2022 tract id. Joining on the 2020 id would match
  # nothing and silently yield zero weights.
  acs$tract_fips_2022 <- paste0(acs$state, acs$county, acs$tract)
  acs$women_15_44 <- rowSums(acs[CT_ACS_VARS], na.rm = TRUE)

  xw <- readr::read_csv(CT_XWALK, show_col_types = FALSE, progress = FALSE,
                        col_types = readr::cols(.default = readr::col_character()))
  # The published crosswalk ships a UTF-8 BOM on the first header cell and
  # spells the 2022 tract column "Tract_fips_2022" with a capital T. Hardcoding
  # either detail makes the join fail with "column not present" on a file that
  # looks correct in a text editor.
  names(xw) <- tolower(sub("^﻿", "", names(xw)))

  joined <- dplyr::left_join(xw, acs[, c("tract_fips_2022", "women_15_44")],
                             by = "tract_fips_2022", relationship = "many-to-one")
  n_miss <- sum(is.na(joined$women_15_44))
  if (n_miss > 0) {
    warning(sprintf("%d of %d CT crosswalk tracts had no ACS match; they contribute zero weight.",
                    n_miss, nrow(joined)), call. = FALSE)
  }

  w <- joined %>%
    dplyr::group_by(county_fips_2020, ce_fips_2022) %>%
    dplyr::summarise(women_15_44 = sum(women_15_44, na.rm = TRUE), .groups = "drop") %>%
    dplyr::group_by(county_fips_2020) %>%
    dplyr::mutate(weight = women_15_44 / sum(women_15_44)) %>%
    dplyr::ungroup()

  # Shares must be a partition of each legacy county, or births are created or
  # destroyed by the apportionment.
  chk <- w %>% dplyr::group_by(county_fips_2020) %>%
    dplyr::summarise(total = sum(weight), .groups = "drop")
  stopifnot(all(abs(chk$total - 1) < 1e-9))

  readr::write_csv(w, CT_WEIGHTS)
  w
}

#' Apportion legacy-county values onto planning regions
#'
#' @param d [data.frame]: rows keyed by legacy county FIPS.
#' @param geoid_col [character(1)]: column holding the legacy FIPS.
#' @param value_cols [character]: numeric columns to apportion.
#' @return [data.frame] one row per (planning region), with `ct_apportioned`
#'   flagging every row whose value is an estimate rather than an observation.
#' @family geography
#' @export
apportion_ct_legacy <- function(d, geoid_col = "GEOID", value_cols) {
  w <- build_ct_legacy_to_region_weights()
  legacy <- d[d[[geoid_col]] %in% w$county_fips_2020, , drop = FALSE]
  if (nrow(legacy) == 0L) return(legacy[0, , drop = FALSE])

  out <- legacy %>%
    dplyr::rename(county_fips_2020 = !!rlang::sym(geoid_col)) %>%
    dplyr::inner_join(w, by = "county_fips_2020",
                      relationship = "many-to-many") %>%
    dplyr::mutate(dplyr::across(dplyr::all_of(value_cols), ~ .x * weight)) %>%
    dplyr::group_by(ce_fips_2022) %>%
    # CYCLE 4. sum(na.rm = TRUE) here turned a WONDER-suppressed legacy county
    # (which arrives as NA) into 0 for every planning region drawing from it --
    # and a region fed ONLY by that county was published as a hard 0. "We may
    # not say" is not "none"; the difference is a county reported as having no
    # midwife-attended births. Suppression means the true count is 1-9, so 0 is
    # not even a defensible estimate, only a lower bound.
    #
    # Propagating NA to any region touched by a suppressed county was the first
    # fix and it was wrong in the other direction: a region straddling one
    # suppressed and one observed county would discard the observed births too,
    # so the conservation guard fired at 100 -> 92.97. Both "publish 0" and
    # "publish NA" destroy information.
    #
    # A region therefore reports the sum of its OBSERVED contributions, and is
    # NA only when every contributing county was suppressed -- the case that was
    # being published as a hard 0. `ct_partial` marks a region whose total is
    # missing at least one suppressed county, so an understated value can never
    # be mistaken for a complete one.
    dplyr::summarise(
      dplyr::across(dplyr::all_of(value_cols),
                    ~ if (all(is.na(.x))) NA_real_ else sum(.x, na.rm = TRUE)),
      ct_partial = any(dplyr::if_any(dplyr::all_of(value_cols), is.na)) &&
        !all(dplyr::if_all(dplyr::all_of(value_cols), is.na)),
      .groups = "drop") %>%
    dplyr::rename(!!geoid_col := ce_fips_2022) %>%
    dplyr::mutate(ct_apportioned = TRUE)

  # Apportionment redistributes; it must not change the total.
  # CYCLE 4. This guard used na.rm = TRUE on BOTH sides, so when a suppressed
  # county's NA became 0 the totals matched at 0 and the invariant passed over
  # exactly the corruption it exists to detect. A guard that cannot fail on bad
  # input is not a guard. Missing values are now accounted for separately, and
  # the total is compared only over the observed part.
  for (v in value_cols) {
    n_missing_before <- sum(is.na(legacy[[v]]))
    n_missing_after  <- sum(is.na(out[[v]]))
    if (n_missing_before > 0L && n_missing_after == 0L) {
      stop(sprintf(paste0(
        "apportion_ct_legacy: %s had %d suppressed legacy county/counties on ",
        "input and none on output. Suppression must propagate, not become 0."),
        v, n_missing_before), call. = FALSE)
    }
    before <- sum(legacy[[v]], na.rm = TRUE)
    after  <- sum(out[[v]], na.rm = TRUE)
    if (abs(before - after) > 1e-6 * max(1, before)) {
      stop(sprintf("apportion_ct_legacy: %s observed total changed (%s -> %s).",
                   v, before, after), call. = FALSE)
    }
  }
  out
}
