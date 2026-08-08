# Shared tract-boundary vintage resolver for Step 8 and Step 9.
#
# Both steps must call this function with the same CENSUS_VINTAGE to guarantee
# they read/write the same tract GEOID universe.  Never key batch paths off
# TARGET_YEAR (the isochrone year); key them off CENSUS_VINTAGE (the year
# passed to get_acs()), which determines the boundary vintage of the GEOIDs.
#
# Census Bureau rule (ACS Geography Boundaries by Year):
#   CENSUS_VINTAGE <= 2019  →  2010-boundary tracts  →  returns "2010"
#   CENSUS_VINTAGE >= 2020  →  2020-boundary tracts  →  returns "2020"

#' Resolve tract boundary vintage string from ACS vintage year
#'
#' @param census_vintage Integer or character ACS vintage year
#'   (demographics.yml acs.vintage, passed to get_acs(year=)).
#' @return Character: "2010" or "2020"
resolve_tract_vintage <- function(census_vintage) {
  if (as.integer(census_vintage) >= 2020) "2020" else "2010"
}

#' Build the vintage-tagged Step 8 batch subdirectory path
#'
#' @param base_output_dir Character path to the base Step 8 output directory
#'   (config$accessibility_pipeline_files$output_dir_08).
#' @param census_vintage Integer or character ACS vintage year.
#' @return Character path: base_output_dir/tract_vintage_XXXX
step8_batch_dir <- function(base_output_dir, census_vintage) {
  vintage <- resolve_tract_vintage(census_vintage)
  file.path(base_output_dir, paste0("tract_vintage_", vintage))
}
