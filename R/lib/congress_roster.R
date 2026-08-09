#!/usr/bin/env Rscript
#' @title 119th-Congress representative roster for district map badges
#'
#' @description
#' Sitting House member per congressional district: name, party and official
#' URL, in the shape `mm_rep_badge()` (isochrones `R/variety_sentences.R`)
#' expects.
#'
#' @section Source:
#' `unitedstates/congress-legislators`, the long-running open dataset behind
#' most civic-tech uses of Congress membership. Fetched from
#' <https://unitedstates.github.io/congress-legislators/legislators-current.csv>
#' and cached to `data/congress/legislators_current.csv`, because the roster
#' changes with resignations and special elections and an analysis should not
#' silently re-fetch a different Congress mid-run.
#'
#' Note the `theunitedstates.io` host no longer resolves; the GitHub Pages
#' domain above is the live one.
#'
#' @section A vintage mismatch that cannot be fixed, only disclosed:
#' ACS 2023 reports congressional districts on **118th Congress** boundaries --
#' the API labels them so explicitly ("Congressional District 1 (118th
#' Congress), Colorado"). The sitting members are the **119th** Congress.
#' Several states redrew districts between the two (Alabama, Georgia, Louisiana,
#' New York and North Carolina among them), so in those states a 119th-Congress
#' member is being attached to a district whose ACS statistics describe slightly
#' different ground.
#'
#' This is disclosed rather than corrected: there is no ACS release on 119th
#' boundaries yet, and silently pairing them would assert a correspondence that
#' does not hold. `district_profiles` carries `boundary_vintage` on every row.
#'
#' @section Delegates:
#' DC, Puerto Rico and the territories send non-voting delegates. They are
#' included with `role = "Delegate"` rather than dropped, since ACS reports DC
#' and PR, and a blank badge would read as "no representative" rather than
#' "not a voting member".
#'
#' @family dependencies
#' @author Tyler Muffly, MD + Claude Code
#' @name congress_roster
NULL

LEG_URL   <- "https://unitedstates.github.io/congress-legislators/legislators-current.csv"
LEG_CACHE <- file.path("data", "congress", "legislators_current.csv")

#' Fetch (or load) the current House roster keyed by state FIPS + district
#'
#' @param refresh [logical(1)]: re-download even if cached.
#' @return [data.frame] `state_abbr`, `district`, `rep_name`, `party`, `url`,
#'   `role`.
#' @family dependencies
#' @export
load_house_roster <- function(refresh = FALSE) {
  dir.create(dirname(LEG_CACHE), showWarnings = FALSE, recursive = TRUE)
  if (refresh || !file.exists(LEG_CACHE)) {
    ok <- tryCatch({
      utils::download.file(LEG_URL, LEG_CACHE, quiet = TRUE); TRUE
    }, error = function(e) FALSE)
    if (!ok && !file.exists(LEG_CACHE)) {
      stop("load_house_roster: could not fetch ", LEG_URL,
           " and no cache at ", LEG_CACHE, call. = FALSE)
    }
  }
  leg <- readr::read_csv(LEG_CACHE, show_col_types = FALSE, progress = FALSE,
                         col_types = readr::cols(.default = readr::col_character()))

  reps <- leg %>%
    dplyr::filter(type == "rep") %>%
    dplyr::transmute(
      state_abbr = state,
      # At-large districts are recorded as 0; ACS reports them as "00".
      district = sprintf("%02d", as.integer(district)),
      rep_name = full_name,
      party = party,
      url = url,
      role = dplyr::if_else(state_abbr %in% c("DC", "PR", "VI", "GU", "AS", "MP"),
                            "Delegate", "Rep."))

  # One sitting member per district. A duplicate means the roster spans a
  # transition (a resignation not yet reflected), and silently keeping both
  # would double every district row downstream.
  dup <- reps %>% dplyr::count(state_abbr, district) %>% dplyr::filter(n > 1)
  if (nrow(dup)) {
    stop(sprintf("load_house_roster: %d district(s) have more than one sitting member (e.g. %s-%s). Roster may span a transition.",
                 nrow(dup), dup$state_abbr[1], dup$district[1]), call. = FALSE)
  }
  reps
}
