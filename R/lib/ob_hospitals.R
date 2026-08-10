#!/usr/bin/env Rscript
#' @title Hospitals offering obstetric services, by county
#'
#' @description
#' Counts short-term acute and critical-access hospitals that report an
#' obstetric service, from the CMS Provider of Services (POS) file, aggregated
#' to county FIPS.
#'
#' @section What POS does and does not carry:
#' POS has **no obstetric bed count**. All 473 columns were checked: there are
#' bed counts for psychiatric, rehabilitation, hospice, AIDS, Alzheimer's,
#' ventilator and swing beds, and none for obstetrics. What it has is
#' \code{OB_SRVC_CD}, a service indicator. For a facility-closure narrative that
#' is arguably the better variable -- "does this hospital deliver babies" is the
#' question, not how many beds it holds -- but it is a different measurement and
#' is named as such. True obstetric bed counts live in HCRIS Medicare cost
#' reports (worksheet S-3), not here.
#'
#' @section Coverage is partial, and silence is not a "no":
#' \code{OB_SRVC_CD} is populated for a minority of active hospital records. A
#' facility with a missing code has NOT reported "no obstetrics"; it has
#' reported nothing. Counties are therefore given three columns -- hospitals
#' with obstetric services, hospitals whose obstetric status is unknown, and the
#' active hospital total -- so a zero can be distinguished from an absence of
#' information. Collapsing the two would understate obstetric capacity most in
#' small rural counties, whose hospitals report least completely.
#'
#' @section County, not district:
#' POS carries \code{FIPS_STATE_CD} and \code{FIPS_CNTY_CD} but no coordinates,
#' so county aggregation is exact and needs no crosswalk. Assigning hospitals to
#' congressional districts would require ZIP -> ZCTA -> CD, two approximations
#' stacked, or geocoding the addresses. Deliberately not attempted here.
#'
#' @family geography
#' @author Tyler Muffly, MD + Claude Code
#' @name ob_hospitals
NULL

POS_FILE <- file.path("data", "cms_pos_hospital.csv")

# Short-term acute (01) and critical access (11). Long-term, psychiatric,
# rehabilitation and children's facilities are excluded: they are not where
# routine births happen, and counting them would inflate obstetric capacity.
HOSPITAL_SUBTYPES <- c("01", "11")

#' Count obstetric-service hospitals per county
#'
#' @param path [character(1)]: POS extract.
#' @return [data.frame] `GEOID`, `n_hosp_active`, `n_hosp_ob`, `n_hosp_ob_unknown`.
#' @family geography
#' @export
build_ob_hospital_counts <- function(path = POS_FILE) {
  stopifnot(file.exists(path))
  h <- readr::read_csv(path, show_col_types = FALSE, progress = FALSE,
                       col_types = readr::cols(.default = readr::col_character()))

  active <- h %>%
    dplyr::filter(
      PRVDR_CTGRY_SBTYP_CD %in% HOSPITAL_SUBTYPES,
      is.na(PGM_TRMNTN_CD) | PGM_TRMNTN_CD == "00",
      !is.na(FIPS_STATE_CD), !is.na(FIPS_CNTY_CD)) %>%
    # One row per provider. POS carries historical and superseded records, so an
    # un-deduplicated count would tally the same hospital several times; the
    # most recently certified record wins.
    # CYCLE 5. desc(CRTFCTN_DT) alone leaves same-date records for one provider
    # to input order. The current extract has NO duplicate PRVDR_NUM at all, so
    # this rule has never once fired -- an untested rule, not a tested one. The
    # provider name is a deterministic secondary key so the choice cannot depend
    # on how the POS file was sorted.
    dplyr::arrange(PRVDR_NUM, dplyr::desc(CRTFCTN_DT),
                   dplyr::across(dplyr::any_of(c("FAC_NAME", "PRVDR_NAME")))) %>%
    dplyr::distinct(PRVDR_NUM, .keep_all = TRUE) %>%
    dplyr::mutate(
      GEOID = paste0(FIPS_STATE_CD, FIPS_CNTY_CD),
      # CYCLE 15. The trailing `TRUE ~ "no"` asserted "this hospital has no
      # obstetric service" for ANY code outside 1-3 -- including a code POS has
      # not used yet. That is the same construction cycle 1 removed from the
      # RUCC banding rule, where an unexpected value was confidently labelled
      # "Nonmetropolitan, remote". Only "0" is a recorded no; anything else is
      # something the source said that this code does not understand, which is
      # unknown, not a negative.
      #
      # The live extract carries only 0/1/2/3, so behaviour is unchanged today
      # -- which is exactly why the branch had never been tested by data.
      ob_status = dplyr::case_when(
        is.na(OB_SRVC_CD)                ~ "unknown",
        OB_SRVC_CD %in% c("1", "2", "3") ~ "yes",
        OB_SRVC_CD == "0"                ~ "no",
        TRUE                             ~ "unknown"))

  active %>%
    dplyr::group_by(GEOID) %>%
    dplyr::summarise(
      n_hosp_active     = dplyr::n(),
      n_hosp_ob         = sum(ob_status == "yes"),
      n_hosp_ob_unknown = sum(ob_status == "unknown"),
      .groups = "drop")
}
