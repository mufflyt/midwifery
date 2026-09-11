#!/usr/bin/env Rscript
#' @title Geocoding completeness by AMCB certification status, among matched
#'
#' @description
#' Feeds the "no geocodable address" stage of
#' `make_cohort_exclusion_flow_figure.R`. `geography_by_linkage_status.csv`
#' (the existing committed aggregate) breaks geocoding completeness down by
#' MATCH quality (primary vs sensitivity_fuzzy) across every AMCB status
#' pooled together. That isn't the ACTIVE-restricted denominator the
#' exclusion figure needs: `cat_$cohort` in build_stats_catalog.R is likewise
#' pooled across all statuses. Neither answers "of ACTIVE, NPI-matched
#' midwives, how many have an assignable county" -- which requires a fresh
#' person-level join between the frozen linkage (status, match outcome) and
#' the geography artifact (geocode outcome).
#'
#' @section Column names are confirmed, not guessed:
#' This script was written without access to the person-level files (they're
#' gitignored and weren't present on the authoring machine), so every column
#' name below is a best guess from the producing scripts'
#' (`match_amcb_to_npi.R`, `03-geography-hierarchy.R`) own documented output
#' shape, not a name read off real data. Both the id join key and the geocode
#' indicator are resolved defensively against a short candidate list; if none
#' of the candidates are present the script STOPS with the actual column
#' names on both files, rather than silently joining on the wrong key or
#' guessing which column means "geocoded."
#'
#' Output: artifacts/geography_by_amcb_status.csv, one row per
#' (status, match_status), matching the shape of the existing
#' geography_by_linkage_status.csv so both can be read the same way.
#'
#' @family figures
#' @author Tyler Muffly, MD + Claude Code

suppressPackageStartupMessages({
  library(dplyr); library(readr)
})
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "artifact_provenance.R"))

LINKAGE   <- file.path("artifacts", "amcb_npi_linkage_FROZEN.csv")
GEOGRAPHY <- file.path("artifacts", "midwives_geography_FROZEN.csv")
OUT       <- file.path("artifacts", "geography_by_amcb_status.csv")

if (!file.exists(LINKAGE)) {
  stop(sprintf(paste0(
    "%s not found.\n",
    "This script needs the person-level frozen linkage, not the aggregate\n",
    "artifacts/linkage_completeness_by_status.csv -- run it on the machine\n",
    "that holds the frozen cohort (see repin_frozen_cohort.R)."), LINKAGE),
    call. = FALSE)
}
if (!file.exists(GEOGRAPHY)) {
  stop(sprintf(paste0(
    "%s not found.\n",
    "Produced by R/03-geography-hierarchy.R. Run that step first, or point\n",
    "GEOGRAPHY at wherever its output actually landed."), GEOGRAPHY),
    call. = FALSE)
}

linkage <- chr(LINKAGE)
geo     <- chr(GEOGRAPHY)

#' Resolve the first present column from a candidate list, or stop naming
#' every candidate tried and every column actually present.
#' @keywords internal
#' @noRd
.resolve_col <- function(df, candidates, df_name) {
  hit <- candidates[candidates %in% names(df)]
  if (!length(hit)) {
    stop(sprintf(paste0(
      "None of the expected columns (%s) were found in %s.\n",
      "Columns actually present: %s.\n",
      "Update the candidate list in build_geography_by_amcb_status.R once\n",
      "you can see the real schema."),
      paste(candidates, collapse = ", "), df_name,
      paste(names(df), collapse = ", ")), call. = FALSE)
  }
  hit[1]
}

id_link <- .resolve_col(linkage, c("amcb_id", "certification_number"), "the frozen linkage")
id_geo  <- .resolve_col(geo,     c("amcb_id", "certification_number"), "the geography artifact")
status_col <- .resolve_col(linkage, c("status", "amcb_status", "certification_status"),
                           "the frozen linkage")
# "matched" means match_status == "primary" -- the reconciliation's own clean
# definition (reconcile_linkage.R), which deliberately excludes fuzzy-surname
# matches (weak name-identity evidence) and nursing-taxonomy-only matches
# (taxonomy ambiguity) from the confirmed-identity count. npi_match_status
# alone cannot make this distinction -- it folds all three together under
# "matched"/"matched_nursing_taxonomy" -- so match_status is required, not a
# fallback candidate.
match_col  <- .resolve_col(linkage, c("match_status"), "the frozen linkage")
state_col  <- .resolve_col(linkage, c("nppes_state"), "the frozen linkage")
geocode_col <- .resolve_col(geo, c("county_best", "county_exact", "geo_class"),
                            "the geography artifact")

# States/territories ACOG assigns no district to (overseas military APO/FPO
# codes and US territories). MUST match build_table1_midwives.R's
# ACOG_EXPECTED_UNMAPPED exactly -- duplicated here (no shared config exists
# yet) rather than sourced, so if that list changes there this one needs the
# same edit.
ACOG_UNMAPPED <- c("AA", "AE", "AP", "GU", "PR", "VI", "AS", "MP", "FM", "PW", "MH")

linkage_std <- linkage %>%
  transmute(.id = .data[[id_link]], status = .data[[status_col]],
           match_status = .data[[match_col]], nppes_state = .data[[state_col]])
geo_std <- geo %>%
  transmute(.id = .data[[id_geo]],
           geocoded = !is.na(.data[[geocode_col]]) & nzchar(trimws(.data[[geocode_col]])))

joined <- tryCatch(
  dplyr::left_join(linkage_std, geo_std, by = ".id"),
  error = function(e) stop(sprintf("Join failed on id column '%s'/'%s': %s",
                                   id_link, id_geo, conditionMessage(e)), call. = FALSE)
)

joined <- joined %>%
  mutate(match_bucket = if_else(match_status == "primary", "matched", "not_matched"),
         geocoded = coalesce(geocoded, FALSE),
         acog_unmapped = geocoded & nppes_state %in% ACOG_UNMAPPED)

out <- joined %>%
  group_by(status, match_status = match_bucket) %>%
  summarise(n = n(), n_geocoded = sum(geocoded),
           n_acog_unmapped = sum(acog_unmapped), .groups = "drop") %>%
  arrange(status, match_status)

stopifnot(sum(out$n) == nrow(linkage))

write_with_provenance(out, OUT, inputs = c(LINKAGE, GEOGRAPHY))
cat(sprintf("Wrote %s (%d rows)\n", OUT, nrow(out)))
