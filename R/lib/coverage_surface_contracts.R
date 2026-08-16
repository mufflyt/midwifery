# =============================================================================
# Contracts for the dissolved coverage surfaces
# =============================================================================
# Two properties of build_midwifery_isochrone_map.R produced a plausible map
# from a broken input, which is the worst failure mode a figure can have.
#
# 1. THE LAND CLIP WAS CONDITIONAL ON A USB DRIVE.
#
#        water_dir <- "/Volumes/MufflySamsung/nhdplus_hr/water_masks"
#        if (dir.exists(water_dir)) { ...clip... }
#
#    With the drive unmounted the clip is skipped, no error is raised, and the
#    surfaces once again run over the Great Lakes -- 10.3% and 12.9% open water
#    in the published bands, counted as drivable ground. Whether the map is
#    correct depends on whether a drive happened to be plugged in, and nothing
#    in the output says which happened. A surface must therefore CARRY whether
#    it was clipped, and an unclipped surface must not be presentable as final.
#
# 2. NESTING WAS ENFORCED BY MUTATION.
#
#        g <- st_union(unions[[a]], unions[[b]]); st_geometry(unions[[a]]) <- g
#
#    A 30-minute surface escaping its own 60-minute surface is real evidence:
#    the two routing engines disagree by up to 15% in area, and an escape is
#    how that disagreement shows up geographically. Absorbing the smaller band
#    into the larger makes the invariant true and destroys the evidence in the
#    same statement. Measure the escape FIRST, keep the number, then absorb.
#
# Sourced by build_midwifery_isochrone_map.R; tested by
# tests/test_cycle14_coverage_surfaces.R.
# =============================================================================

#' Area of the inner band that lies OUTSIDE the outer band
#'
#' Measured before any absorption. Zero means the bands already nest.
#'
#' @param inner,outer [sf|sfc]: dissolved band surfaces, same CRS.
#' @return [numeric(1)] escaped area in km^2 (0 when nesting already holds).
nesting_escape_km2 <- function(inner, outer) {
  gi <- sf::st_make_valid(sf::st_geometry(inner))
  go <- sf::st_make_valid(sf::st_geometry(outer))
  if (length(gi) == 0L) return(0)
  # Required by R/spatial_crs_contract.R before any spatial binary operation.
  # Cycle 11's T104 caught this function missing it -- the guard written two
  # cycles ago failing the code written in this one, which is the point of it.
  if (!exists("assert_crs_equal", mode = "function"))
    source(file.path("R", "spatial_crs_contract.R"))
  assert_crs_equal(gi, go, "st_difference(nesting escape)")
  d <- suppressWarnings(sf::st_difference(gi, go))
  if (length(d) == 0L) return(0)
  a <- suppressWarnings(sum(as.numeric(sf::st_area(d))))
  if (!is.finite(a)) 0 else a / 1e6
}

#' A published coverage surface must be ONE feature
#'
#' The dissolved union is what makes the map publishable: individual polygons
#' would place identifiable people. One feature per band is the privacy
#' contract, not a tidiness preference.
#'
#' @param x [sf|sfc]: a band surface.
#' @param band [character(1)]: label for the message.
#' @return [invisible(TRUE)]; stops otherwise.
assert_dissolved_privacy <- function(x, band = "surface") {
  n <- length(sf::st_geometry(x))
  if (n != 1L) {
    stop(sprintf(paste0("%s holds %d features; a published coverage surface ",
                        "must be a single dissolved union. Per-provider ",
                        "polygons place identifiable people."), band, n),
         call. = FALSE)
  }
  invisible(TRUE)
}

#' Record whether the land clip actually ran
#'
#' Returns a one-row provenance record rather than a bare logical so the answer
#' travels with the artifact. `final` is FALSE for an unclipped surface: it may
#' be built and inspected, but it is not a publishable product.
#'
#' @param water_dir [character(1)]: directory of state water masks.
#' @param states [character]: states whose masks are required.
#' @param require_clip [logical(1)]: when TRUE, a missing mask directory is an
#'   error rather than a downgrade. Use for any run that produces a figure.
#' @return [data.frame] one row: clip_applied, masks_found, masks_expected,
#'   water_dir, final.
water_clip_provenance <- function(water_dir, states, require_clip = TRUE) {
  present <- dir.exists(water_dir)
  found <- if (!present) 0L else
    sum(file.exists(file.path(water_dir, sprintf("%s_water_mask.fgb", states))))
  if (require_clip && found < length(states)) {
    stop(sprintf(paste0("land clip unavailable: %d of %d state water masks found ",
                        "under %s. Refusing to build a coverage surface that ",
                        "counts open water as drivable ground -- the Great Lakes ",
                        "defect. Mount the drive, or pass require_clip = FALSE ",
                        "for an explicitly non-final run."),
                 found, length(states), water_dir), call. = FALSE)
  }
  data.frame(clip_applied = found > 0L, masks_found = found,
             masks_expected = length(states), water_dir = water_dir,
             final = found == length(states), stringsAsFactors = FALSE)
}

#' Is a state's "water mask" actually that state's outline?
#'
#' Five states shipped a single-feature mask covering 102-104% of their land
#' area. Subtracting it deletes every isochrone in the state, which reads as
#' "no midwives here" rather than as a broken input.
#'
#' @param mask_area_km2,state_land_km2 [numeric]: areas.
#' @param max_pct [numeric(1)]: real inland water is a few percent.
#' @return [logical] TRUE where the mask is inverted.
is_inverted_water_mask <- function(mask_area_km2, state_land_km2, max_pct = 50) {
  r <- 100 * mask_area_km2 / state_land_km2
  !is.na(r) & r > max_pct
}

#' Is a state's "water mask" too large for that state's census water area?
#'
#' The land-percentage heuristic is useful for synthetic tests, but the real
#' failure separates cleanly on census AWATER: Michigan legitimately has a large
#' water mask, while the inverted AR/IA/KS/MO/WV masks are 45-162x their census
#' water area.
#'
#' @param mask_area_km2,census_water_km2 [numeric]: areas.
#' @param max_ratio [numeric(1)]: maximum tolerated mask-to-AWATER ratio.
#' @return [logical] TRUE where the mask is too large to be trusted as water.
is_water_mask_larger_than_awater <- function(mask_area_km2, census_water_km2,
                                             max_ratio = 5) {
  r <- mask_area_km2 / census_water_km2
  !is.na(r) & is.finite(r) & r > max_ratio
}
