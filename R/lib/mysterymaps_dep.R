#!/usr/bin/env Rscript
#' @title Dependency on the mysterymaps leaflet helpers
#'
#' @description
#' The `mm_*` map helpers live in mufflyt/isochrones-main at
#' `R/mysterymaps_urogyn.R`, staged there for the {mysterymaps} package
#' (github.com/mufflyt/mysterymaps). That is the CANONICAL home. Nothing here
#' re-implements or copies them.
#'
#' @section Why this file exists:
#' The first draft of the midwifery access map hand-rolled a zero-aware Jenks
#' scale that was a line-for-line duplicate of `mm_jenks_zero_scale()`, and
#' separately re-derived conventions the canonical builder already encodes:
#' canvas rendering, a scale bar, and a dedicated map pane so point markers stay
#' clickable above a choropleth. That is exactly the drift this project has been
#' bitten by before -- see R/lib/isochrones_dep.R, where the same mistake with
#' the gender gate, the credential helpers and `rank_one_to_one()` meant a fix
#' applied to one copy was a fix applied to none.
#'
#' @section What is reused:
#' `mm_jenks_zero_scale()`, `mm_add_coverage_surfaces()`,
#' `mm_register_base_legend()`, `mm_base_legend_switcher()` and
#' `mm_zoom_gated_labels()` are all called directly.
#'
#' @section The capability the library lacked was added TO the library:
#' The existing builders (`mm_build_choropleth_point_map()`,
#' `mm_access_choropleth_map()`) are organised around per-geography values --
#' points counted into polygons, or drive time to the closest provider. A
#' dissolved coverage union has no per-geography value at all, so neither
#' builder fit.
#'
#' An earlier version of this file argued that this justified keeping the
#' layer-assembly local, on the grounds that generalising a canonical function
#' "to suit one caller" was the greater sin. That reasoning was wrong, and it is
#' the argument against every library improvement ever made. When the shared
#' library cannot express something, the fix is to teach it -- generically --
#' not to keep a private copy and write a paragraph defending it. Private code
#' is exactly how the duplicate Jenks scale got written.
#'
#' So `mm_add_coverage_surfaces()` and friends now live in
#' `R/mysterymaps_urogyn.R` alongside the rest. They take any named list of
#' polygon layers and are not aware of midwives.
#'
#' @section It found a bug in the canonical map:
#' Writing `mm_base_legend_switcher()` surfaced the same defect in
#' `mm_access_choropleth_map()`: it adds two legends with `group = L$time` and
#' `group = L$supply` while those are `baseGroups`, and
#' `leaflet::addLegend(group=)` only follows OVERLAY groups. Both legends
#' therefore render at once in the urogyn maps. Had the workaround stayed local,
#' that bug would still be shipping.
#'
#' @section Resolution order:
#' \enumerate{
#'   \item `MYSTERYMAPS_HOME` environment variable, if set.
#'   \item `~/isochrones-main`, the conventional checkout location.
#' }
#'
#' @section It fails loudly, and that is deliberate:
#' If the helpers cannot be found the loader aborts with instructions rather
#' than falling back to a local copy. A silent fallback is how the duplicate
#' scale got written in the first place.
#'
#' @family dependencies
#' @author Tyler Muffly, MD + Claude Code
#' @name mysterymaps_dep
NULL

#' Path to the canonical mysterymaps source
#'
#' @return [character(1)] absolute path to the directory holding the `mm_*`
#'   helpers, honouring the `MYSTERYMAPS_HOME` environment variable when set.
#' @details
#' Resolved rather than hard-coded so a checkout in a different location does
#' not silently fall back to a stale copy -- the drift this file exists to
#' prevent.
#' @examples
#' \dontrun{
#' mm_home()
#' }
#' @keywords internal
mm_home <- function() {
  cand <- c(Sys.getenv("MYSTERYMAPS_HOME"), path.expand("~/isochrones-main"))
  cand <- cand[nzchar(cand)]
  hit <- cand[file.exists(file.path(cand, "R", "mysterymaps_urogyn.R"))]
  if (!length(hit))
    stop("mysterymaps helpers not found. Looked for R/mysterymaps_urogyn.R under:\n  ",
         paste(cand, collapse = "\n  "),
         "\nSet MYSTERYMAPS_HOME to your isochrones-main checkout.", call. = FALSE)
  hit[1]
}

#' Load the canonical mm_* helpers into the calling environment
#'
#' The helper file resolves its own dependencies with `here::here()`, so it must
#' be sourced with the working directory at that project root; the directory is
#' restored on exit.
#'
#' @return Invisibly, the character vector of `mm_*` objects loaded.
#' @param quiet [logical(1)]: suppress the source() messages.
#'   Default TRUE.
#' @return invisibly TRUE once the helpers are attached; stops if the
#'   canonical source cannot be found, rather than continuing with a
#'   partially loaded namespace.
#' @examples
#' \dontrun{
#' load_mysterymaps()
#' mm_jenks_zero_scale(values)
#' }
load_mysterymaps <- function(quiet = TRUE) {
  home <- mm_home()
  owd <- setwd(home); on.exit(setwd(owd), add = TRUE)
  f <- file.path("R", "mysterymaps_urogyn.R")
  if (quiet) {
    suppressWarnings(suppressMessages(sys.source(f, envir = globalenv())))
  } else {
    sys.source(f, envir = globalenv())
  }
  got <- ls(globalenv(), pattern = "^mm_")
  if (!"mm_jenks_zero_scale" %in% got)
    stop("mysterymaps loaded but mm_jenks_zero_scale is absent -- wrong file?",
         call. = FALSE)
  invisible(got)
}
