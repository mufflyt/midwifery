# Shared string helpers for the worksite-address scripts
# (build_worksite_address_resolution.R, build_worksite_leaflet_map.R,
# build_worksite_setting_crosswalk.R). Pulled out here because all three
# defined byte-identical copies, which tests/ci_hygiene.R's H4 check exists
# to catch -- the risk being that a future edit fixes a bug in one copy and
# not the others.

#' Is each element non-missing and non-blank after trimming?
nonempty <- function(x) !is.na(x) & nzchar(str_squish(as.character(x)))

#' The first non-blank value, or NA if every value is blank
first_nonempty <- function(x) {
  x <- x[nonempty(x)]
  if (length(x)) x[[1L]] else NA_character_
}

#' Sorted, deduplicated, semicolon-joined non-blank values, or NA if none
collapse_unique <- function(x) {
  x <- sort(unique(x[nonempty(x)]))
  if (length(x)) paste(x, collapse = "; ") else NA_character_
}

#' The first finite value, or NA if none is finite
first_finite <- function(x) {
  x <- x[is.finite(x)]
  if (length(x)) x[[1L]] else NA_real_
}
