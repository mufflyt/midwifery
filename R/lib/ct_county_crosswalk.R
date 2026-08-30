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
    dplyr::mutate(ct_apportioned = TRUE) %>%
    # D3 RULING (2026-08-10): WITHHOLD any partial region.
    #
    # The flagged-but-published behaviour above protected only readers who
    # check the flag. CDC WONDER suppression means 1-9, so each missing
    # contributor understates the region by an unknown 1-9, and an understated
    # total that can win or lose a comparison is worse than a missing one.
    # The count is set to NA where ct_partial is TRUE; the flag is retained so
    # the reason for the gap stays visible and countable.
    dplyr::mutate(dplyr::across(dplyr::all_of(value_cols),
                                ~ dplyr::if_else(ct_partial, NA_real_, .x)))

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

#' Connecticut ZIP -> 2022 planning region, by dominant land area
#'
#' @description
#' The ZIP-to-county relationship file is 2020 vintage and reports Connecticut
#' under its EIGHT LEGACY COUNTIES (09001-09015). `data/county_base.csv` is 2023
#' vintage and reports the NINE PLANNING REGIONS (09110-09190). The two describe
#' the same ground and do not join, so every Connecticut ZIP resolves to a
#' county that carries no RUCC and the provider is recorded as having no
#' assignable county. 249 cohort members were lost this way -- not for want of
#' an address, but for want of a matching vintage.
#'
#' @section Why not apportion through the legacy county:
#' `apportion_ct_legacy()` above splits a legacy-county COUNT across regions by
#' population weight, which is the right tool for a birth count and the wrong
#' one for a person: seven of the eight legacy counties straddle two or three
#' planning regions, and the regions do not share a rurality band -- Capitol and
#' Lower Connecticut River Valley are RUCC 1, five are RUCC 2, and Northeastern
#' Connecticut and Northwest Hills are RUCC 4. Assigning by county-level weight
#' would push every rural Connecticut midwife into a metropolitan region.
#'
#' So this does not route through the legacy county at all. It goes ZIP -> tract
#' -> planning region, which is exact because tracts NEST within regions, and
#' resolves a ZIP spanning several regions by the same dominant-land-area rule
#' the national crosswalk uses for counties. Same rule, finer geography.
#'
#' @param tract_path [character(1)]: ZCTA-to-tract relationship file.
#' @param cw_path [character(1)]: Connecticut 2020-tract to 2022-region crosswalk.
#' @return [data.frame] `zip5`, `GEOID` (planning region), one row per ZIP.
#' @family geography
#' @export
ct_zip_to_region <- function(tract_path = file.path("data", "zcta_tract_2020.txt"),
                             cw_path = file.path("data", "ct_tract_crosswalk_2022.csv")) {
  if (!file.exists(tract_path) || !file.exists(cw_path)) return(NULL)

  zt <- readr::read_delim(tract_path, delim = "|", show_col_types = FALSE,
                          progress = FALSE, col_types = readr::cols(.default = "c"))
  cw <- readr::read_csv(cw_path, show_col_types = FALSE, progress = FALSE,
                        col_types = readr::cols(.default = "c"))

  # Connecticut tracts only. The national file is 171k rows and every other
  # state already joins correctly; touching them would be a change with no
  # defect behind it.
  zt <- zt[substr(zt$GEOID_TRACT_20, 1, 2) == "09", , drop = FALSE]
  if (!nrow(zt)) return(NULL)

  zt$zip5 <- pad5(zt$GEOID_ZCTA5_20)
  zt$land <- suppressWarnings(as.numeric(zt$AREALAND_PART))
  zt <- zt[!is.na(zt$zip5) & nzchar(zt$zip5) & !is.na(zt$land), , drop = FALSE]

  m <- merge(zt[, c("zip5", "GEOID_TRACT_20", "land")],
             unique(cw[, c("tract_fips_2020", "ce_fips_2022")]),
             by.x = "GEOID_TRACT_20", by.y = "tract_fips_2020", all.x = FALSE)
  if (!nrow(m)) return(NULL)

  agg <- stats::aggregate(land ~ zip5 + ce_fips_2022, data = m, FUN = sum)
  agg <- agg[order(agg$zip5, -agg$land), , drop = FALSE]
  out <- agg[!duplicated(agg$zip5), c("zip5", "ce_fips_2022"), drop = FALSE]
  names(out) <- c("zip5", "GEOID")
  rownames(out) <- NULL
  out
}
