#' Validate and normalize a state abbreviation
#'
#' Upper-cases and trims, then maps anything not a real 2-letter state/
#' territory code to NA rather than passing through a typo or a full state
#' name as if it were comparable to one. Shared by every script in the
#' state-source audit (`build_state_source_audit.R`,
#' `build_state_source_pairwise_audit.R`, `build_cross_source_comparison.R`,
#' `extract_open_payments_profile_supplement.R`) so a change to which codes
#' count as valid only has to be made once.
#'
#' @param x `character`: raw state field from any source.
#' @return `character`: a valid 2-letter code, or `NA_character_`.
VALID_STATES <- c(state.abb, "DC", "PR", "VI", "GU", "AS", "MP")
clean_state <- function(x) {
  x <- toupper(trimws(x))
  as.character(ifelse(x %in% VALID_STATES, x, NA_character_))
}
