#!/usr/bin/env Rscript

# =============================================================================
# Deterministic AMCB -> state license -> NPPES -> NPI bridge
#
# Primary identity key:
#
#   normalized_license_number + license_state
#
# License number alone is NEVER treated as nationally unique.
#
# A deterministic key is only as trustworthy as the strings on both sides, so
# two guards bound what it may auto-accept:
#   * a license key that maps to more than one NPI is never accepted; and
#   * a key match whose *legal surname* contradicts the roster is never
#     accepted -- it is quarantined for review (see `link_amcb_by_license`).
#
# Expected files
# --------------
# midwives.csv
#   certification_number
#   first_name
#   middle_name
#   last_name
#
# amcb_license_bridge.csv
#   certification_number
#   license_number
#   license_state
#
# Optional columns in amcb_license_bridge.csv:
#   practice_city
#   practice_state
#   license_first_name
#   license_middle_name
#   license_last_name
#
# NPPES dissemination CSV
#   standard NPPES columns, including:
#     NPI
#     Provider First Name
#     Provider Middle Name
#     Provider Last Name (Legal Name)
#     Provider Business Practice Location Address City Name
#     Provider Business Practice Location Address State Name
#     Healthcare Provider Taxonomy Code_1 ... _15
#     Provider License Number_1 ... _15
#     Provider License Number State Code_1 ... _15
#
# Optional prior linkage artifact:
#   artifacts/amcb_npi_linkage_*.csv
#
# Environment variables
# ---------------------
# AMCB_ROSTER
# AMCB_LICENSE_BRIDGE
# NPPES_FILE
# PRIOR_LINKAGE
# ARTIFACT_DIR
#
# Outputs
# -------
# artifacts/amcb_license_npi_crosswalk_<timestamp>.csv
# artifacts/amcb_license_npi_audit_<timestamp>.csv
# artifacts/amcb_license_key_collisions_<timestamp>.csv
# artifacts/amcb_license_rescued_<timestamp>.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(readr)
  library(scales)
  library(stringr)
  library(tibble)
  library(tidyr)
})

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log_step <- function(...) {
  text <- base::paste0(...)
  base::message(
    base::sprintf(
      "[%s] %s",
      base::format(base::Sys.time(), "%Y-%m-%d %H:%M:%S"),
      text
    )
  )
}

# -----------------------------------------------------------------------------
# Generic character normalization
# -----------------------------------------------------------------------------

blank_to_na <- function(x) {
  cleaned <- x |>
    base::as.character() |>
    stringr::str_squish()

  cleaned[base::is.na(cleaned) | cleaned == ""] <- NA_character_

  cleaned
}

normalize_text <- function(x) {
  cleaned <- blank_to_na(x)

  cleaned <- base::iconv(
    cleaned,
    from = "",
    to = "ASCII//TRANSLIT"
  )

  cleaned <- cleaned |>
    stringr::str_to_upper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish()

  cleaned[cleaned == ""] <- NA_character_

  cleaned
}

normalize_city <- function(x) {
  normalize_text(x)
}

# -----------------------------------------------------------------------------
# State normalization
# -----------------------------------------------------------------------------

normalize_state <- function(x) {
  raw_state <- normalize_text(x)

  # datasets:: qualified because Rscript does not attach the datasets package
  # by default, so a bare state.name is not found in a non-interactive run.
  state_lookup <- tibble::tibble(
    state_name = base::toupper(datasets::state.name),
    state_code = datasets::state.abb
  )

  territories <- tibble::tribble(
    ~state_name, ~state_code,
    "DISTRICT OF COLUMBIA", "DC",
    "PUERTO RICO", "PR",
    "GUAM", "GU",
    "VIRGIN ISLANDS", "VI",
    "AMERICAN SAMOA", "AS",
    "NORTHERN MARIANA ISLANDS", "MP"
  )

  state_lookup <- dplyr::bind_rows(
    state_lookup,
    territories
  )

  mapped <- dplyr::case_when(
    base::is.na(raw_state) ~ NA_character_,
    stringr::str_detect(raw_state, "^[A-Z]{2}$") ~ raw_state,
    TRUE ~ state_lookup$state_code[
      base::match(raw_state, state_lookup$state_name)
    ]
  )

  mapped
}

# -----------------------------------------------------------------------------
# License normalization
#
# Deliberately conservative:
# - keep leading zeros;
# - keep letters;
# - remove spaces, dashes and punctuation;
# - do NOT coerce to numeric;
# - do NOT strip prefixes such as RN/CNM unless the source-specific evidence
#   proves those prefixes are formatting rather than part of the license.
# -----------------------------------------------------------------------------

normalize_license_number <- function(x) {
  cleaned <- blank_to_na(x)

  cleaned <- cleaned |>
    base::iconv(
      from = "",
      to = "ASCII//TRANSLIT"
    ) |>
    stringr::str_to_upper() |>
    stringr::str_replace_all("[^A-Z0-9]", "")

  cleaned[cleaned == ""] <- NA_character_

  cleaned
}

make_license_key <- function(license_number, license_state) {
  number_key <- normalize_license_number(license_number)
  state_key <- normalize_state(license_state)

  dplyr::if_else(
    !base::is.na(number_key) & !base::is.na(state_key),
    base::paste(state_key, number_key, sep = "::"),
    NA_character_
  )
}

# -----------------------------------------------------------------------------
# Name normalization
# -----------------------------------------------------------------------------

normalize_person_name <- function(x) {
  normalize_text(x)
}

first_initial <- function(x) {
  normalized <- normalize_person_name(x)

  dplyr::if_else(
    base::is.na(normalized),
    NA_character_,
    base::substr(normalized, 1L, 1L)
  )
}

middle_initial <- function(x) {
  first_initial(x)
}

# -----------------------------------------------------------------------------
# Input checks
# -----------------------------------------------------------------------------

require_columns <- function(table_input, required, label) {
  missing_columns <- base::setdiff(
    required,
    base::names(table_input)
  )

  if (base::length(missing_columns) > 0L) {
    base::stop(
      base::sprintf(
        "%s is missing required columns: %s",
        label,
        base::paste(missing_columns, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  base::invisible(TRUE)
}

# -----------------------------------------------------------------------------
# AMCB roster
# -----------------------------------------------------------------------------

read_amcb_roster <- function(path) {
  log_step("Reading AMCB roster: ", path)

  roster <- readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE,
    progress = FALSE
  )

  require_columns(
    roster,
    c(
      "certification_number",
      "first_name",
      "middle_name",
      "last_name"
    ),
    "AMCB roster"
  )

  roster <- roster |>
    dplyr::mutate(
      amcb_id = blank_to_na(.data$certification_number),
      amcb_first_name = blank_to_na(.data$first_name),
      amcb_middle_name = blank_to_na(.data$middle_name),
      amcb_last_name = blank_to_na(.data$last_name),
      amcb_first_key = normalize_person_name(
        .data$amcb_first_name
      ),
      amcb_middle_key = normalize_person_name(
        .data$amcb_middle_name
      ),
      amcb_last_key = normalize_person_name(
        .data$amcb_last_name
      ),
      amcb_first_initial = first_initial(
        .data$amcb_first_name
      ),
      amcb_middle_initial = middle_initial(
        .data$amcb_middle_name
      )
    )

  duplicate_ids <- roster |>
    dplyr::filter(!base::is.na(.data$amcb_id)) |>
    dplyr::count(.data$amcb_id, name = "n") |>
    dplyr::filter(.data$n > 1L)

  if (base::nrow(duplicate_ids) > 0L) {
    base::stop(
      base::sprintf(
        "AMCB roster contains %s duplicate certification numbers.",
        scales::comma(base::nrow(duplicate_ids))
      ),
      call. = FALSE
    )
  }

  log_step(
    "AMCB rows loaded: ",
    scales::comma(base::nrow(roster))
  )

  log_step(
    "Rows with a middle name: ",
    scales::comma(
      base::sum(!base::is.na(roster$amcb_middle_key))
    )
  )

  roster
}

# -----------------------------------------------------------------------------
# AMCB -> state-board license bridge
# -----------------------------------------------------------------------------

read_amcb_license_bridge <- function(path) {
  log_step("Reading license bridge: ", path)

  bridge <- readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE,
    progress = FALSE
  )

  require_columns(
    bridge,
    c(
      "certification_number",
      "license_number",
      "license_state"
    ),
    "AMCB license bridge"
  )

  optional_columns <- c(
    "practice_city",
    "practice_state",
    "license_first_name",
    "license_middle_name",
    "license_last_name"
  )

  for (column_name in optional_columns) {
    if (!column_name %in% base::names(bridge)) {
      bridge[[column_name]] <- NA_character_
    }
  }

  bridge <- bridge |>
    dplyr::transmute(
      amcb_id = blank_to_na(.data$certification_number),
      license_number_raw = blank_to_na(.data$license_number),
      license_state_raw = blank_to_na(.data$license_state),
      license_number_key = normalize_license_number(
        .data$license_number
      ),
      license_state_key = normalize_state(
        .data$license_state
      ),
      license_key = make_license_key(
        .data$license_number,
        .data$license_state
      ),
      amcb_practice_city = normalize_city(
        .data$practice_city
      ),
      amcb_practice_state = normalize_state(
        .data$practice_state
      ),
      board_first_key = normalize_person_name(
        .data$license_first_name
      ),
      board_middle_key = normalize_person_name(
        .data$license_middle_name
      ),
      board_last_key = normalize_person_name(
        .data$license_last_name
      )
    ) |>
    dplyr::filter(
      !base::is.na(.data$amcb_id),
      !base::is.na(.data$license_key)
    ) |>
    dplyr::distinct()

  log_step(
    "Valid AMCB-license rows: ",
    scales::comma(base::nrow(bridge))
  )

  log_step(
    "Unique AMCB certificants with license keys: ",
    scales::comma(dplyr::n_distinct(bridge$amcb_id))
  )

  bridge
}

# -----------------------------------------------------------------------------
# NPPES column names
# -----------------------------------------------------------------------------

nppes_license_columns <- function(slots = 15L) {
  license_columns <- base::sprintf(
    "Provider License Number_%s",
    base::seq_len(slots)
  )

  state_columns <- base::sprintf(
    "Provider License Number State Code_%s",
    base::seq_len(slots)
  )

  base::c(
    "NPI",
    "Provider First Name",
    "Provider Middle Name",
    "Provider Last Name (Legal Name)",
    "Provider Business Practice Location Address City Name",
    "Provider Business Practice Location Address State Name",
    license_columns,
    state_columns
  )
}

# -----------------------------------------------------------------------------
# Read only needed NPPES columns.
#
# readr still scans the source file, but selecting only these fields avoids
# materializing the hundreds of irrelevant NPPES columns. For the full ~10 GB
# dissemination file, a DuckDB UNPIVOT over the 15 license slots (as in
# extract_nppes_midwives.R) would be lighter still; this readr path is kept for
# portability and is adequate for the pre-filtered inputs used in testing.
# -----------------------------------------------------------------------------

read_nppes_license_fields <- function(path, slots = 15L) {
  wanted <- nppes_license_columns(slots)

  log_step("Reading NPPES license fields from: ", path)
  log_step(
    "Selecting ",
    base::length(wanted),
    " NPPES columns."
  )

  nppes_wide <- readr::read_csv(
    path,
    col_select = dplyr::any_of(wanted),
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE,
    progress = TRUE,
    name_repair = "minimal"
  )

  require_columns(
    nppes_wide,
    c(
      "NPI",
      "Provider First Name",
      "Provider Last Name (Legal Name)"
    ),
    "NPPES file"
  )

  log_step(
    "NPPES providers loaded: ",
    scales::comma(base::nrow(nppes_wide))
  )

  nppes_wide
}

# -----------------------------------------------------------------------------
# NPPES wide -> one row per NPI/license slot
# -----------------------------------------------------------------------------

pivot_nppes_licenses <- function(nppes_wide, slots = 15L) {
  log_step("Pivoting NPPES license slots to long form.")

  provider_fields <- nppes_wide |>
    dplyr::transmute(
      npi = blank_to_na(.data$NPI),
      nppes_first_name = blank_to_na(.data[["Provider First Name"]]),
      nppes_middle_name = blank_to_na(.data[["Provider Middle Name"]]),
      nppes_last_name = blank_to_na(.data[["Provider Last Name (Legal Name)"]]),
      nppes_city = normalize_city(
        .data[["Provider Business Practice Location Address City Name"]]
      ),
      nppes_state = normalize_state(
        .data[["Provider Business Practice Location Address State Name"]]
      ),
      nppes_first_key = normalize_person_name(.data[["Provider First Name"]]),
      nppes_middle_key = normalize_person_name(.data[["Provider Middle Name"]]),
      nppes_last_key = normalize_person_name(
        .data[["Provider Last Name (Legal Name)"]]
      )
    )

  license_parts <- purrr::map_dfr(
    base::seq_len(slots),
    function(slot_number) {
      number_column <- base::sprintf(
        "Provider License Number_%s",
        slot_number
      )

      state_column <- base::sprintf(
        "Provider License Number State Code_%s",
        slot_number
      )

      if (!number_column %in% base::names(nppes_wide) ||
          !state_column %in% base::names(nppes_wide)) {
        return(tibble::tibble())
      }

      nppes_wide |>
        dplyr::transmute(
          npi = blank_to_na(.data$NPI),
          license_slot = slot_number,
          nppes_license_number_raw = blank_to_na(
            .data[[number_column]]
          ),
          nppes_license_state_raw = blank_to_na(
            .data[[state_column]]
          ),
          license_number_key = normalize_license_number(
            .data[[number_column]]
          ),
          license_state_key = normalize_state(
            .data[[state_column]]
          ),
          license_key = make_license_key(
            .data[[number_column]],
            .data[[state_column]]
          )
        ) |>
        dplyr::filter(
          !base::is.na(.data$npi),
          !base::is.na(.data$license_key)
        )
    }
  )

  license_long <- license_parts |>
    dplyr::left_join(
      provider_fields,
      by = "npi"
    ) |>
    dplyr::distinct(
      .data$npi,
      .data$license_key,
      .keep_all = TRUE
    )

  log_step(
    "NPPES NPI-license combinations: ",
    scales::comma(base::nrow(license_long))
  )

  log_step(
    "Unique NPPES license keys: ",
    scales::comma(
      dplyr::n_distinct(license_long$license_key)
    )
  )

  license_long
}

# -----------------------------------------------------------------------------
# Determine whether a license key maps uniquely to an NPI.
#
# A duplicated key is NEVER auto-accepted.
# -----------------------------------------------------------------------------

classify_nppes_license_keys <- function(license_long) {
  log_step("Classifying NPPES license-key uniqueness.")

  key_counts <- license_long |>
    dplyr::group_by(.data$license_key) |>
    dplyr::summarise(
      n_npi_for_license = dplyr::n_distinct(.data$npi),
      .groups = "drop"
    )

  classified <- license_long |>
    dplyr::left_join(
      key_counts,
      by = "license_key"
    ) |>
    dplyr::mutate(
      license_key_unique = .data$n_npi_for_license == 1L
    )

  collision_count <- key_counts |>
    dplyr::filter(.data$n_npi_for_license > 1L) |>
    base::nrow()

  log_step(
    "License keys mapping to >1 NPI: ",
    scales::comma(collision_count)
  )

  classified
}

# -----------------------------------------------------------------------------
# Exact deterministic join
#
# Acceptance requires ALL of:
#   * the license key resolves to exactly one NPPES NPI;
#   * the certificant's licenses point to exactly one NPI overall; and
#   * the legal surname does not actively conflict (NA -- a name missing on
#     either side -- does not block, but a real disagreement does).
# Everything else is labelled and carried through for review, never accepted.
# -----------------------------------------------------------------------------

link_amcb_by_license <- function(
    roster,
    bridge,
    nppes_licenses
) {
  log_step(
    "Joining AMCB to NPPES on exact license_number + license_state."
  )

  license_candidates <- bridge |>
    dplyr::left_join(
      nppes_licenses,
      by = c(
        "license_key",
        "license_number_key",
        "license_state_key"
      )
    ) |>
    dplyr::left_join(
      roster |>
        dplyr::select(
          "amcb_id",
          "amcb_first_name",
          "amcb_middle_name",
          "amcb_last_name",
          "amcb_first_key",
          "amcb_middle_key",
          "amcb_last_key",
          "amcb_first_initial",
          "amcb_middle_initial"
        ),
      by = "amcb_id"
    ) |>
    dplyr::mutate(
      first_name_agrees = dplyr::case_when(
        base::is.na(.data$nppes_first_key) |
          base::is.na(.data$amcb_first_key) ~ NA,
        TRUE ~ .data$nppes_first_key == .data$amcb_first_key
      ),
      last_name_agrees = dplyr::case_when(
        base::is.na(.data$nppes_last_key) |
          base::is.na(.data$amcb_last_key) ~ NA,
        TRUE ~ .data$nppes_last_key == .data$amcb_last_key
      ),
      middle_name_agrees = dplyr::case_when(
        base::is.na(.data$nppes_middle_key) |
          base::is.na(.data$amcb_middle_key) ~ NA,
        TRUE ~ .data$nppes_middle_key == .data$amcb_middle_key
      ),
      city_agrees = dplyr::case_when(
        base::is.na(.data$amcb_practice_city) |
          base::is.na(.data$nppes_city) ~ NA,
        TRUE ~ .data$amcb_practice_city == .data$nppes_city
      ),
      practice_state_agrees = dplyr::case_when(
        base::is.na(.data$amcb_practice_state) |
          base::is.na(.data$nppes_state) ~ NA,
        TRUE ~ .data$amcb_practice_state == .data$nppes_state
      ),
      # An actual legal-surname disagreement blocks acceptance even when the
      # license key is unique; a missing name (NA) does not block.
      surname_conflicts = !base::is.na(.data$last_name_agrees) &
        !.data$last_name_agrees
    )

  per_amcb <- license_candidates |>
    dplyr::group_by(.data$amcb_id) |>
    dplyr::summarise(
      n_license_keys = dplyr::n_distinct(
        .data$license_key,
        na.rm = TRUE
      ),
      n_candidate_npi = dplyr::n_distinct(
        .data$npi,
        na.rm = TRUE
      ),
      n_surname_conflict_npi = dplyr::n_distinct(
        .data$npi[.data$surname_conflicts],
        na.rm = TRUE
      ),
      candidate_npis = base::paste(
        base::sort(base::unique(
          .data$npi[!base::is.na(.data$npi)]
        )),
        collapse = "|"
      ),
      .groups = "drop"
    )

  license_candidates <- license_candidates |>
    dplyr::left_join(
      per_amcb,
      by = "amcb_id"
    ) |>
    dplyr::mutate(
      deterministic_accept = (
        !base::is.na(.data$npi) &
          .data$n_npi_for_license == 1L &
          .data$n_candidate_npi == 1L &
          !.data$surname_conflicts
      ),
      deterministic_status = dplyr::case_when(
        base::is.na(.data$npi) ~ "license_not_found_in_nppes",
        .data$n_npi_for_license > 1L ~
          "license_key_maps_to_multiple_npis",
        .data$n_candidate_npi > 1L ~
          "amcb_has_conflicting_license_npis",
        .data$surname_conflicts ~
          "license_match_surname_conflict",
        .data$deterministic_accept ~ "license_exact",
        TRUE ~ "unresolved"
      )
    )

  accepted <- license_candidates |>
    dplyr::filter(.data$deterministic_accept) |>
    dplyr::arrange(
      .data$amcb_id,
      .data$license_key,
      .data$npi
    ) |>
    dplyr::group_by(.data$amcb_id) |>
    dplyr::slice(1L) |>
    dplyr::ungroup()

  crosswalk <- roster |>
    dplyr::left_join(
      accepted |>
        dplyr::select(
          "amcb_id",
          deterministic_npi = "npi",
          deterministic_license_key = "license_key",
          deterministic_license_number = "license_number_key",
          deterministic_license_state = "license_state_key",
          "nppes_first_name",
          "nppes_middle_name",
          "nppes_last_name",
          "nppes_city",
          "nppes_state",
          "first_name_agrees",
          "middle_name_agrees",
          "last_name_agrees",
          "city_agrees",
          "practice_state_agrees"
        ),
      by = "amcb_id"
    ) |>
    dplyr::left_join(
      per_amcb,
      by = "amcb_id"
    ) |>
    dplyr::mutate(
      deterministic_status = dplyr::case_when(
        !base::is.na(.data$deterministic_npi) ~
          "license_exact",
        base::is.na(.data$n_candidate_npi) ~
          "no_license_available",
        .data$n_candidate_npi == 0L ~
          "license_not_found_in_nppes",
        .data$n_candidate_npi > 1L ~
          "license_conflict",
        .data$n_surname_conflict_npi >= 1L ~
          "license_match_surname_conflict",
        TRUE ~ "unresolved"
      )
    )

  log_step(
    "Deterministic license matches: ",
    scales::comma(
      base::sum(
        crosswalk$deterministic_status == "license_exact",
        na.rm = TRUE
      )
    )
  )

  log_step(
    "Quarantined on surname conflict: ",
    scales::comma(
      base::sum(
        crosswalk$deterministic_status ==
          "license_match_surname_conflict",
        na.rm = TRUE
      )
    )
  )

  base::list(
    crosswalk = crosswalk,
    candidates = license_candidates
  )
}

# -----------------------------------------------------------------------------
# Prior matcher integration
# -----------------------------------------------------------------------------

read_prior_linkage <- function(path) {
  if (base::is.na(path) || !base::nzchar(path) ||
      !base::file.exists(path)) {
    log_step("No prior linkage artifact supplied.")

    return(NULL)
  }

  log_step("Reading prior linkage artifact: ", path)

  prior <- readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE,
    progress = FALSE
  )

  id_candidates <- c(
    "amcb_id",
    "certification_number"
  )

  id_column <- id_candidates[
    id_candidates %in% base::names(prior)
  ][1L]

  if (base::is.na(id_column)) {
    base::stop(
      "Prior linkage has no AMCB certification identifier.",
      call. = FALSE
    )
  }

  if (id_column != "amcb_id") {
    prior <- prior |>
      dplyr::rename(
        amcb_id = dplyr::all_of(id_column)
      )
  }

  prior
}

# -----------------------------------------------------------------------------
# Identify old linkage status generically.
# -----------------------------------------------------------------------------

derive_prior_status <- function(prior) {
  if (base::is.null(prior)) {
    return(NULL)
  }

  possible_status <- c(
    "linkage_status",
    "match_status",
    "status",
    "match_class",
    "evidence_class"
  )

  status_column <- possible_status[
    possible_status %in% base::names(prior)
  ][1L]

  possible_npi <- c(
    "npi",
    "matched_npi"
  )

  npi_column <- possible_npi[
    possible_npi %in% base::names(prior)
  ][1L]

  # A prior artifact with neither a status nor an NPI column carries no usable
  # linkage signal. Rather than dereference `.data[[NA]]` (a hard error), warn
  # and emit an empty prior tier so the deterministic arm still runs.
  if (base::is.na(status_column) && base::is.na(npi_column)) {
    log_step(
      "Prior linkage has neither a status nor an NPI column; ",
      "the prior tier will be empty."
    )

    prior_status <- prior |>
      dplyr::transmute(
        amcb_id = blank_to_na(.data$amcb_id),
        prior_npi = NA_character_,
        prior_status = NA_character_
      ) |>
      dplyr::distinct(.data$amcb_id, .keep_all = TRUE)

    return(prior_status)
  }

  prior_status <- prior |>
    dplyr::transmute(
      amcb_id = blank_to_na(.data$amcb_id),
      prior_npi = if (!base::is.na(npi_column)) {
        blank_to_na(.data[[npi_column]])
      } else {
        NA_character_
      },
      prior_status = if (!base::is.na(status_column)) {
        blank_to_na(.data[[status_column]])
      } else {
        dplyr::if_else(
          base::is.na(blank_to_na(.data[[npi_column]])),
          "unmatched",
          "matched"
        )
      }
    ) |>
    dplyr::distinct(.data$amcb_id, .keep_all = TRUE)

  prior_status
}

# -----------------------------------------------------------------------------
# Combine deterministic tier with prior tier.
#
# Deterministic license match wins.
# Prior match is retained when no deterministic key resolves the row.
# A disagreement is explicitly quarantined for review rather than silently
# replacing the old NPI OR silently trusting the new one: both NPIs are dropped
# from `linked_npi` and the row is flagged.
# -----------------------------------------------------------------------------

combine_linkage_tiers <- function(
    crosswalk,
    prior_status
) {
  log_step("Combining deterministic and prior linkage tiers.")

  if (base::is.null(prior_status)) {
    combined <- crosswalk |>
      dplyr::mutate(
        prior_npi = NA_character_,
        prior_status = NA_character_
      )
  } else {
    combined <- crosswalk |>
      dplyr::left_join(
        prior_status,
        by = "amcb_id"
      )
  }

  combined <- combined |>
    dplyr::mutate(
      deterministic_disagrees_with_prior = (
        !base::is.na(.data$deterministic_npi) &
          !base::is.na(.data$prior_npi) &
          .data$deterministic_npi != .data$prior_npi
      ),
      linkage_method = dplyr::case_when(
        .data$deterministic_disagrees_with_prior ~
          "license_exact_conflicts_with_prior",
        !base::is.na(.data$deterministic_npi) ~
          "license_exact",
        !base::is.na(.data$prior_npi) ~
          "prior_match",
        TRUE ~
          "unresolved"
      ),
      linked_npi = dplyr::case_when(
        .data$deterministic_disagrees_with_prior ~
          NA_character_,
        !base::is.na(.data$deterministic_npi) ~
          .data$deterministic_npi,
        !base::is.na(.data$prior_npi) ~
          .data$prior_npi,
        TRUE ~
          NA_character_
      ),
      rescued_by_license = (
        !base::is.na(.data$deterministic_npi) &
          base::is.na(.data$prior_npi)
      )
    )

  log_step(
    "Previously unlinked rows rescued by license: ",
    scales::comma(
      base::sum(combined$rescued_by_license, na.rm = TRUE)
    )
  )

  log_step(
    "License/prior NPI conflicts requiring review: ",
    scales::comma(
      base::sum(
        combined$deterministic_disagrees_with_prior,
        na.rm = TRUE
      )
    )
  )

  combined
}

# -----------------------------------------------------------------------------
# Audit table
# -----------------------------------------------------------------------------

build_license_audit <- function(combined) {
  log_step("Building linkage audit.")

  total_n <- base::nrow(combined)

  audit <- combined |>
    dplyr::count(
      .data$linkage_method,
      name = "n"
    ) |>
    dplyr::mutate(
      percent = 100 * .data$n / total_n
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$n)
    )

  audit
}

# -----------------------------------------------------------------------------
# Dynamic summary
# -----------------------------------------------------------------------------

build_summary_sentence <- function(combined) {
  total_n <- base::nrow(combined)

  deterministic_n <- base::sum(
    combined$linkage_method == "license_exact",
    na.rm = TRUE
  )

  rescued_n <- base::sum(
    combined$rescued_by_license,
    na.rm = TRUE
  )

  conflict_n <- base::sum(
    combined$deterministic_disagrees_with_prior,
    na.rm = TRUE
  )

  deterministic_pct <- 100 * deterministic_n / total_n

  base::sprintf(
    paste0(
      "Exact license-number plus license-state linkage resolved ",
      "%s of %s AMCB certificants (%.1f%%), including %s previously ",
      "unlinked certificants; %s license/prior-NPI disagreements ",
      "were quarantined for review."
    ),
    scales::comma(deterministic_n),
    scales::comma(total_n),
    deterministic_pct,
    scales::comma(rescued_n),
    scales::comma(conflict_n)
  )
}

# -----------------------------------------------------------------------------
# Save artifacts
# -----------------------------------------------------------------------------

save_license_artifacts <- function(
    combined,
    candidates,
    audit,
    artifact_dir
) {
  base::dir.create(
    artifact_dir,
    recursive = TRUE,
    showWarnings = FALSE
  )

  timestamp <- base::format(
    base::Sys.time(),
    "%Y%m%d_%H%M%S"
  )

  crosswalk_path <- base::file.path(
    artifact_dir,
    base::sprintf(
      "amcb_license_npi_crosswalk_%s.csv",
      timestamp
    )
  )

  audit_path <- base::file.path(
    artifact_dir,
    base::sprintf(
      "amcb_license_npi_audit_%s.csv",
      timestamp
    )
  )

  collision_path <- base::file.path(
    artifact_dir,
    base::sprintf(
      "amcb_license_key_collisions_%s.csv",
      timestamp
    )
  )

  rescued_path <- base::file.path(
    artifact_dir,
    base::sprintf(
      "amcb_license_rescued_%s.csv",
      timestamp
    )
  )

  summary_path <- base::file.path(
    artifact_dir,
    base::sprintf(
      "amcb_license_summary_%s.txt",
      timestamp
    )
  )

  # Both kinds of "do not auto-accept" land in the collision quarantine: a
  # license key shared across NPIs, a certificant whose licenses point at
  # several NPIs, or a unique key whose legal surname contradicts the roster.
  collisions <- candidates |>
    dplyr::filter(
      .data$n_npi_for_license > 1L |
        .data$n_candidate_npi > 1L |
        .data$surname_conflicts
    ) |>
    dplyr::arrange(
      .data$amcb_id,
      .data$license_key,
      .data$npi
    )

  rescued <- combined |>
    dplyr::filter(.data$rescued_by_license) |>
    dplyr::arrange(.data$amcb_id)

  summary_sentence <- build_summary_sentence(combined)

  readr::write_csv(
    combined,
    crosswalk_path,
    na = ""
  )

  log_step(
    "Saved crosswalk: ",
    base::normalizePath(
      crosswalk_path,
      mustWork = TRUE
    )
  )

  readr::write_csv(
    audit,
    audit_path,
    na = ""
  )

  log_step(
    "Saved audit: ",
    base::normalizePath(
      audit_path,
      mustWork = TRUE
    )
  )

  readr::write_csv(
    collisions,
    collision_path,
    na = ""
  )

  log_step(
    "Saved collision quarantine: ",
    base::normalizePath(
      collision_path,
      mustWork = TRUE
    )
  )

  readr::write_csv(
    rescued,
    rescued_path,
    na = ""
  )

  log_step(
    "Saved rescued rows: ",
    base::normalizePath(
      rescued_path,
      mustWork = TRUE
    )
  )

  base::writeLines(
    summary_sentence,
    summary_path
  )

  log_step(
    "Saved summary: ",
    base::normalizePath(
      summary_path,
      mustWork = TRUE
    )
  )

  base::message("")
  base::message(summary_sentence)

  base::invisible(
    base::list(
      crosswalk_path = crosswalk_path,
      audit_path = audit_path,
      collision_path = collision_path,
      rescued_path = rescued_path,
      summary_path = summary_path
    )
  )
}

# -----------------------------------------------------------------------------
# Full pipeline
# -----------------------------------------------------------------------------

run_amcb_license_bridge <- function(
    amcb_path = base::Sys.getenv(
      "AMCB_ROSTER",
      "midwives.csv"
    ),
    license_bridge_path = base::Sys.getenv(
      "AMCB_LICENSE_BRIDGE",
      "amcb_license_bridge.csv"
    ),
    nppes_path = base::Sys.getenv(
      "NPPES_FILE",
      "npidata_pfile_20050523-20260713.csv"
    ),
    prior_linkage_path = base::Sys.getenv(
      "PRIOR_LINKAGE",
      ""
    ),
    artifact_dir = base::Sys.getenv(
      "ARTIFACT_DIR",
      "artifacts"
    ),
    slots = 15L
) {
  log_step("Starting deterministic AMCB license bridge.")
  log_step("AMCB roster: ", amcb_path)
  log_step("License bridge: ", license_bridge_path)
  log_step("NPPES file: ", nppes_path)
  log_step("Prior linkage: ", prior_linkage_path)
  log_step("Artifact directory: ", artifact_dir)

  for (required_path in c(
    amcb_path,
    license_bridge_path,
    nppes_path
  )) {
    if (!base::file.exists(required_path)) {
      base::stop(
        base::sprintf(
          "Required file does not exist: %s",
          required_path
        ),
        call. = FALSE
      )
    }
  }

  roster <- read_amcb_roster(amcb_path)

  bridge <- read_amcb_license_bridge(
    license_bridge_path
  )

  nppes_wide <- read_nppes_license_fields(
    nppes_path,
    slots = slots
  )

  license_long <- pivot_nppes_licenses(
    nppes_wide,
    slots = slots
  )

  nppes_licenses <- classify_nppes_license_keys(
    license_long
  )

  linked <- link_amcb_by_license(
    roster = roster,
    bridge = bridge,
    nppes_licenses = nppes_licenses
  )

  prior <- read_prior_linkage(
    prior_linkage_path
  )

  prior_status <- derive_prior_status(prior)

  combined <- combine_linkage_tiers(
    crosswalk = linked$crosswalk,
    prior_status = prior_status
  )

  audit <- build_license_audit(combined)

  print(audit)

  saved_paths <- save_license_artifacts(
    combined = combined,
    candidates = linked$candidates,
    audit = audit,
    artifact_dir = artifact_dir
  )

  log_step("Deterministic AMCB license bridge complete.")

  base::invisible(
    base::list(
      crosswalk = combined,
      candidates = linked$candidates,
      audit = audit,
      saved_paths = saved_paths
    )
  )
}

# -----------------------------------------------------------------------------
# Execute
#
# Guarded so the file can be sourced (e.g. by tests/test_amcb_license_bridge.R)
# without triggering a full pipeline run.
# -----------------------------------------------------------------------------

if (base::sys.nframe() == 0L) {
  bridge_run <- run_amcb_license_bridge()
}
