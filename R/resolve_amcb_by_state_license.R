#!/usr/bin/env Rscript
#' Resolve AMCB certificants to NPIs using state license numbers
#'
#' @description
#' A deterministic identity-resolution tier keyed on state license number plus
#' license state. It MUST precede probabilistic name matching: a license key is
#' a real identifier, a name is not.
#'
#' A match is accepted only when the normalized key identifies EXACTLY ONE NPI
#' in NPPES. Duplicate license keys, one-license-to-many-NPI, and AMCB
#' certificants resolving to conflicting NPIs are QUARANTINED -- never broken by
#' fuzzy score, taxonomy preference, geography, or row order. That restraint is
#' the point: an unresolved identity is a known unknown, a wrongly resolved one
#' is a silent error that propagates into every downstream count.
#'
#' @section Leading zeros:
#' `normalize_license_number()` strips leading zeros so "0007" and "7" agree,
#' which is necessary because boards and NPPES disagree on padding. The cost is
#' that a jurisdiction where leading zeros are SIGNIFICANT would see two
#' distinct licences collide -- such a collision surfaces as
#' `quarantined_duplicate_state_board_key` rather than as a false match.
#'
#' @param amcb_path AMCB roster. Must contain a stable certificant identifier.
#' @param state_license_path State-board roster linked to AMCB certificants.
#' @param nppes_path NPPES bulk dissemination CSV or extracted candidate CSV.
#' @param existing_crosswalk_path Optional existing AMCB-NPI crosswalk.
#' @param save_dir Directory for timestamped artifacts.
#' @param max_license_slots Number of NPPES taxonomy/license slots to inspect.
#'
#' @return Named list: deterministic matches, quarantine records, conflicts,
#'   updated crosswalk, audit summary, saved paths.
#' @export
# normalize_npi() and fmt_n() are canonical in R/lib/common_helpers.R. The
# exists() guard keeps this idempotent when the numbered scripts are sourced
# in sequence into one environment, which is how the pipeline runs.
if (!exists("normalize_npi", mode = "function")) {
  source(file.path("R", "lib", "common_helpers.R"))
}
resolve_amcb_by_state_license <- function(
    amcb_path,
    state_license_path,
    nppes_path,
    existing_crosswalk_path = NULL,
    save_dir = "artifacts",
    max_license_slots = 15L) {

  message("resolve_amcb_by_state_license(): starting.")
  message("AMCB input: ", amcb_path)
  message("State-license input: ", state_license_path)
  message("NPPES input: ", nppes_path)
  message("Existing crosswalk: ",
          if (is.null(existing_crosswalk_path)) "<none>" else existing_crosswalk_path)

  assert_file_exists(amcb_path)
  assert_file_exists(state_license_path)
  assert_file_exists(nppes_path)
  if (!is.null(existing_crosswalk_path)) assert_file_exists(existing_crosswalk_path)

  dir.create(save_dir, recursive = TRUE, showWarnings = FALSE)
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  message("Reading AMCB roster.")
  amcb_roster <- readr::read_csv(amcb_path, show_col_types = FALSE,
                                 progress = FALSE)
  message("AMCB rows: ", fmt_n(nrow(amcb_roster)))

  amcb_id_col <- find_column(names(amcb_roster),
                             c("amcb_id", "certification_number",
                               "certification_no", "cert_number", "cert_no",
                               "id"))
  if (is.na(amcb_id_col))
    stop("No stable AMCB certificant identifier was found.", call. = FALSE)
  message("Using AMCB identifier column: ", amcb_id_col)

  amcb_core <- amcb_roster |>
    dplyr::mutate(amcb_id_license = normalize_identifier(.data[[amcb_id_col]]))

  if (anyDuplicated(amcb_core$amcb_id_license) > 0L) {
    duplicate_ids <- amcb_core |>
      dplyr::count(.data$amcb_id_license, name = "n") |>
      dplyr::filter(.data$n > 1L)
    stop("AMCB stable identifier is not unique. Duplicate IDs: ",
         fmt_n(nrow(duplicate_ids)), call. = FALSE)
  }

  message("Reading state-board license roster.")
  state_licenses_raw <- readr::read_csv(state_license_path,
                                        show_col_types = FALSE,
                                        progress = FALSE)
  state_id_col <- find_column(names(state_licenses_raw),
                              c("amcb_id", "certification_number",
                                "certification_no", "cert_number", "cert_no"))
  license_col <- find_column(names(state_licenses_raw),
                             c("license_number", "license_no", "license",
                               "state_license_number"))
  license_state_col <- find_column(names(state_licenses_raw),
                                   c("license_state", "state", "state_code",
                                     "jurisdiction"))
  if (is.na(state_id_col) || is.na(license_col) || is.na(license_state_col))
    stop(paste0("State-license file must contain AMCB identifier, license ",
                "number, and license state."), call. = FALSE)

  message("Normalizing state-board license keys.")
  state_licenses <- state_licenses_raw |>
    dplyr::transmute(
      amcb_id_license = normalize_identifier(.data[[state_id_col]]),
      license_state = normalize_state(.data[[license_state_col]]),
      license_number_raw = as.character(.data[[license_col]]),
      license_number = normalize_license_number(.data[[license_col]])) |>
    dplyr::filter(!is.na(.data$amcb_id_license), !is.na(.data$license_state),
                  !is.na(.data$license_number)) |>
    dplyr::distinct()
  message("Normalized AMCB-license records: ", fmt_n(nrow(state_licenses)))

  message("Checking state-board license-key collisions.")
  duplicated_state_keys <- state_licenses |>
    dplyr::count(.data$license_state, .data$license_number, name = "n_amcb") |>
    dplyr::filter(.data$n_amcb > 1L)

  state_licenses_clean <- state_licenses |>
    dplyr::anti_join(duplicated_state_keys,
                     by = c("license_state", "license_number"))
  state_license_quarantine <- state_licenses |>
    dplyr::semi_join(duplicated_state_keys,
                     by = c("license_state", "license_number")) |>
    dplyr::mutate(license_resolution_status =
                    "quarantined_duplicate_state_board_key")
  message("Unique state-board license keys: ", fmt_n(nrow(state_licenses_clean)))
  message("State-board collisions quarantined: ",
          fmt_n(nrow(state_license_quarantine)))

  message("Reading NPPES license fields.")
  nppes_raw <- readr::read_csv(nppes_path, show_col_types = FALSE,
                               progress = FALSE, name_repair = "minimal")
  message("NPPES rows: ", fmt_n(nrow(nppes_raw)))

  message("Expanding NPPES taxonomy/license slots 1-", max_license_slots, ".")
  nppes_licenses <- extract_nppes_license_slots(nppes_raw, max_license_slots)
  message("Usable NPPES NPI-license records: ", fmt_n(nrow(nppes_licenses)))

  message("Restricting NPPES to requested license keys.")
  relevant_nppes_licenses <- nppes_licenses |>
    dplyr::semi_join(state_licenses_clean,
                     by = c("license_state", "license_number"))
  message("Relevant NPPES license rows: ", fmt_n(nrow(relevant_nppes_licenses)))

  message("Determining whether each license key identifies one NPI.")
  nppes_key_cardinality <- relevant_nppes_licenses |>
    dplyr::group_by(.data$license_state, .data$license_number) |>
    dplyr::summarise(
      n_npi = dplyr::n_distinct(.data$npi),
      # Safe because it is only READ when n_npi == 1, at which point every
      # value in the group is identical and row order cannot matter.
      npi = dplyr::if_else(dplyr::n_distinct(.data$npi) == 1L,
                           dplyr::first(.data$npi), NA_character_),
      taxonomy_codes = paste(sort(unique(stats::na.omit(.data$taxonomy_code))),
                             collapse = ";"),
      .groups = "drop")

  deterministic_candidates <- state_licenses_clean |>
    dplyr::left_join(nppes_key_cardinality,
                     by = c("license_state", "license_number")) |>
    dplyr::mutate(
      n_npi = tidyr::replace_na(.data$n_npi, 0L),
      license_resolution_status = dplyr::case_when(
        .data$n_npi == 1L ~ "resolved_unique_license",
        .data$n_npi == 0L ~ "license_not_found_in_nppes",
        .data$n_npi >  1L ~ "quarantined_license_maps_multiple_npi",
        TRUE ~ "quarantined_unexpected"))

  message("Checking for multiple deterministic NPIs per AMCB certificant.")
  amcb_npi_cardinality <- deterministic_candidates |>
    dplyr::filter(.data$license_resolution_status == "resolved_unique_license") |>
    dplyr::group_by(.data$amcb_id_license) |>
    dplyr::summarise(
      n_deterministic_npi = dplyr::n_distinct(.data$npi),
      deterministic_npi = dplyr::if_else(dplyr::n_distinct(.data$npi) == 1L,
                                         dplyr::first(.data$npi), NA_character_),
      n_license_keys = dplyr::n(),
      license_states = paste(sort(unique(.data$license_state)), collapse = ";"),
      license_numbers = paste(sort(unique(.data$license_number)), collapse = ";"),
      .groups = "drop")

  deterministic_matches <- amcb_npi_cardinality |>
    dplyr::filter(.data$n_deterministic_npi == 1L) |>
    dplyr::transmute(
      amcb_id_license = .data$amcb_id_license,
      npi_license = .data$deterministic_npi,
      linkage_tier_license = "deterministic_state_license",
      deterministic_key_type = "state_license_number",
      deterministic_key_states = .data$license_states,
      deterministic_key_count = .data$n_license_keys)

  conflicting_amcb_matches <- amcb_npi_cardinality |>
    dplyr::filter(.data$n_deterministic_npi > 1L) |>
    dplyr::mutate(license_resolution_status = "quarantined_amcb_maps_multiple_npi")

  message("Deterministic AMCB-NPI matches: ", fmt_n(nrow(deterministic_matches)))
  message("AMCB records with conflicting deterministic NPIs: ",
          fmt_n(nrow(conflicting_amcb_matches)))

  message("Joining deterministic matches to AMCB roster.")
  # An `npi` column already on the roster would be silently overwritten below.
  # Preserve it under a distinct name so nothing is lost without trace.
  if ("npi" %in% names(amcb_core) && !"npi_roster_original" %in% names(amcb_core)) {
    amcb_core$npi_roster_original <- amcb_core$npi
    message("Roster already carried `npi`; preserved as npi_roster_original.")
  }
  amcb_with_license_match <- amcb_core |>
    dplyr::left_join(deterministic_matches, by = "amcb_id_license")

  crosswalk_conflicts <- tibble::tibble()

  if (!is.null(existing_crosswalk_path)) {
    message("Comparing against existing name-based crosswalk.")
    existing_crosswalk <- readr::read_csv(existing_crosswalk_path,
                                          show_col_types = FALSE,
                                          progress = FALSE)
    existing_id_col <- find_column(names(existing_crosswalk),
                                   c("amcb_id", "certification_number",
                                     "certification_no", "cert_number",
                                     "cert_no", amcb_id_col))
    existing_npi_col <- find_column(names(existing_crosswalk),
                                    c("npi", "matched_npi"))
    if (is.na(existing_id_col) || is.na(existing_npi_col))
      stop(paste0("Existing crosswalk does not contain recognizable AMCB-ID ",
                  "and NPI columns."), call. = FALSE)

    # linkage_tier is OPTIONAL. Referencing .data$linkage_tier inside if_else()
    # errors when the column is absent, regardless of how the condition
    # evaluates -- if_else() does not short-circuit. Create it first.
    if (!"linkage_tier" %in% names(existing_crosswalk))
      existing_crosswalk$linkage_tier <- NA_character_

    existing_identity <- existing_crosswalk |>
      dplyr::transmute(
        amcb_id_license = normalize_identifier(.data[[existing_id_col]]),
        npi_existing = normalize_npi(.data[[existing_npi_col]]),
        linkage_tier_existing = as.character(.data$linkage_tier)) |>
      dplyr::distinct(.data$amcb_id_license, .keep_all = TRUE)

    comparison <- amcb_with_license_match |>
      dplyr::left_join(existing_identity, by = "amcb_id_license") |>
      dplyr::mutate(deterministic_vs_existing = dplyr::case_when(
        is.na(.data$npi_license) ~ "no_deterministic_match",
        is.na(.data$npi_existing) ~ "new_deterministic_match",
        .data$npi_license == .data$npi_existing ~ "deterministic_confirms_existing",
        TRUE ~ "deterministic_conflicts_existing"))

    crosswalk_conflicts <- comparison |>
      dplyr::filter(.data$deterministic_vs_existing ==
                      "deterministic_conflicts_existing")
    message("Existing name matches contradicted by license key: ",
            fmt_n(nrow(crosswalk_conflicts)))

    message("Building deterministic-first combined crosswalk.")
    updated_crosswalk <- comparison |>
      dplyr::mutate(
        npi = dplyr::coalesce(.data$npi_license, .data$npi_existing),
        linkage_tier = dplyr::if_else(!is.na(.data$npi_license),
                                      "deterministic_state_license",
                                      .data$linkage_tier_existing),
        identity_resolution_source = dplyr::case_when(
          !is.na(.data$npi_license) ~ "state_license_to_nppes",
          !is.na(.data$npi_existing) ~ "existing_name_matcher",
          TRUE ~ "unresolved"),
        existing_match_overridden =
          .data$deterministic_vs_existing == "deterministic_conflicts_existing")
  } else {
    updated_crosswalk <- amcb_with_license_match |>
      dplyr::mutate(
        npi = .data$npi_license,
        linkage_tier = .data$linkage_tier_license,
        identity_resolution_source = dplyr::if_else(!is.na(.data$npi_license),
                                                    "state_license_to_nppes",
                                                    "unresolved"),
        existing_match_overridden = FALSE)
  }

  message("Constructing unresolved-license audit.")
  unresolved_license_records <- deterministic_candidates |>
    dplyr::filter(.data$license_resolution_status != "resolved_unique_license")

  quarantine_records <- dplyr::bind_rows(
    state_license_quarantine |> dplyr::mutate(npi = NA_character_),
    unresolved_license_records,
    conflicting_amcb_matches |>
      dplyr::transmute(amcb_id_license = .data$amcb_id_license,
                       license_state = .data$license_states,
                       license_number = .data$license_numbers,
                       npi = NA_character_,
                       license_resolution_status = .data$license_resolution_status))

  audit_summary <- build_license_resolution_summary(
    amcb_roster = amcb_core, state_licenses = state_licenses,
    deterministic_matches = deterministic_matches,
    quarantine_records = quarantine_records,
    crosswalk_conflicts = crosswalk_conflicts,
    updated_crosswalk = updated_crosswalk)

  p <- function(stem) file.path(save_dir,
                                sprintf("%s_%s.csv", stem, timestamp))
  deterministic_path <- p("amcb_deterministic_license_matches")
  quarantine_path    <- p("amcb_license_quarantine")
  crosswalk_path     <- p("amcb_npi_crosswalk_license_first")
  conflict_path      <- p("amcb_license_vs_existing_conflicts")
  audit_path         <- p("amcb_license_resolution_summary")

  message("Saving deterministic matches: ", deterministic_path)
  readr::write_csv(deterministic_matches, deterministic_path)
  message("Saving license quarantine: ", quarantine_path)
  readr::write_csv(quarantine_records, quarantine_path)
  message("Saving deterministic-first crosswalk: ", crosswalk_path)
  readr::write_csv(updated_crosswalk, crosswalk_path)
  message("Saving deterministic conflicts: ", conflict_path)
  readr::write_csv(crosswalk_conflicts, conflict_path)
  message("Saving audit summary: ", audit_path)
  readr::write_csv(audit_summary, audit_path)

  resolved_n <- nrow(deterministic_matches)
  roster_n <- nrow(amcb_core)
  message(sprintf(paste0("License-key resolution identified %s of %s AMCB ",
                         "certificants (%.1f%%) deterministically."),
                  fmt_n(resolved_n), fmt_n(roster_n),
                  100 * resolved_n / roster_n))
  if (nrow(crosswalk_conflicts) > 0L)
    message(fmt_n(nrow(crosswalk_conflicts)),
            paste0(" existing name-based assignments disagree with a ",
                   "deterministic license key and require review."))

  message("resolve_amcb_by_state_license(): complete.")
  list(deterministic_matches = deterministic_matches,
       quarantine_records = quarantine_records,
       crosswalk_conflicts = crosswalk_conflicts,
       updated_crosswalk = updated_crosswalk,
       audit_summary = audit_summary,
       saved_paths = c(deterministic = deterministic_path,
                       quarantine = quarantine_path,
                       crosswalk = crosswalk_path,
                       conflicts = conflict_path,
                       audit = audit_path))
}

#' Extract state-license keys from NPPES taxonomy slots
#' @param nppes_records NPPES records. @param max_slots Maximum taxonomy slots.
#' @return [tbl_df] one row per unique NPI-license-state-taxonomy combination.
#' @keywords internal
extract_nppes_license_slots <- function(nppes_records, max_slots = 15L) {
  npi_col <- find_column(names(nppes_records), c("NPI", "npi"))
  if (is.na(npi_col)) stop("NPPES input does not contain NPI.", call. = FALSE)

  slots <- lapply(seq_len(max_slots), function(slot) {
    license_col <- find_column(names(nppes_records),
                               c(paste0("Provider License Number_", slot),
                                 paste0("provider_license_number_", slot)))
    state_col <- find_column(names(nppes_records),
                             c(paste0("Provider License Number State Code_", slot),
                               paste0("provider_license_number_state_code_", slot)))
    taxonomy_col <- find_column(names(nppes_records),
                                c(paste0("Healthcare Provider Taxonomy Code_", slot),
                                  paste0("healthcare_provider_taxonomy_code_", slot)))
    if (is.na(license_col) || is.na(state_col)) return(NULL)

    taxonomy_value <- if (is.na(taxonomy_col)) {
      rep(NA_character_, nrow(nppes_records))
    } else {
      as.character(nppes_records[[taxonomy_col]])
    }
    tibble::tibble(
      npi = normalize_npi(nppes_records[[npi_col]]),
      license_state = normalize_state(nppes_records[[state_col]]),
      license_number = normalize_license_number(nppes_records[[license_col]]),
      taxonomy_code = taxonomy_value,
      taxonomy_slot = slot)
  })

  dplyr::bind_rows(slots) |>
    dplyr::filter(!is.na(.data$npi), !is.na(.data$license_state),
                  !is.na(.data$license_number)) |>
    dplyr::distinct()
}

#' Build the license-resolution audit summary
#' @param amcb_roster AMCB roster. @param state_licenses Normalized licenses.
#' @param deterministic_matches Accepted matches.
#' @param quarantine_records Quarantined records.
#' @param crosswalk_conflicts Conflicts with the existing crosswalk.
#' @param updated_crosswalk Combined crosswalk.
#' @return [tbl_df]
#' @keywords internal
build_license_resolution_summary <- function(amcb_roster, state_licenses,
                                             deterministic_matches,
                                             quarantine_records,
                                             crosswalk_conflicts,
                                             updated_crosswalk) {
  roster_n <- nrow(amcb_roster)
  license_person_n <- nrow(dplyr::distinct(state_licenses, .data$amcb_id_license))
  deterministic_n <- nrow(dplyr::distinct(deterministic_matches,
                                          .data$amcb_id_license))
  resolved_total_n <- updated_crosswalk |>
    dplyr::filter(!is.na(.data$npi)) |>
    dplyr::distinct(.data$amcb_id_license) |> nrow()

  n <- c(roster_n, license_person_n, deterministic_n,
         nrow(quarantine_records), nrow(crosswalk_conflicts), resolved_total_n)
  tibble::tibble(
    metric = c("amcb_roster", "amcb_with_state_license",
               "deterministically_resolved", "license_quarantine_rows",
               "existing_matches_contradicted", "resolved_after_license_first"),
    n = n,
    pct_of_amcb = 100 * n / roster_n)
}

#' Normalize a state license number
#' @param x License number.
#' @return [character] normalized, NA when unusable.
#' @keywords internal
normalize_license_number <- function(x) {
  normalized <- toupper(trimws(as.character(x)))
  normalized <- stringr::str_replace_all(normalized, "[^A-Z0-9]", "")
  # Strip leading zeros only when the remainder is entirely digits, so "A007"
  # is left alone while "0007" and "7" agree.
  normalized <- stringr::str_remove(normalized, "^0+(?=[0-9]+$)")
  normalized[is.na(normalized) | normalized == "" |
               normalized %in% c("NA", "NONE", "NULL", "UNKNOWN")] <-
    NA_character_
  normalized
}

#' Normalize a state to a two-character abbreviation
#' @param x State name or abbreviation.
#' @return [character] two-letter abbreviation, NA when unrecognised.
#' @keywords internal
normalize_state <- function(x) {
  # state.name/state.abb live in `datasets`, NOT `base`. Calling
  # base::state.name errors with "object 'state.name' not found", which would
  # have made every call to this function fail.
  state_text <- toupper(trimws(as.character(x)))
  full_names <- toupper(c(datasets::state.name, "DISTRICT OF COLUMBIA"))
  abbreviations <- c(datasets::state.abb, "DC")
  state_lookup <- stats::setNames(abbreviations, full_names)

  full_name_match <- !is.na(state_text) & state_text %in% names(state_lookup)
  state_text[full_name_match] <- state_lookup[state_text[full_name_match]]
  state_text[is.na(state_text) | !state_text %in% abbreviations] <- NA_character_
  state_text
}

#' Normalize an AMCB stable identifier
#' @param x Identifier.
#' @return [character]
#' @keywords internal
normalize_identifier <- function(x) {
  normalized <- toupper(trimws(as.character(x)))
  normalized[is.na(normalized) | normalized == ""] <- NA_character_
  normalized
}

#' Normalize an NPI to ten digits
#' @param x NPI.
#' @return [character] ten digits, NA otherwise.
#' @keywords internal
# normalize_npi() is canonical in R/lib/common_helpers.R, sourced above.

#' Find the first available column from a candidate list
#' @param available Existing column names. @param candidates Candidate names.
#' @return [character(1)] or NA_character_.
#' @keywords internal
find_column <- function(available, candidates) {
  matched <- candidates[candidates %in% available]
  if (length(matched) == 0L) NA_character_ else matched[[1L]]
}

#' Verify an input file exists
#' @param path File path.
#' @return invisible TRUE, or an error.
#' @keywords internal
assert_file_exists <- function(path) {
  if (!file.exists(path))
    stop("Input file does not exist: ", path, call. = FALSE)
  invisible(TRUE)
}

#' Thousands-separated count without a scales dependency
#' @param x [numeric]
#' @return [character]
#' @keywords internal
# fmt_n() is canonical in R/lib/common_helpers.R, sourced above.
