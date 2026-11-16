#' Validate and normalize a state abbreviation
#'
#' Upper-cases and trims, translates a full state/territory name or a
#' "XX - FULL NAME" combined form to its 2-letter code, and maps anything
#' else (a typo, a foreign place name, a military postal code) to NA rather
#' than passing it through as if it were comparable to a real code. Shared
#' by every script in the state-source audit (`build_state_source_audit.R`,
#' `build_state_source_pairwise_audit.R`, `build_cross_source_comparison.R`,
#' `extract_open_payments_profile_supplement.R`) so a change to which codes
#' count as valid only has to be made once.
#'
#' @details
#' **Full names are translated, not just rejected.** A field like
#' `"CALIFORNIA"` or `"New York"` is a real, unambiguous state -- treating it
#' as unparseable silently excludes a comparable record for no reason. Only
#' genuinely non-state values (a typo, `"N.Y."`, a foreign city, a military
#' postal code like `"AE"`/`"AP"`) still become `NA`.
#'
#' **The `"XX - FULL NAME"` form only resolves when both halves agree.** A
#' value like `"TX - TEXAS"` resolves to `TX`. A superficially similar value
#' whose two halves disagree, or whose prefix is not itself a valid code
#' (`"ON - ONTARIO"`, a Canadian province), is left `NA` rather than
#' guessed from one half alone.
#'
#' @param x `character`: raw state field from any source.
#' @return `character`: a valid 2-letter code, or `NA_character_`.
VALID_STATES <- c(state.abb, "DC", "PR", "VI", "GU", "AS", "MP")
FULL_STATE_NAME_TO_ABB <- stats::setNames(
  c(toupper(state.abb), "DC", "PR", "VI", "GU", "AS", "MP"),
  toupper(c(state.name, "DISTRICT OF COLUMBIA", "PUERTO RICO", "VIRGIN ISLANDS",
            "GUAM", "AMERICAN SAMOA", "NORTHERN MARIANA ISLANDS"))
)
clean_state <- function(x) {
  x <- toupper(trimws(x))
  out <- rep(NA_character_, length(x))

  is_abb <- x %in% VALID_STATES
  out[is_abb] <- x[is_abb]

  is_full_name <- !is_abb & x %in% names(FULL_STATE_NAME_TO_ABB)
  out[is_full_name] <- FULL_STATE_NAME_TO_ABB[x[is_full_name]]

  is_combo <- is.na(out) & grepl("^[A-Z]{2}\\s*-\\s*[A-Z ]+$", x)
  if (any(is_combo)) {
    halves <- strsplit(x[is_combo], "\\s*-\\s*")
    left <- vapply(halves, `[`, character(1L), 1L)
    right <- vapply(halves, `[`, character(1L), 2L)
    right_abb <- unname(FULL_STATE_NAME_TO_ABB[right])
    agrees <- !is.na(right_abb) & left %in% VALID_STATES & left == right_abb
    combo_idx <- which(is_combo)
    out[combo_idx[agrees]] <- left[agrees]
  }

  out
}
