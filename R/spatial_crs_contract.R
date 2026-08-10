#' @title Spatial CRS and Geometry Contract Enforcement
#'
#' @description
#' Enforces strict Coordinate Reference System (CRS) matching before spatial
#' operations to prevent silent geometry errors.
#'
#' @details
#' Normalizes CRS at ingestion boundaries rather than within overlap logic.
#' Required to avoid issues like Hall of Shame #30 (EPSG:4326 vs 9311 mismatch).
#'
#' @family spatial-contracts
#' @name spatial_crs_contract
NULL

# =============================================================================
# spatial_crs_contract.R — CRS and Geometry Contract Enforcement
# =============================================================================
#
# PURPOSE:
#   Prevents Hall of Shame #30 (EPSG:4326 vs 9311 silent mismatch).
#   Three layers of protection:
#     1. assert_crs_equal() — before any spatial binary operation
#     2. validate_geometry_contract() — structural + semantic geometry checks
#     3. validate_overlap_plausibility() — scientific sanity on overlap output
#
# RULE:
#   CRS normalization happens at INGESTION BOUNDARIES, not inside overlap logic.
#   Every spatial binary operation must be preceded by assert_crs_equal().
#
# =============================================================================

#' Assert CRS Equality Before Spatial Operations
#'
#' Hard stop if two sf objects have different coordinate reference systems.
#' Call this before every \code{st_intersection}, \code{st_join},
#' \code{st_union}, \code{st_difference}, or \code{st_intersects}.
#'
#' @param x An sf object.
#' @param y An sf object.
#' @param operation Character. Name of the spatial operation (for error
#'   messages).
#' @return Invisible TRUE. Stops with fatal error on mismatch.
#'
#' @examples
#' \dontrun{
#'   assert_crs_equal(isochrones, tracts, "st_intersection")
#' }
#'
#' @family spatial-contracts
#' @concept geometry-integrity
#' @seealso \code{\link{validate_geometry_contract}} for structural geometry
#'   checks, \code{\link{validate_overlap_plausibility}} for output sanity.
#' @export
assert_crs_equal <- function(x, y, operation = "spatial operation") {
  crs_x <- sf::st_crs(x)
  crs_y <- sf::st_crs(y)

  # Reject undefined CRS on either input. Two NA CRSs satisfy
  # identical(crs_x, crs_y) but produce garbage from st_intersection/st_join.
  if (is.na(crs_x)) {
    stop(sprintf(
      paste0(
        "[CRS CONTRACT] Layer 1 has undefined CRS before %s.\n",
        "  Fix: sf::st_set_crs(x, <epsg>) if you know the CRS, or ",
        "sf::st_transform(x, <epsg>) to project."
      ), operation
    ), call. = FALSE)
  }
  if (is.na(crs_y)) {
    stop(sprintf(
      paste0(
        "[CRS CONTRACT] Layer 2 has undefined CRS before %s.\n",
        "  Fix: sf::st_set_crs(y, <epsg>) if you know the CRS, or ",
        "sf::st_transform(y, <epsg>) to project."
      ), operation
    ), call. = FALSE)
  }

  if (!identical(crs_x, crs_y)) {
    epsg_x <- tryCatch(crs_x$epsg, error = function(e) NA)
    epsg_y <- tryCatch(crs_y$epsg, error = function(e) NA)
    stop(sprintf(
      paste0(
        "[CRS CONTRACT] CRS mismatch before %s.\n",
        "  Layer 1: EPSG:%s (%s)\n",
        "  Layer 2: EPSG:%s (%s)\n",
        "  This produces scientifically invalid spatial results.\n",
        "  Fix: call sf::st_transform() on one layer before the operation.\n",
        "  See Hall of Shame #30."
      ),
      operation,
      ifelse(is.na(epsg_x), "unknown", epsg_x), crs_x$input,
      ifelse(is.na(epsg_y), "unknown", epsg_y), crs_y$input
    ), call. = FALSE)
  }
  invisible(TRUE)
}


#' Validate Geometry Contract for Spatial Analysis
#'
#' Checks that an sf object meets structural and semantic requirements
#' for area-weighted overlap computation: correct CRS, valid geometries,
#' polygon type, non-zero area, and continental extent.
#'
#' @param sf_obj An sf object to validate.
#' @param label Character. Human-readable label for error messages.
#' @param expected_crs Integer. Expected EPSG code (default: 9311 for CONUS
#'   Albers).
#' @param expected_geom_types Character vector. Acceptable geometry types.
#' @param min_area_km2 Numeric. Minimum total area in km² (catches collapsed
#'   geometries).
#' @param expected_bbox Named numeric vector with xmin, xmax, ymin, ymax bounds.
#'   Default: CONUS extent in EPSG:9311.
#' @param strict Logical. If TRUE (default), violations are fatal. If FALSE,
#'   warnings.
#'
#' @return Named list with \code{valid} (logical) and \code{issues} (character
#'   vector).
#'
#' @examples
#' \dontrun{
#'   validate_geometry_contract(isochrones, "FPMRS 30-min isochrones")
#' }
#'
#' @family spatial-contracts
#' @concept geometry-integrity
#' @seealso \code{\link{assert_crs_equal}} for pre-operation CRS checks,
#'   \code{\link{validate_overlap_plausibility}} for output-level sanity.
#' @export
validate_geometry_contract <- function(
  sf_obj,
  label = "sf_object",
  expected_crs = 9311L,
  expected_geom_types = c("POLYGON", "MULTIPOLYGON"),
  min_area_km2 = 100,
  expected_bbox = c(xmin = -2500000, xmax = 2500000, ymin = -1500000, ymax = 1600000),
  strict = TRUE
) {
  issues <- character(0)

  if (n_unallocated > 0L) {
    issues <- c(issues, sprintf(
      "Population: %d of %d tracts have no allocated population, so the %s total below is a floor, not a count",
      n_unallocated, nrow(overlap_df), format(population, big.mark = ",")))
  }

  # 1. CRS check
  actual_crs <- tryCatch(sf::st_crs(sf_obj)$epsg, error = function(e) NA)
  if (is.na(actual_crs) || actual_crs != expected_crs) {
    issues <- c(issues, sprintf(
      "CRS: expected EPSG:%d, got EPSG:%s", expected_crs,
      ifelse(is.na(actual_crs), "unknown", actual_crs)
    ))
  }

  # 2. Geometry type check
  geom_types <- unique(as.character(sf::st_geometry_type(sf_obj)))
  bad_types <- setdiff(geom_types, expected_geom_types)
  if (length(bad_types) > 0) {
    issues <- c(issues, sprintf(
      "Geometry types: found %s (expected only %s)",
      paste(bad_types, collapse = ", "),
      paste(expected_geom_types, collapse = ", ")
    ))
  }

  # 3. Validity check
  n_invalid <- sum(!sf::st_is_valid(sf_obj))
  if (n_invalid > 0) {
    issues <- c(issues, sprintf(
      "Validity: %d / %d geometries invalid", n_invalid, nrow(sf_obj)
    ))
  }

  # 4. Non-zero area check
  total_area_km2 <- tryCatch(
    sum(as.numeric(sf::st_area(sf_obj))) / 1e6,
    error = function(e) 0
  )
  if (total_area_km2 < min_area_km2) {
    issues <- c(issues, sprintf(
      "Area: %.1f km² (minimum %.1f km²) — geometry may have collapsed",
      total_area_km2, min_area_km2
    ))
  }

  # 5. Bbox sanity (only if CRS matches expected)
  if (is.na(actual_crs) || actual_crs == expected_crs) {
    bb <- sf::st_bbox(sf_obj)
    if (!is.null(expected_bbox) && length(expected_bbox) == 4) {
      if (bb["xmin"] < expected_bbox["xmin"] * 2 || bb["xmax"] > expected_bbox["xmax"] * 2 ||
          bb["ymin"] < expected_bbox["ymin"] * 2 || bb["ymax"] > expected_bbox["ymax"] * 2) {
        issues <- c(issues, sprintf(
          "Bbox: [%.0f, %.0f, %.0f, %.0f] outside expected CONUS range",
          bb["xmin"], bb["xmax"], bb["ymin"], bb["ymax"]
        ))
      }
    }
  }

  # 6. Empty geometry check
  n_empty <- sum(sf::st_is_empty(sf_obj))
  if (n_empty > 0) {
    issues <- c(issues, sprintf(
      "Empty: %d / %d geometries are empty", n_empty, nrow(sf_obj)
    ))
  }

  result <- list(valid = length(issues) == 0, issues = issues)

  if (length(issues) > 0) {
    msg <- sprintf(
      "[GEOMETRY CONTRACT] %s failed %d check(s):\n  %s",
      label, length(issues), paste(issues, collapse = "\n  ")
    )
    if (strict) stop(msg, call. = FALSE)
    else warning(msg, call. = FALSE, immediate. = TRUE)
  } else {
    message(sprintf("[GEOMETRY CONTRACT] %s: PASS (CRS=%d, %d polys, %.0f km²)",
                    label, expected_crs, nrow(sf_obj), total_area_km2))
  }

  invisible(result)
}


#' Validate Overlap Output Plausibility
#'
#' Scientific sanity check on Step 8 overlap output. Catches the
#' "computationally successful but scientifically catastrophic" failure
#' mode where the pipeline produces plausible-looking but undercounted results.
#'
#' @param overlap_df Data frame with GEOID, overlap_fraction,
#'   population_allocated.
#' @param subspecialty Character. Subspecialty name (for expected thresholds).
#' @param drive_time_min Integer. Drive time band in minutes.
#' @param min_states Integer. Minimum number of states expected (default: 30).
#' @param min_tracts Integer. Minimum number of tracts expected (default: 5000).
#' @param min_population Numeric. Minimum population covered (default: 5e6).
#' @param strict Logical. If TRUE (default), violations are fatal.
#'
#' @return Named list with \code{valid}, \code{n_states}, \code{n_tracts},
#'   \code{population}.
#'
#' @examples
#' \dontrun{
#'   validate_overlap_plausibility(batch_df, "FPMRS", 30)
#' }
#'
#' @family spatial-contracts
#' @concept geometry-integrity
#' @seealso \code{\link{assert_crs_equal}} for pre-operation CRS checks,
#'   \code{\link{validate_geometry_contract}} for structural geometry checks,
#'   \code{\link{validate_coord_id_contract}} for coord_id consistency.
#' @export
validate_overlap_plausibility <- function(
  overlap_df,
  subspecialty = "unknown",
  drive_time_min = 30L,
  min_states = 30L,
  min_tracts = 5000L,
  min_population = 5e6,
  strict = TRUE
) {
  n_states <- length(unique(substr(overlap_df$GEOID, 1, 2)))
  n_tracts <- nrow(overlap_df)
  # CYCLE 7, class N1. na.rm = TRUE scored every UNALLOCATED tract as 0
  # residents, so the population floor below was compared against an understated
  # total -- meaning the gate was most likely to pass precisely when allocation
  # had failed. Missing allocations are now counted and reported separately.
  n_unallocated <- sum(is.na(overlap_df$population_allocated))
  population <- sum(overlap_df$population_allocated, na.rm = TRUE)

  issues <- character(0)

  if (n_states < min_states) {
    issues <- c(issues, sprintf(
      "States: %d (expected >= %d) — coverage suspiciously sparse",
      n_states, min_states
    ))
  }

  if (n_tracts < min_tracts) {
    issues <- c(issues, sprintf(
      "Tracts: %s (expected >= %s) — may indicate geometry collapse or CRS mismatch",
      format(n_tracts, big.mark = ","), format(min_tracts, big.mark = ",")
    ))
  }

  if (population < min_population) {
    issues <- c(issues, sprintf(
      "Population: %s (expected >= %s) — undercounting suggests broken spatial join",
      format(population, big.mark = ","), format(min_population, big.mark = ",")
    ))
  }

  result <- list(
    valid = length(issues) == 0,
    n_states = n_states,
    n_tracts = n_tracts,
    population = population,
    issues = issues
  )

  if (length(issues) > 0) {
    msg <- sprintf(
      "[OVERLAP PLAUSIBILITY] %s %d-min FAILED:\n  %s\n  See Hall of Shame #30.",
      subspecialty, drive_time_min, paste(issues, collapse = "\n  ")
    )
    if (strict) stop(msg, call. = FALSE)
    else warning(msg, call. = FALSE, immediate. = TRUE)
  } else {
    message(sprintf(
      "[OVERLAP PLAUSIBILITY] %s %d-min: PASS (%d states, %s tracts, %s pop)",
      subspecialty, drive_time_min, n_states,
      format(n_tracts, big.mark = ","),
      format(population, big.mark = ",")
    ))
  }

  invisible(result)
}


#' Validate Coord ID Contract Between Year Coord Map and Isochrones
#'
#' Asserts that year_coord_map coord_ids are a subset of provider_isochrones
#' coord_ids. A match rate below 95% indicates coord_id generation divergence
#' between the two artifacts — the #1 cause of silent coverage collapse
#' (Hall of Shame #30b).
#'
#' @param year_coord_map Data frame with \code{coord_id} column.
#' @param isochrones sf object with \code{coord_id} column.
#' @param min_match_rate Numeric. Minimum fraction of YCM coord_ids that must
#'   exist in isochrones (default: 0.95 = 95%).
#' @param strict Logical. If TRUE (default), violations are fatal.
#'
#' @return Named list with \code{valid}, \code{match_rate}, \code{n_matched},
#'   \code{n_total}.
#'
#' @examples
#' \dontrun{
#'   validate_coord_id_contract(year_coord_map, provider_isochrones)
#' }
#'
#' @family spatial-contracts
#' @concept geometry-integrity
#' @seealso \code{\link{assert_crs_equal}} for pre-operation CRS checks,
#'   \code{\link{validate_overlap_plausibility}} for output-level sanity.
#' @export
validate_coord_id_contract <- function(
  year_coord_map,
  isochrones,
  min_match_rate = 0.95,
  strict = TRUE
) {
  if (!"coord_id" %in% names(year_coord_map)) {
    stop("[COORD_ID CONTRACT] year_coord_map has no coord_id column.", call. = FALSE)
  }
  if (!"coord_id" %in% names(isochrones)) {
    stop("[COORD_ID CONTRACT] isochrones has no coord_id column.", call. = FALSE)
  }

  ycm_coords <- unique(as.character(year_coord_map$coord_id))
  iso_coords <- unique(as.character(isochrones$coord_id))
  n_matched <- sum(ycm_coords %in% iso_coords)
  n_total <- length(ycm_coords)
  match_rate <- if (n_total > 0) n_matched / n_total else 0

  result <- list(
    valid = match_rate >= min_match_rate,
    match_rate = match_rate,
    n_matched = n_matched,
    n_total = n_total,
    n_missing = n_total - n_matched,
    iso_coords = length(iso_coords)
  )

  if (match_rate < min_match_rate) {
    msg <- sprintf(
      paste0(
        "[COORD_ID CONTRACT] FAILED — only %d / %d (%.1f%%) of year_coord_map coord_ids\n",
        "  exist in provider_isochrones (minimum: %.0f%%).\n",
        "  Isochrone coord_ids: %d unique values.\n",
        "  This means %.0f%% of physicians will be silently dropped from overlap.\n",
        "  Cause: provider_isochrones.rds and year_coord_map were built from\n",
        "  different sources with different coord_id generation logic.\n",
        "  Fix: build provider_isochrones from the same consolidated band files\n",
        "  that produced the year_coord_map. See Hall of Shame #30b."
      ),
      n_matched, n_total, match_rate * 100,
      min_match_rate * 100,
      length(iso_coords),
      (1 - match_rate) * 100
    )
    if (strict) stop(msg, call. = FALSE)
    else warning(msg, call. = FALSE, immediate. = TRUE)
  } else {
    message(sprintf(
      "[COORD_ID CONTRACT] PASS — %d / %d (%.1f%%) coord_ids matched (>= %.0f%%)",
      n_matched, n_total, match_rate * 100, min_match_rate * 100
    ))
  }

  invisible(result)
}
