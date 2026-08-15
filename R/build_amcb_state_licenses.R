#!/usr/bin/env Rscript
#
# Build the external identifier bridge:
#
#   AMCB certificant -> state license number -> (downstream) NPPES
#
# Expected inputs:
#   data/amcb_roster.csv
#   data/raw/state_boards/{CO.csv, MA.xlsx, CA.csv, ...}
#
# State-board files need not share column names; the reader searches common
# variants for name parts, license number, state, status and type.
#
# ACCEPTANCE IS DELIBERATELY CONSERVATIVE, in descending evidence strength:
#   1. exact first + middle + last + state, unique candidate
#   2. exact first + last + state, unique candidate
#   3. exact first + last nationally, unique candidate   (see the warning below)
#
# Fuzzy matches are NEVER automatically accepted; they go to the review
# artifact. Once a license number enters the canonical bridge, downstream code
# treats it as IDENTITY EVIDENCE, so a Smith/Jones false positive is far worse
# than leaving that certificant unresolved.
#
# TIER 3 IS THE RISKY ONE, and its risk runs backwards from intuition.
# "Nationally unique" is unique WITHIN THE BOARD FILES ACTUALLY LOADED, not
# within the United States. Loading three states makes "JANE SMITH" more likely
# to look unique, not less -- so tier 3 becomes MORE permissive as coverage gets
# WORSE, and it accepts a match whose state contradicts the certificant's own.
# It is therefore reported separately, and `allow_national_tier` exists so it
# can be switched off without editing code.
#
# Required packages: dplyr, purrr, readr, readxl, stringr, tibble, tools

#' Log a timestamped message.
#' @param ... Objects passed to paste0().
#' @return Invisibly NULL.
log_message <- function(...) {
  message(sprintf("[%s] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                  paste0(...)))
  invisible(NULL)
}

#' Normalize a person-name component.
#' @param value Character vector.
#' @return [character] normalized, NA when empty.
normalize_name <- function(value) {
  normalized <- value |>
    as.character() |>
    stringr::str_to_upper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish()
  normalized[is.na(normalized) | normalized == ""] <- NA_character_
  normalized
}

#' Normalize a license number.
#' @param value Character vector.
#' @return [character] normalized, NA when unusable.
normalize_license <- function(value) {
  normalized <- value |>
    as.character() |>
    stringr::str_to_upper() |>
    stringr::str_replace_all("[^A-Z0-9]", "")
  normalized[is.na(normalized) | normalized == ""] <- NA_character_
  normalized
}

#' Normalize a US state to a two-letter abbreviation.
#' @param value Character vector.
#' @return [character] abbreviation, NA when unrecognised.
# NOT the same function as normalize_state() in R/resolve_amcb_by_state_license.R.
# This one str_squish()es and accepts "WASHINGTON DC" / "WASHINGTON D C"; that one
# uses trimws() and exact matching. Both behaviours are wanted where they are, so
# they carry distinct names rather than being merged -- merging would loosen
# license-key construction, which is a linkage change, not a cleanup.
normalize_state_lenient <- function(value) {
  # state.name / state.abb live in `datasets`, NOT `base`. base::state.name
  # errors with "object 'state.name' not found", which would make every call
  # here fail before a single key could be built.
  raw_state <- value |>
    as.character() |>
    stringr::str_to_upper() |>
    stringr::str_squish()

  state_lookup <- tibble::tibble(state_name = toupper(datasets::state.name),
                                 state_code = datasets::state.abb) |>
    dplyr::bind_rows(tibble::tibble(
      state_name = c("DISTRICT OF COLUMBIA", "WASHINGTON DC", "WASHINGTON D C"),
      state_code = "DC"))

  abbreviations <- c(datasets::state.abb, "DC")
  out <- ifelse(!is.na(raw_state) & raw_state %in% abbreviations,
                raw_state,
                state_lookup$state_code[match(raw_state,
                                              state_lookup$state_name)])
  out[!is.na(out) & !out %in% abbreviations] <- NA_character_
  out
}

#' Find the first matching column name, in candidate priority order.
#' @param names_available Source column names. @param candidates Candidates.
#' @return [character(1)] or NA_character_.
# Case-INSENSITIVE. R/resolve_amcb_by_state_license.R has a case-SENSITIVE
# find_column(); same reasoning as above, so the names differ.
find_column_ci <- function(names_available, candidates) {
  match_position <- match(stringr::str_to_lower(candidates),
                          stringr::str_to_lower(names_available))
  match_position <- match_position[!is.na(match_position)]
  if (length(match_position) == 0L) return(NA_character_)
  names_available[match_position[[1L]]]
}

#' Pull a source column safely, or a default vector when absent.
#' @param source_tbl Input tibble. @param candidates Candidate names.
#' @param default Value used when no column matches.
#' @return Vector of length nrow(source_tbl).
pull_candidate_column <- function(source_tbl, candidates,
                                  default = NA_character_) {
  source_name <- find_column_ci(names(source_tbl), candidates)
  if (is.na(source_name)) return(rep(default, nrow(source_tbl)))
  source_tbl[[source_name]]
}

#' Read a state-board roster from CSV/TSV/XLSX/XLS/RDS.
#' @param path File path.
#' @return [tbl_df]
read_board_file <- function(path) {
  extension <- stringr::str_to_lower(tools::file_ext(path))
  log_message("Reading state-board file: ", path)
  roster_tbl <- switch(
    extension,
    csv  = readr::read_csv(path, show_col_types = FALSE, progress = FALSE),
    tsv  = readr::read_tsv(path, show_col_types = FALSE, progress = FALSE),
    xlsx = readxl::read_excel(path),
    xls  = readxl::read_excel(path),
    rds  = readRDS(path),
    stop("Unsupported state-board file type: ", extension, call. = FALSE))
  tibble::as_tibble(roster_tbl)
}

#' Standardize one state-board roster.
#' @param path Source roster path.
#' @return [tbl_df] standardized licensee rows.
standardize_board_roster <- function(path) {
  source_tbl <- read_board_file(path)

  # The filename is only a FALLBACK for the license state, and a weak one:
  # "colorado.csv" would yield "DO" from its last two letters. It is used only
  # when the file carries no state column, and it is validated through
  # normalize_state_lenient(), so an unrecognisable value becomes NA rather than a
  # plausible-looking wrong state.
  file_state <- normalize_state_lenient(
    stringr::str_to_upper(stringr::str_extract(
      tools::file_path_sans_ext(basename(path)), "[A-Za-z]{2}$")))

  g <- function(cands, default = NA_character_)
    pull_candidate_column(source_tbl, cands, default)

  standardized_tbl <- tibble::tibble(
    board_source_file = basename(path),
    board_source_row = seq_len(nrow(source_tbl)),
    first_name_raw = as.character(g(c("first_name","firstname","first",
                                      "given_name","givenname",
                                      "licensee_first_name"))),
    middle_name_raw = as.character(g(c("middle_name","middlename","middle",
                                       "middle_initial","mi",
                                       "licensee_middle_name"))),
    last_name_raw = as.character(g(c("last_name","lastname","last","surname",
                                     "family_name","familyname",
                                     "licensee_last_name"))),
    license_number_raw = as.character(g(c("license_number","license_no",
                                          "license_num","licensenumber",
                                          "licenseno","license",
                                          "credential_number","credential_no",
                                          "credential"))),
    license_state_raw = as.character(g(c("license_state","state","state_code",
                                         "jurisdiction","license_jurisdiction"),
                                       default = file_state)),
    license_status = as.character(g(c("license_status","status",
                                      "credential_status","lic_status"))),
    license_type = as.character(g(c("license_type","credential_type",
                                    "profession","profession_name",
                                    "license_category")))) |>
    dplyr::mutate(
      first_norm = normalize_name(.data$first_name_raw),
      middle_norm = normalize_name(.data$middle_name_raw),
      last_norm = normalize_name(.data$last_name_raw),
      middle_initial = stringr::str_sub(.data$middle_norm, 1L, 1L),
      license_number = normalize_license(.data$license_number_raw),
      license_state = normalize_state_lenient(.data$license_state_raw)) |>
    dplyr::filter(!is.na(.data$license_number), !is.na(.data$license_state),
                  !is.na(.data$first_norm), !is.na(.data$last_norm))

  # Two DIFFERENT people sharing one (state, license) inside a single file is a
  # data problem, not something to resolve by keeping whichever row came first.
  collisions <- standardized_tbl |>
    dplyr::group_by(.data$license_state, .data$license_number) |>
    dplyr::filter(dplyr::n_distinct(paste(.data$first_norm,
                                          .data$last_norm)) > 1L) |>
    dplyr::ungroup()
  if (nrow(collisions) > 0L)
    log_message("  WARNING: ", nrow(collisions), " row(s) in ", basename(path),
                " share a (state, license) key across different names; ",
                "dropping all of them rather than picking one.")

  standardized_tbl <- standardized_tbl |>
    dplyr::anti_join(collisions |>
                       dplyr::distinct(.data$license_state,
                                       .data$license_number),
                     by = c("license_state", "license_number")) |>
    dplyr::distinct(.data$license_state, .data$license_number,
                    .keep_all = TRUE)

  log_message("Standardized ", format(nrow(standardized_tbl), big.mark = ","),
              " usable license records from ", basename(path))
  standardized_tbl
}

#' Read and combine every state-board roster in a directory.
#' @param board_dir Directory containing roster files.
#' @return [tbl_df] combined standardized license universe.
read_all_board_rosters <- function(board_dir) {
  log_message("Searching for state-board rosters in: ", board_dir)
  board_files <- list.files(board_dir, pattern = "\\.(csv|tsv|xlsx|xls|rds)$",
                            full.names = TRUE, ignore.case = TRUE)
  if (length(board_files) == 0L)
    stop("No state-board roster files found in ", board_dir, call. = FALSE)
  log_message("Found ", format(length(board_files), big.mark = ","),
              " roster files.")

  license_tbl <- dplyr::bind_rows(lapply(board_files, standardize_board_roster))
  states_loaded <- sort(unique(license_tbl$license_state))
  log_message("Combined license universe contains ",
              format(nrow(license_tbl), big.mark = ","), " rows and ",
              length(states_loaded), " states/jurisdictions: ",
              paste(states_loaded, collapse = ", "))
  attr(license_tbl, "states_loaded") <- states_loaded
  license_tbl
}

#' Standardize the AMCB cohort for linkage.
#' @param amcb_path Path to the AMCB roster CSV.
#' @return [tbl_df]
read_amcb_roster <- function(amcb_path) {
  log_message("Reading AMCB cohort: ", amcb_path)
  source_tbl <- readr::read_csv(amcb_path, show_col_types = FALSE,
                                progress = FALSE)
  g <- function(cands) pull_candidate_column(source_tbl, cands)

  amcb_id <- as.character(g(c("amcb_id","certificant_id","certification_id",
                              "certification_number","certificate_number","id")))
  missing_amcb_id <- is.na(amcb_id) | trimws(amcb_id) == ""
  if (any(missing_amcb_id)) {
    # A synthesized row identifier is NOT a certificant identifier. It cannot
    # be joined to anything outside this file, so it is named to make that
    # obvious rather than passing as a real ID.
    log_message("  WARNING: ", sum(missing_amcb_id),
                " AMCB rows carry no stable identifier; assigning synthetic ",
                "row IDs that are NOT joinable to any external source.")
    amcb_id[missing_amcb_id] <- sprintf("SYNTHETIC_ROW_%07d",
                                        which(missing_amcb_id))
  }

  cohort_tbl <- tibble::tibble(
    amcb_source_row = seq_len(nrow(source_tbl)),
    amcb_id = amcb_id,
    amcb_first_name = as.character(g(c("first_name","firstname","first",
                                       "given_name"))),
    amcb_middle_name = as.character(g(c("middle_name","middlename","middle",
                                        "middle_initial","mi"))),
    amcb_last_name = as.character(g(c("last_name","lastname","last","surname",
                                      "family_name"))),
    amcb_state_raw = as.character(g(c("state","practice_state","address_state",
                                      "mailing_state","license_state")))) |>
    dplyr::mutate(
      first_norm = normalize_name(.data$amcb_first_name),
      middle_norm = normalize_name(.data$amcb_middle_name),
      last_norm = normalize_name(.data$amcb_last_name),
      middle_initial = stringr::str_sub(.data$middle_norm, 1L, 1L),
      amcb_state = normalize_state_lenient(.data$amcb_state_raw))

  if (anyDuplicated(cohort_tbl$amcb_id) > 0L)
    stop("AMCB identifier is not unique; resolve identity before linkage.",
         call. = FALSE)

  log_message("Loaded ", format(nrow(cohort_tbl), big.mark = ","),
              " AMCB certificants.")
  cohort_tbl
}

#' Count candidate board rows per certificant within a tier.
#' @param candidate_tbl Candidate matches.
#' @return [tbl_df] with candidate_n.
count_candidates <- function(candidate_tbl) {
  candidate_tbl |>
    dplyr::group_by(.data$amcb_id) |>
    dplyr::mutate(candidate_n = dplyr::n()) |>
    dplyr::ungroup()
}

# All three matchers keep the BOARD's license_state under its own name. The
# board is the authority on where a licence lives; the certificant's own state
# is not. Renaming the board column away (or coalescing the two) silently
# emitted the AMCB state for national-tier matches -- writing "CO:99" for a
# licence that exists only in TX, which would then either miss NPPES entirely
# or resolve to a DIFFERENT Colorado licensee.
.join_board <- function(cohort_tbl, license_tbl, by, tier) {
  cohort_tbl |>
    dplyr::inner_join(license_tbl, by = by, relationship = "many-to-many",
                      suffix = c("_amcb", "_board")) |>
    dplyr::mutate(match_tier = tier) |>
    count_candidates()
}

#' Exact first + middle + last + state.
#' @param cohort_tbl Cohort. @param license_tbl License universe.
#' @return [tbl_df] candidates.
match_exact_middle_state <- function(cohort_tbl, license_tbl) {
  log_message("Running exact first + middle + last + state linkage.")
  cohort_tbl |>
    dplyr::filter(!is.na(.data$first_norm), !is.na(.data$middle_norm),
                  !is.na(.data$last_norm), !is.na(.data$amcb_state)) |>
    dplyr::rename(license_state = "amcb_state") |>
    .join_board(license_tbl,
                by = c("first_norm", "middle_norm", "last_norm",
                       "license_state"),
                tier = "exact_first_middle_last_state") |>
    dplyr::mutate(amcb_state = .data$license_state)
}

#' Exact first + last + state.
#' @param cohort_tbl Cohort. @param license_tbl License universe.
#' @return [tbl_df] candidates.
match_exact_state <- function(cohort_tbl, license_tbl) {
  log_message("Running exact first + last + state linkage.")
  cohort_tbl |>
    dplyr::filter(!is.na(.data$first_norm), !is.na(.data$last_norm),
                  !is.na(.data$amcb_state)) |>
    dplyr::rename(license_state = "amcb_state") |>
    .join_board(license_tbl,
                by = c("first_norm", "last_norm", "license_state"),
                tier = "exact_first_last_state") |>
    dplyr::mutate(amcb_state = .data$license_state)
}

#' Nationally unique exact first + last.
#' @param cohort_tbl Cohort. @param license_tbl License universe.
#' @return [tbl_df] candidates. license_state is the BOARD's, and may differ
#'   from the certificant's own state -- which is recorded, not hidden.
match_exact_national <- function(cohort_tbl, license_tbl) {
  log_message("Running nationally unique exact first + last linkage.")
  cohort_tbl |>
    dplyr::filter(!is.na(.data$first_norm), !is.na(.data$last_norm)) |>
    .join_board(license_tbl, by = c("first_norm", "last_norm"),
                tier = "exact_first_last_national") |>
    dplyr::mutate(state_agrees = !is.na(.data$amcb_state) &
                    .data$amcb_state == .data$license_state)
}

#' Resolve certificants to licences, hierarchically by evidence strength.
#' @param cohort_tbl Cohort. @param license_tbl License universe.
#' @param allow_national_tier Enable tier 3.
#' @return list(accepted, unresolved, ambiguous)
resolve_amcb_licenses <- function(cohort_tbl, license_tbl,
                                  allow_national_tier = FALSE) {
  log_message("Beginning hierarchical AMCB-to-license resolution.")

  tier_1_tbl <- match_exact_middle_state(cohort_tbl, license_tbl)
  accepted_1_tbl <- dplyr::filter(tier_1_tbl, .data$candidate_n == 1L)
  log_message("Tier 1 accepted ", format(nrow(accepted_1_tbl), big.mark = ","),
              " unique matches.")

  remaining_1_tbl <- dplyr::anti_join(
    cohort_tbl, dplyr::distinct(accepted_1_tbl, .data$amcb_id), by = "amcb_id")

  tier_2_tbl <- match_exact_state(remaining_1_tbl, license_tbl)
  accepted_2_tbl <- dplyr::filter(tier_2_tbl, .data$candidate_n == 1L)
  log_message("Tier 2 accepted ", format(nrow(accepted_2_tbl), big.mark = ","),
              " unique matches.")

  remaining_2_tbl <- dplyr::anti_join(
    remaining_1_tbl, dplyr::distinct(accepted_2_tbl, .data$amcb_id),
    by = "amcb_id")

  if (allow_national_tier) {
    tier_3_tbl <- match_exact_national(remaining_2_tbl, license_tbl)
    accepted_3_tbl <- dplyr::filter(tier_3_tbl, .data$candidate_n == 1L)
    n_cross <- sum(!accepted_3_tbl$state_agrees, na.rm = TRUE)
    log_message("Tier 3 accepted ", format(nrow(accepted_3_tbl),
                                           big.mark = ","),
                " unique matches, of which ", n_cross,
                " sit in a state DIFFERENT from the certificant's own.")
    if (n_cross > 0L)
      log_message("  WARNING: tier-3 uniqueness is relative to the board ",
                  "files loaded, not to the nation. Partial coverage makes ",
                  "this tier MORE permissive, not less.")
  } else {
    log_message("Tier 3 (national) disabled by allow_national_tier = FALSE.")
    tier_3_tbl <- tibble::tibble()
    accepted_3_tbl <- tibble::tibble()
  }

  accepted_tbl <- dplyr::bind_rows(accepted_1_tbl, accepted_2_tbl,
                                   accepted_3_tbl) |>
    dplyr::arrange(.data$amcb_source_row)

  unresolved_tbl <- dplyr::anti_join(
    cohort_tbl, dplyr::distinct(accepted_tbl, .data$amcb_id), by = "amcb_id")

  # A disabled tier yields a zero-column tibble; filtering it on a column that
  # does not exist errors, so each tier is guarded by its own row count rather
  # than assumed to have been populated.
  amb_of <- function(x) if (nrow(x)) dplyr::filter(x, .data$candidate_n > 1L) else NULL
  ambiguous_tbl <- dplyr::bind_rows(amb_of(tier_1_tbl), amb_of(tier_2_tbl),
                                    amb_of(tier_3_tbl))

  # Same reason: mutate() on an empty, column-less accepted table errors.
  audit_tbl <- if (nrow(accepted_tbl)) {
    accepted_tbl |>
      dplyr::mutate(state_agrees = !is.na(.data$amcb_state) &
                      .data$amcb_state == .data$license_state) |>
      dplyr::count(.data$match_tier, .data$state_agrees, name = "n") |>
      dplyr::arrange(.data$match_tier, dplyr::desc(.data$n))
  } else {
    tibble::tibble(match_tier = character(), state_agrees = logical(),
                   n = integer())
  }

  log_message("Resolution complete: ",
              format(nrow(accepted_tbl), big.mark = ","), " accepted; ",
              format(nrow(unresolved_tbl), big.mark = ","), " unresolved.")
  list(accepted = accepted_tbl, unresolved = unresolved_tbl,
       ambiguous = ambiguous_tbl, audit = audit_tbl)
}

#' Build the canonical AMCB state-license bridge.
#' @param accepted_tbl Accepted match rows.
#' @return [tbl_df]
build_license_bridge <- function(accepted_tbl) {
  log_message("Building canonical AMCB state-license bridge.")
  if (nrow(accepted_tbl) == 0L)
    return(tibble::tibble(amcb_id = character(), license_state = character(),
                          license_number = character()))
  accepted_tbl |>
    dplyr::transmute(
      amcb_id = .data$amcb_id,
      amcb_source_row = .data$amcb_source_row,
      amcb_first_name = .data$amcb_first_name,
      amcb_middle_name = .data$amcb_middle_name,
      amcb_last_name = .data$amcb_last_name,
      # The BOARD's state, always. Never the certificant's.
      license_state = .data$license_state,
      certificant_state = .data$amcb_state,
      state_agrees = !is.na(.data$amcb_state) &
        .data$amcb_state == .data$license_state,
      license_number = .data$license_number,
      license_status = .data$license_status,
      license_type = .data$license_type,
      board_source_file = .data$board_source_file,
      board_source_row = .data$board_source_row,
      match_tier = .data$match_tier,
      candidate_n = .data$candidate_n,
      deterministic_identifier = paste(.data$license_state,
                                       .data$license_number, sep = ":")) |>
    dplyr::distinct(.data$amcb_id, .data$license_state, .data$license_number,
                    .keep_all = TRUE)
}

#' Build a state-board acquisition priority manifest.
#'
#' Ranks states by UNRESOLVED AMCB certificants, so the queue re-orders itself
#' as rosters arrive instead of hard-coding NY/CA/FL/TX/GA forever. A state
#' counts as loaded when at least one board row carries it.
#'
#' @param cohort_tbl Standardized complete AMCB cohort.
#' @param unresolved_tbl Current unresolved AMCB cohort.
#' @param license_tbl Current standardized state-board universe.
#' @return [tbl_df] one row per state, priority 1..k for unloaded states.
build_license_acquisition_manifest <- function(cohort_tbl, unresolved_tbl,
                                               license_tbl) {
  log_message("[acquisition] Building state acquisition manifest.")

  cohort_state_tbl <- cohort_tbl |>
    dplyr::filter(!is.na(.data$amcb_state)) |>
    dplyr::count(state = .data$amcb_state, name = "cohort_n")
  unresolved_state_tbl <- if (nrow(unresolved_tbl)) {
    unresolved_tbl |>
      dplyr::filter(!is.na(.data$amcb_state)) |>
      dplyr::count(state = .data$amcb_state, name = "unresolved_amcb")
  } else {
    tibble::tibble(state = character(), unresolved_amcb = integer())
  }
  loaded_state_tbl <- license_tbl |>
    dplyr::filter(!is.na(.data$license_state)) |>
    dplyr::distinct(state = .data$license_state) |>
    dplyr::mutate(roster_loaded = TRUE)

  manifest_tbl <- cohort_state_tbl |>
    dplyr::full_join(unresolved_state_tbl, by = "state") |>
    dplyr::left_join(loaded_state_tbl, by = "state") |>
    dplyr::mutate(
      cohort_n = tidyr::replace_na(.data$cohort_n, 0L),
      unresolved_amcb = tidyr::replace_na(.data$unresolved_amcb, 0L),
      roster_loaded = tidyr::replace_na(.data$roster_loaded, FALSE),
      resolved_n = .data$cohort_n - .data$unresolved_amcb,
      resolved_pct = dplyr::if_else(.data$cohort_n > 0L,
                                    100 * .data$resolved_n / .data$cohort_n,
                                    NA_real_)) |>
    # FALSE sorts before TRUE, so unloaded states lead and cumsum() below
    # numbers them contiguously from 1.
    dplyr::arrange(.data$roster_loaded, dplyr::desc(.data$unresolved_amcb),
                   .data$state) |>
    dplyr::mutate(
      queueable = !.data$roster_loaded & .data$unresolved_amcb > 0L,
      priority = dplyr::if_else(.data$queueable, cumsum(.data$queueable),
                                NA_integer_)) |>
    dplyr::select("priority", "state", "cohort_n", "unresolved_amcb",
                  "resolved_n", "resolved_pct", "roster_loaded")

  nxt <- manifest_tbl |> dplyr::filter(!is.na(.data$priority)) |>
    dplyr::slice_min(.data$priority, n = 1L, with_ties = FALSE)
  if (nrow(nxt) == 1L) {
    log_message("[acquisition] Next board: ", nxt$state[[1L]], " with ",
                format(nxt$unresolved_amcb[[1L]], big.mark = ",", trim = TRUE),
                " unresolved certificants.")
  } else {
    log_message("[acquisition] No unloaded state has unresolved rows.")
  }
  manifest_tbl
}

#' Summarize license resolution by state.
#' @param cohort_tbl Standardized complete AMCB cohort.
#' @param resolution Object returned by resolve_amcb_licenses().
#' @return [tbl_df] per-state resolved / ambiguous / unresolved counts.
summarize_license_resolution_by_state <- function(cohort_tbl, resolution) {
  log_message("[acquisition] Summarizing state-level resolution.")
  cnt <- function(x, nm) {
    if (!nrow(x) || !"amcb_state" %in% names(x))
      return(tibble::tibble(state = character(), !!nm := integer()))
    dplyr::count(x, state = .data$amcb_state, name = nm)
  }
  amb <- if (nrow(resolution$ambiguous) &&
             "amcb_state" %in% names(resolution$ambiguous)) {
    resolution$ambiguous |>
      dplyr::distinct(.data$amcb_id, state = .data$amcb_state) |>
      dplyr::count(.data$state, name = "ambiguous_n")
  } else {
    tibble::tibble(state = character(), ambiguous_n = integer())
  }

  cohort_tbl |>
    dplyr::count(state = .data$amcb_state, name = "cohort_n") |>
    dplyr::left_join(cnt(resolution$accepted, "deterministic_n"), by = "state") |>
    dplyr::left_join(amb, by = "state") |>
    dplyr::left_join(cnt(resolution$unresolved, "unresolved_n"), by = "state") |>
    # across() with all_of() on plain names: c(.data$x, .data$y) inside across()
    # is deprecated and errors under current dplyr.
    dplyr::mutate(dplyr::across(dplyr::all_of(c("deterministic_n",
                                                "ambiguous_n", "unresolved_n")),
                                ~ tidyr::replace_na(.x, 0L)),
                  deterministic_pct = 100 * .data$deterministic_n /
                    .data$cohort_n) |>
    dplyr::arrange(dplyr::desc(.data$unresolved_n), .data$state)
}

#' Save the acquisition manifest and per-state audit.
#' @param manifest_tbl Acquisition manifest.
#' @param state_audit_tbl Per-state resolution audit.
#' @param artifact_dir Destination directory.
#' @return Invisibly the saved paths.
save_license_acquisition_audit <- function(manifest_tbl, state_audit_tbl,
                                           artifact_dir = "artifacts") {
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
  paths <- list(
    manifest_path = file.path(artifact_dir,
                              paste0("amcb_license_acquisition_manifest_",
                                     timestamp, ".csv")),
    audit_path = file.path(artifact_dir,
                           paste0("amcb_license_state_audit_", timestamp,
                                  ".csv")))
  log_message("[acquisition] Saving manifest: ", paths$manifest_path)
  readr::write_csv(manifest_tbl, paths$manifest_path, na = "")
  log_message("[acquisition] Saving state audit: ", paths$audit_path)
  readr::write_csv(state_audit_tbl, paths$audit_path, na = "")
  invisible(paths)
}

#' Save the bridge and audit artifacts.
#' @param bridge_tbl Canonical bridge. @param unresolved_tbl Unresolved rows.
#' @param ambiguous_tbl Ambiguous candidates. @param destination_dir Directory.
#' @return Named list of saved paths.
save_license_artifacts <- function(bridge_tbl, unresolved_tbl, ambiguous_tbl,
                                   destination_dir = "data") {
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  artifact_dir <- file.path(destination_dir, "linkage_audit")
  dir.create(destination_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

  paths <- list(
    timestamped = file.path(destination_dir,
                            paste0("amcb_state_licenses_", timestamp, ".csv")),
    canonical = file.path(destination_dir, "amcb_state_licenses.csv"),
    unresolved = file.path(artifact_dir,
                           paste0("amcb_state_license_unresolved_", timestamp,
                                  ".csv")),
    ambiguous = file.path(artifact_dir,
                          paste0("amcb_state_license_ambiguous_", timestamp,
                                 ".csv")))

  log_message("Writing timestamped license bridge: ", paths$timestamped)
  readr::write_csv(bridge_tbl, paths$timestamped, na = "")
  log_message("Writing canonical resolver dependency: ", paths$canonical)
  readr::write_csv(bridge_tbl, paths$canonical, na = "")
  log_message("Writing unresolved cohort: ", paths$unresolved)
  readr::write_csv(unresolved_tbl, paths$unresolved, na = "")
  log_message("Writing ambiguous candidates: ", paths$ambiguous)
  readr::write_csv(ambiguous_tbl, paths$ambiguous, na = "")
  paths
}

#' Build AMCB state-license identifiers from board rosters.
#' @param amcb_path AMCB cohort CSV. @param board_dir Board roster directory.
#' @param destination_dir Output directory.
#' @param allow_national_tier Enable the national first+last tier.
#' @return Invisibly list(bridge, resolution, paths).
build_amcb_state_licenses <- function(amcb_path = "data/amcb_roster.csv",
                                      board_dir = "data/raw/state_boards",
                                      destination_dir = "data",
                                      artifact_dir = "artifacts",
                                      allow_national_tier = FALSE) {
  log_message("========== AMCB LICENSE ACQUISITION ==========")
  log_message("AMCB input: ", amcb_path)
  log_message("Board directory: ", board_dir)
  log_message("Destination: ", destination_dir)

  if (!file.exists(amcb_path))
    stop("AMCB cohort does not exist: ", amcb_path, call. = FALSE)
  if (!dir.exists(board_dir))
    stop("State-board directory does not exist: ", board_dir,
         "\nCreate it and place state roster CSV/XLSX files there.",
         call. = FALSE)

  cohort_tbl <- read_amcb_roster(amcb_path)
  license_tbl <- read_all_board_rosters(board_dir)
  resolution <- resolve_amcb_licenses(cohort_tbl, license_tbl,
                                      allow_national_tier)
  bridge_tbl <- build_license_bridge(resolution$accepted)
  manifest_tbl <- build_license_acquisition_manifest(cohort_tbl,
                                                     resolution$unresolved,
                                                     license_tbl)
  state_audit_tbl <- summarize_license_resolution_by_state(cohort_tbl,
                                                           resolution)
  paths <- save_license_artifacts(bridge_tbl, resolution$unresolved,
                                  resolution$ambiguous, destination_dir)
  audit_paths <- save_license_acquisition_audit(manifest_tbl, state_audit_tbl,
                                                artifact_dir)

  cohort_n <- nrow(cohort_tbl)
  linked_n <- dplyr::n_distinct(bridge_tbl$amcb_id)
  states_loaded <- attr(license_tbl, "states_loaded")

  log_message("========== ACQUISITION SUMMARY ==========")
  log_message("AMCB cohort: ", format(cohort_n, big.mark = ","))
  log_message("Board states loaded: ", length(states_loaded), " (",
              paste(states_loaded, collapse = ", "), ")")
  log_message("Linked to state license: ", format(linked_n, big.mark = ","),
              " (", sprintf("%.1f%%", 100 * linked_n / cohort_n), ")")
  log_message("Still unresolved: ",
              format(cohort_n - linked_n, big.mark = ","))
  if (nrow(bridge_tbl) > 0L)
    log_message("Accepted matches whose state disagrees with the ",
                "certificant's: ", sum(!bridge_tbl$state_agrees, na.rm = TRUE))
  log_message("Canonical dependency created: ", paths$canonical)
  log_message("=========================================")

  invisible(list(bridge = bridge_tbl, resolution = resolution,
                 manifest = manifest_tbl, state_audit = state_audit_tbl,
                 paths = paths, audit_paths = audit_paths))
}

# Sourcing this file must NOT run the pipeline. The original ran
# build_amcb_state_licenses() at load time, so `source()` from a test, or from
# the resolver, would execute the whole acquisition and error on missing data.
if (sys.nframe() == 0L && !interactive()) {
  license_build <- build_amcb_state_licenses(
    amcb_path = "data/amcb_roster.csv",
    board_dir = "data/raw/state_boards",
    destination_dir = "data")
}
