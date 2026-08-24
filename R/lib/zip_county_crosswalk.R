# =============================================================================
# The ZIP -> county crosswalk, defined once
# =============================================================================
# Four scripts built this crosswalk from data/zcta_county_2020.txt with four
# private copies of the same six lines. Two of the copies carried a filter and
# two did not, and that divergence published a wrong number for eight months.
#
# What the missing filter did
# ---------------------------
# 903 of the 47,863 rows in the Census ZCTA-county relationship file have no
# ZCTA at all: GEOID_ZCTA5_20 is NA. pad5() propagates the NA, so the copies
# without the filter carried 903 rows keyed on NA. group_by(zip5) then collapsed
# all 903 into ONE row -- zip5 = NA, GEOID = 02290 -- and 02290 is Yukon-Koyukuk
# Census Area, Alaska, RUCC 8.
#
# dplyr's left_join() matches NA to NA by default. So every midwife with no
# practice ZIP joined that row and was placed in a remote Alaskan census area.
# Not dropped, not Unknown -- placed, with a real county and a real RUCC, which
# is why coalesce(..., "Unknown") never fired and nothing downstream complained.
# All 1,545 midwives in the newly-NPI-resolved group have no practice ZIP, and
# all 1,545 were published as "Nonmetro, remote (7-9)".
#
# A missing value wearing the face of a real one. zip5_key() in
# common_helpers.R carries the same warning about "00000" for the same reason.
#
# Why this file exists rather than a fifth filter
# -----------------------------------------------
# Adding the filter to the two broken copies would fix today's number and leave
# four copies to diverge again. The crosswalk is defined here, once, and the
# NA key is refused rather than filtered: assert_no_na_key() makes returning a
# crosswalk that can absorb missing ZIPs an error, not an oversight.
#
# Base R plus dplyr/readr, matching the scripts that call it.
# =============================================================================

#' Refuse a lookup table whose key can absorb missing values
#'
#' A join key holding NA is not a lookup, it is a magnet: under dplyr's default
#' na_matches = "na" every unmatched row on the left finds it.
#'
#' @param d [data.frame]: the lookup table.
#' @param key [character]: the key column.
#' @param what [character]: name used in the error.
#' @return `d`, invisibly, when the key is clean.
#' @keywords internal
#' @noRd
assert_no_na_key <- function(d, key, what) {
  n_na <- sum(is.na(d[[key]]))
  if (n_na > 0) {
    stop(sprintf(paste0("INVARIANT: '%s' holds %d missing value(s) in %s. ",
                        "left_join() matches NA to NA, so every row with no %s ",
                        "would be assigned this row's value rather than left ",
                        "unmatched."),
                 key, n_na, what, key), call. = FALSE)
  }
  invisible(d)
}

#' ZCTA-to-county part rows, with unusable rows dropped
#'
#' One row per ZCTA-county intersection, carrying the land area of the part so a
#' caller can pick a dominant county or measure how split a ZIP is.
#'
#' Rows with no ZCTA or no county are dropped rather than kept as NA: they
#' describe county area that falls in no ZCTA, which is a real fact about the
#' Census file and not a ZIP anybody can look up.
#'
#' @param path [character]: data/zcta_county_2020.txt.
#' @return [tibble] zip5, GEOID, land.
#' @keywords internal
#' @noRd
zcta_county_parts <- function(path) {
  if (!file.exists(path)) {
    stop("Missing ", path,
         ". Download the Census ZCTA-county relationship file.", call. = FALSE)
  }
  out <- readr::read_delim(path, delim = "|", show_col_types = FALSE,
                           progress = FALSE) %>%
    dplyr::filter(!is.na(.data$GEOID_ZCTA5_20), !is.na(.data$GEOID_COUNTY_20)) %>%
    dplyr::transmute(zip5 = pad5(.data$GEOID_ZCTA5_20),
                     GEOID = pad5(.data$GEOID_COUNTY_20),
                     land = suppressWarnings(as.numeric(.data$AREALAND_PART)))
  # pad5() can still return NA from a non-NA but unparseable value. Today every
  # NA comes from a NA source column and the filter above removes all 903 of
  # them, but the guard is on the OUTPUT so a future vintage cannot reintroduce
  # the defect through a different door.
  assert_no_na_key(out, "zip5", basename(path))
  out
}

#' One county per ZIP: the county holding the largest share of its land
#'
#' @param path [character]: data/zcta_county_2020.txt.
#' @return [tibble] zip5, GEOID -- one row per zip5.
#' @keywords internal
#' @noRd
zip_county_dominant <- function(path) {
  out <- zcta_county_parts(path) %>%
    dplyr::group_by(.data$zip5) %>%
    dplyr::slice_max(.data$land, n = 1, with_ties = FALSE) %>%
    dplyr::ungroup() %>%
    dplyr::select("zip5", "GEOID")
  assert_no_na_key(out, "zip5", sprintf("dominant-county crosswalk from %s",
                                        basename(path)))
  out
}
