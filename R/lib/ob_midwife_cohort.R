#' Shared cohort builder: canonical midwives + ABOG Generalist/MFM OB-GYNs
#'
#' DEPENDS on R/lib/cohort_definitions.R being sourced first (for
#' canonical_active_primary()) -- not self-sourced here, same convention as
#' R/lib/medicare_duckdb.R.
#'
#' Factored out of analyze_medicaid_procedure_billing_ob_midwife.R so the
#' four downstream analyses built on it (high-volume flag, enrollment x
#' spending tier, year trend, state comparison) share ONE definition rather
#' than four hand-copies that would quietly drift. See that script's header
#' for the full rationale (why NOT geocoded, why Generalist+MFM only, the
#' subspecialist-cohort-wins dedup rule).
#'
#' @param include_state [logical] attach each provider's NPPES/ABOG-reported
#'   practice state (two-letter code where available). Needed for the
#'   state-level comparison; skipped by default to keep callers that don't
#'   need it (the per-procedure billing join) from depending on an extra
#'   column being clean.
#' @return [tibble] npi, provider_group, display_name, (state if requested).
#'   Dual-group NPI already excluded; see $dual_group_excluded attribute for
#'   the 4 rows this drops, so no caller silently loses them without a way
#'   to find out why counts are 4 short of a naive sum.
#' @family ob-midwife-medicaid

#' Source-file paths, exported as constants so callers can cite them in
#' write_with_provenance(inputs = ...) without hand-reconstructing a path
#' build_ob_midwife_cohort() already computed internally.
OB_MIDWIFE_COHORT_SOURCES <- local({
  iso <- path.expand("~/isochrones")
  list(
    amcb_linkage = "artifacts/amcb_npi_linkage_FROZEN.csv",
    abog_canonical_csv = file.path(iso, "artifacts/cohort_tracking_archive",
                                    "20261012_182448_90267847/abog_inputs",
                                    "canonical_abog_npi_LATEST.csv"),
    abog_subspecialist_rds = file.path(iso, "artifacts/isochrones/step_2.5_final_cohort.rds")
  )
})

build_ob_midwife_cohort <- function(include_state = FALSE) {
  abog_canonical_csv <- OB_MIDWIFE_COHORT_SOURCES$abog_canonical_csv
  abog_subspecialist_rds <- OB_MIDWIFE_COHORT_SOURCES$abog_subspecialist_rds
  stopifnot(file.exists(abog_canonical_csv), file.exists(abog_subspecialist_rds))

  linkage <- readr::read_csv("artifacts/amcb_npi_linkage_FROZEN.csv", show_col_types = FALSE)
  midwives <- canonical_active_primary(linkage) %>%
    dplyr::transmute(npi = as.character(npi), provider_group = "midwife",
                      display_name = paste(first_name, last_name),
                      state = if (include_state) nppes_state else NA_character_)

  abog_canonical <- readr::read_csv(abog_canonical_csv, show_col_types = FALSE)
  abog_sub <- readRDS(abog_subspecialist_rds) %>% tibble::as_tibble()

  sub_npi_all <- abog_sub %>% dplyr::filter(!is.na(npi)) %>%
    dplyr::mutate(npi = as.character(npi)) %>% dplyr::pull(npi) %>% unique()

  generalists <- abog_canonical %>%
    dplyr::filter(subspecialty == "Generalist", !is.na(npi), npi != "NA") %>%
    dplyr::mutate(npi = as.character(as.numeric(npi))) %>%
    dplyr::distinct(npi, .keep_all = TRUE) %>%
    dplyr::filter(!npi %in% sub_npi_all) %>%
    dplyr::transmute(npi, provider_group = "ob_gyn_generalist", display_name = physician_name,
                      state = if (include_state) state_std else NA_character_)

  mfm <- abog_sub %>%
    dplyr::filter(subspecialty_normalized == "MFM", !is.na(npi)) %>%
    dplyr::mutate(npi = as.character(npi)) %>%
    dplyr::distinct(npi, .keep_all = TRUE) %>%
    dplyr::transmute(npi, provider_group = "ob_gyn_mfm", display_name = physician_name,
                      state = if (include_state) practice_state else NA_character_)

  cohort_raw <- dplyr::bind_rows(midwives, generalists, mfm)
  dupe_npi <- cohort_raw %>% dplyr::count(npi) %>% dplyr::filter(n > 1) %>% dplyr::pull(npi)
  dual_group_excluded <- cohort_raw %>% dplyr::filter(npi %in% dupe_npi) %>% dplyr::arrange(npi)
  cohort <- cohort_raw %>% dplyr::filter(!npi %in% dupe_npi)
  if (!include_state) cohort$state <- NULL
  attr(cohort, "dual_group_excluded") <- dual_group_excluded
  cohort
}
