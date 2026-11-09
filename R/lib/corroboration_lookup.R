#' Ambiguity-safe single-state lookup for one (npi, year) in a source frame
#'
#' A source can carry more than one row for the same (npi, year) with
#' DIFFERENT states (confirmed in this project's DAC and Open Payments
#' extracts -- see docs/TECHNICAL_APPENDIX_MIGRATION_CORROBORATION.md).
#' Picking the first such row answers based on input row order, not
#' evidence. This returns the single state only when the source itself
#' agrees on it; otherwise it reports the ambiguity rather than resolving it.
#'
#' @param src_df `data.frame` with at least `npi`, `year`, `state` columns.
#' @param npi_val,year_val scalar lookup key.
#' @return `list(state, ambiguous)`: `state` is the single matching value, or
#'   `NA_character_` if the source has no record (ambiguous = FALSE) or more
#'   than one distinct value (ambiguous = TRUE) for that (npi, year).
lookup_state <- function(src_df, npi_val, year_val) {
  v <- unique(src_df$state[src_df$npi == npi_val & src_df$year == year_val])
  if (length(v) == 0) list(state = NA_character_, ambiguous = FALSE)
  else if (length(v) == 1) list(state = v, ambiguous = FALSE)
  else list(state = NA_character_, ambiguous = TRUE)
}

#' Sources known to share underlying lineage, not independent evidence
#'
#' CMS builds the DAC ("Doctors and Clinicians") address field from PECOS
#' enrollment data -- the same system this project's own PECOS revalidation
#' extract reads. Two sources agreeing when both trace to one upstream
#' system is one witness counted twice, not two.
SHARED_LINEAGE_GROUPS <- list(c("dac_physician_compare", "pecos_revalidation"))

#' Does a set of corroborating sources constitute independent evidence?
#'
#' TRUE only if at least 2 sources corroborate AND they are not all members
#' of the same shared-lineage group (see `SHARED_LINEAGE_GROUPS`). A single
#' source, or a set wholly contained in one shared-lineage group (e.g. just
#' DAC+PECOS), does not count as independent corroboration.
#'
#' @param sources_vec `character` vector of source names that corroborated.
#' @return scalar `logical`.
is_independent_source_set <- function(sources_vec) {
  sources_vec <- unique(sources_vec)
  if (length(sources_vec) < 2) return(FALSE)
  for (grp in SHARED_LINEAGE_GROUPS) {
    if (all(sources_vec %in% grp)) return(FALSE)
  }
  TRUE
}
