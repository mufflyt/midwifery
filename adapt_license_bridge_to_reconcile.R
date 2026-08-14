#!/usr/bin/env Rscript
# =============================================================================
# Adapter: license-bridge crosswalk -> reconcile_linkage.R vocabulary
# =============================================================================
#
# amcb_license_bridge.R speaks in its own columns (`linked_npi`,
# `linkage_method`, `deterministic_status`); reconcile_linkage.R and the frozen
# artifact speak in `npi` / `npi_match_status` / `npi_match_method`, where
# `state_of()` reads "matched" and anything matching `^ambiguous` as
# quarantined. This projects the former onto the latter so the deterministic
# license result can be MERGED (by certification_number) into the matched
# artifact as a pre-pass -- a keyed license match pre-empts name scoring for
# that row -- rather than fed to reconcile as a standalone A/B arm (it lacks the
# name-scoring columns, e.g. n_candidates_pre_rank, that an arm needs).
#
# Deliberately narrow: it returns only the four columns the merge needs, keyed
# on certification_number. Join it into the matched frame and coalesce.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
})

#' Project a license-bridge crosswalk into reconcile's linkage vocabulary
#'
#' @param crosswalk The combined crosswalk from `amcb_license_bridge.R`
#'   (must carry `certification_number`, `linked_npi`, `linkage_method`,
#'   `deterministic_status`).
#' @return A tibble keyed on `certification_number` with `npi`,
#'   `npi_match_status` (`matched` / `ambiguous_license_*` / `unmatched`) and
#'   `npi_match_method`.
#' @export
adapt_license_bridge_to_reconcile <- function(crosswalk) {
  required <- c(
    "certification_number", "linked_npi",
    "linkage_method", "deterministic_status"
  )
  missing_cols <- base::setdiff(required, base::names(crosswalk))
  if (base::length(missing_cols) > 0L) {
    base::stop(
      "crosswalk missing columns: ",
      base::paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }

  crosswalk |>
    dplyr::transmute(
      certification_number = .data$certification_number,
      npi_match_status = dplyr::case_when(
        .data$linkage_method %in% c("license_exact", "prior_match") &
          !base::is.na(.data$linked_npi)                 ~ "matched",
        .data$linkage_method == "license_exact_conflicts_with_prior" ~
          "ambiguous_license_prior_conflict",
        .data$deterministic_status == "license_match_surname_conflict" ~
          "ambiguous_license_surname_conflict",
        .data$deterministic_status == "license_conflict" ~
          "ambiguous_license_collision",
        TRUE                                             ~ "unmatched"
      ),
      npi = dplyr::if_else(
        .data$npi_match_status == "matched",
        .data$linked_npi, NA_character_
      ),
      npi_match_method = dplyr::if_else(
        .data$npi_match_status == "matched",
        .data$linkage_method, NA_character_
      )
    )
}
