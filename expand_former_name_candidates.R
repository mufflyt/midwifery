#!/usr/bin/env Rscript
# =============================================================================
# Former/maiden-surname candidate expansion for AMCB -> NPPES blocking
# =============================================================================
#
# Adds former/maiden surnames to the surname-blocking stage so an AMCB record
# that has no NPPES candidate under its current surname can still enter the
# candidate universe under a historical surname. This targets the "no candidate
# at all" bucket, where a decades-old surname change -- in a cohort that is
# ~99% women -- is a leading reason a real provider is simply absent from the
# surname-blocked pool.
#
# Scope: this runs over the WHOLE roster (every AMCB person is blocked by both
# current and former surnames), so it reproduces the full surname-blocked
# candidate universe rather than only the residual. The join is surname-only
# (no first-initial filter), so `candidate_pairs` on the real ~22k x full-NPPES
# inputs is large; `candidate_block_source` (current / former / both) lets the
# downstream audit tell the two blocking paths apart.
#
# This function only EXPANDS the candidate universe -- it never decides a match.
# `first_name_exact` is annotation, not a gate. Feed `candidate_pairs` into the
# existing conservative resolver (identity evidence + adjudication) unchanged;
# a former-name rescue with exactly one candidate is a lead, not a link.
#
# Data dependency: this expects an AMCB former/maiden-surname column
# (`former_last_name` by default). The current AMCB scrape does NOT provide one
# -- the scraped roster is name + certification + dates only -- so this is
# wired up ready for a former-name source to be supplied; with the column empty
# it rescues no one. Note the NPPES SIDE of the same problem is already handled
# elsewhere: fetch_npi_candidates.py emits an `other_names` / name-variant row
# per former/maiden name and match_nppes.R scores each. This function is the
# complementary AMCB-side half.
# =============================================================================

#' Expand AMCB candidate blocking with former or maiden surnames
#'
#' Adds former/maiden surnames to the surname-blocking stage so AMCB records
#' that have no NPPES candidate under their current surname can enter the
#' candidate universe under a historical surname.
#'
#' The function deliberately does not decide whether a candidate is a match.
#' It only expands the candidate universe. Existing conservative scoring and
#' adjudication should be applied after this step.
#'
#' @param amcb_people AMCB person-level table.
#' @param nppes_people NPPES provider-level table.
#' @param amcb_id_col AMCB unique identifier column.
#' @param amcb_first_col AMCB first-name column.
#' @param amcb_last_col AMCB current surname column.
#' @param amcb_former_col AMCB former/maiden surname column.
#' @param npi_col NPPES NPI column.
#' @param nppes_first_col NPPES first-name column.
#' @param nppes_last_col NPPES surname column.
#' @param existing_status_col Optional AMCB column containing existing linkage
#'   status, such as "no_candidate".
#' @param no_candidate_value Value identifying the existing no-candidate
#'   bucket.
#' @return A list containing candidate pairs, rescue summary, person-level
#'   rescue status, and diagnostics.
#' @export
expand_amcb_former_name_candidates <- function(
    amcb_people,
    nppes_people,
    amcb_id_col = "amcb_id",
    amcb_first_col = "first_name",
    amcb_last_col = "last_name",
    amcb_former_col = "former_last_name",
    npi_col = "npi",
    nppes_first_col = "first_name",
    nppes_last_col = "last_name",
    existing_status_col = "match_status",
    no_candidate_value = "no_candidate"
) {
  required_amcb <- c(
    amcb_id_col,
    amcb_first_col,
    amcb_last_col,
    amcb_former_col
  )

  required_nppes <- c(
    npi_col,
    nppes_first_col,
    nppes_last_col
  )

  missing_amcb <- base::setdiff(
    required_amcb,
    base::names(amcb_people)
  )

  missing_nppes <- base::setdiff(
    required_nppes,
    base::names(nppes_people)
  )

  if (base::length(missing_amcb) > 0L) {
    base::stop(
      "Missing AMCB columns: ",
      base::paste(missing_amcb, collapse = ", ")
    )
  }

  if (base::length(missing_nppes) > 0L) {
    base::stop(
      "Missing NPPES columns: ",
      base::paste(missing_nppes, collapse = ", ")
    )
  }

  base::message(
    "Starting former/maiden-name candidate expansion."
  )
  base::message(
    "AMCB rows: ",
    base::format(base::nrow(amcb_people), big.mark = ",")
  )
  base::message(
    "NPPES rows: ",
    base::format(base::nrow(nppes_people), big.mark = ",")
  )

  normalize_name <- function(name_value) {
    normalized <- name_value |>
      base::as.character() |>
      stringr::str_to_upper() |>
      stringi::stri_trans_general("Latin-ASCII") |>
      stringr::str_replace_all("[^A-Z]", "") |>
      stringr::str_trim()

    dplyr::if_else(
      normalized == "",
      NA_character_,
      normalized
    )
  }

  split_former_surnames <- function(surname_value) {
    surname_value |>
      base::as.character() |>
      stringr::str_replace_all(
        stringr::regex(
          "\\b(?:N\u00c9E|NEE|FORMERLY|MAIDEN)\\b",
          ignore_case = TRUE
        ),
        ""
      ) |>
      stringr::str_split(
        pattern = "\\s*(?:;|\\||/|,)\\s*"
      )
  }

  base::message("Standardizing AMCB names.")

  amcb_standardized <- amcb_people |>
    dplyr::mutate(
      .amcb_id = base::as.character(.data[[amcb_id_col]]),
      .amcb_first_raw = base::as.character(
        .data[[amcb_first_col]]
      ),
      .amcb_current_last_raw = base::as.character(
        .data[[amcb_last_col]]
      ),
      .amcb_former_last_raw = base::as.character(
        .data[[amcb_former_col]]
      ),
      .amcb_first_norm = normalize_name(
        .data[[amcb_first_col]]
      ),
      .amcb_current_last_norm = normalize_name(
        .data[[amcb_last_col]]
      )
    )

  if (
    !base::is.null(existing_status_col) &&
      existing_status_col %in% base::names(amcb_standardized)
  ) {
    amcb_standardized <- amcb_standardized |>
      dplyr::mutate(
        .existing_status = base::as.character(
          .data[[existing_status_col]]
        )
      )
  } else {
    amcb_standardized <- amcb_standardized |>
      dplyr::mutate(
        .existing_status = NA_character_
      )
  }

  base::message("Expanding former/maiden surname values.")

  former_names <- amcb_standardized |>
    dplyr::transmute(
      .amcb_id,
      .amcb_first_norm,
      .amcb_current_last_norm,
      .amcb_former_last_raw,
      .existing_status,
      .former_parts = split_former_surnames(
        .amcb_former_last_raw
      )
    ) |>
    tidyr::unnest_longer(
      .former_parts,
      values_to = ".former_last_raw"
    ) |>
    dplyr::mutate(
      .block_surname_norm = normalize_name(
        .former_last_raw
      )
    ) |>
    dplyr::filter(
      !base::is.na(.block_surname_norm),
      .block_surname_norm != .amcb_current_last_norm
    ) |>
    dplyr::distinct(
      .amcb_id,
      .block_surname_norm,
      .keep_all = TRUE
    ) |>
    dplyr::transmute(
      .amcb_id,
      .amcb_first_norm,
      .block_surname_norm,
      .candidate_block_source = "former_surname",
      .existing_status
    )

  current_names <- amcb_standardized |>
    dplyr::filter(
      !base::is.na(.amcb_current_last_norm)
    ) |>
    dplyr::transmute(
      .amcb_id,
      .amcb_first_norm,
      .block_surname_norm = .amcb_current_last_norm,
      .candidate_block_source = "current_surname",
      .existing_status
    )

  block_names <- dplyr::bind_rows(
    current_names,
    former_names
  ) |>
    dplyr::distinct(
      .amcb_id,
      .block_surname_norm,
      .candidate_block_source,
      .keep_all = TRUE
    )

  base::message(
    "Current-surname blocks: ",
    base::format(base::nrow(current_names), big.mark = ",")
  )
  base::message(
    "Former-surname blocks: ",
    base::format(base::nrow(former_names), big.mark = ",")
  )

  base::message("Standardizing NPPES names.")

  nppes_standardized <- nppes_people |>
    dplyr::mutate(
      .npi = base::as.character(.data[[npi_col]]),
      .nppes_first_raw = base::as.character(
        .data[[nppes_first_col]]
      ),
      .nppes_last_raw = base::as.character(
        .data[[nppes_last_col]]
      ),
      .nppes_first_norm = normalize_name(
        .data[[nppes_first_col]]
      ),
      .block_surname_norm = normalize_name(
        .data[[nppes_last_col]]
      )
    ) |>
    dplyr::filter(
      !base::is.na(.block_surname_norm),
      !base::is.na(.npi)
    )

  base::message(
    "Generating surname-blocked AMCB-NPPES candidate pairs."
  )

  candidate_pairs_raw <- block_names |>
    dplyr::inner_join(
      nppes_standardized,
      by = ".block_surname_norm",
      relationship = "many-to-many"
    ) |>
    dplyr::mutate(
      .first_exact = !base::is.na(.amcb_first_norm) &
        !base::is.na(.nppes_first_norm) &
        .amcb_first_norm == .nppes_first_norm
    )

  base::message(
    "Raw candidate pairs: ",
    base::format(
      base::nrow(candidate_pairs_raw),
      big.mark = ","
    )
  )

  base::message(
    "Collapsing candidates reached through multiple surname paths."
  )

  candidate_pairs <- candidate_pairs_raw |>
    dplyr::group_by(
      .amcb_id,
      .npi
    ) |>
    dplyr::summarise(
      candidate_block_source = dplyr::case_when(
        base::any(
          .candidate_block_source == "current_surname"
        ) &&
          base::any(
            .candidate_block_source == "former_surname"
          ) ~ "both",
        base::any(
          .candidate_block_source == "former_surname"
        ) ~ "former_surname",
        TRUE ~ "current_surname"
      ),
      block_surnames = base::paste(
        base::sort(base::unique(.block_surname_norm)),
        collapse = "|"
      ),
      first_name_exact = base::any(.first_exact),
      existing_status = dplyr::first(.existing_status),
      .groups = "drop"
    ) |>
    dplyr::left_join(
      amcb_standardized |>
        dplyr::select(
          .amcb_id,
          dplyr::all_of(base::names(amcb_people))
        ),
      by = ".amcb_id"
    ) |>
    dplyr::left_join(
      nppes_standardized |>
        dplyr::select(
          .npi,
          dplyr::all_of(base::names(nppes_people))
        ) |>
        dplyr::distinct(
          .npi,
          .keep_all = TRUE
        ),
      by = ".npi",
      suffix = c("_amcb", "_nppes")
    )

  base::message(
    "Unique AMCB-NPI candidate pairs: ",
    base::format(base::nrow(candidate_pairs), big.mark = ",")
  )

  current_candidate_people <- candidate_pairs |>
    dplyr::filter(
      candidate_block_source %in% c(
        "current_surname",
        "both"
      )
    ) |>
    dplyr::distinct(.amcb_id)

  former_candidate_people <- candidate_pairs |>
    dplyr::filter(
      candidate_block_source %in% c(
        "former_surname",
        "both"
      )
    ) |>
    dplyr::distinct(.amcb_id)

  former_only_candidate_people <- candidate_pairs |>
    dplyr::group_by(.amcb_id) |>
    dplyr::summarise(
      has_current_candidate = base::any(
        candidate_block_source %in% c(
          "current_surname",
          "both"
        )
      ),
      has_former_candidate = base::any(
        candidate_block_source %in% c(
          "former_surname",
          "both"
        )
      ),
      candidate_count = dplyr::n_distinct(.npi),
      .groups = "drop"
    ) |>
    dplyr::filter(
      !has_current_candidate,
      has_former_candidate
    )

  base::message("Constructing person-level rescue diagnostics.")

  person_status <- amcb_standardized |>
    dplyr::select(
      .amcb_id,
      .existing_status,
      .amcb_first_raw,
      .amcb_current_last_raw,
      .amcb_former_last_raw
    ) |>
    dplyr::left_join(
      candidate_pairs |>
        dplyr::group_by(.amcb_id) |>
        dplyr::summarise(
          candidate_count = dplyr::n_distinct(.npi),
          current_candidate_count = dplyr::n_distinct(
            .npi[
              candidate_block_source %in% c(
                "current_surname",
                "both"
              )
            ]
          ),
          former_candidate_count = dplyr::n_distinct(
            .npi[
              candidate_block_source %in% c(
                "former_surname",
                "both"
              )
            ]
          ),
          .groups = "drop"
        ),
      by = ".amcb_id"
    ) |>
    dplyr::mutate(
      dplyr::across(
        c(
          candidate_count,
          current_candidate_count,
          former_candidate_count
        ),
        ~ tidyr::replace_na(.x, 0L)
      ),
      had_current_candidate =
        current_candidate_count > 0L,
      has_former_candidate =
        former_candidate_count > 0L,
      rescued_by_former_surname =
        !had_current_candidate &
        has_former_candidate,
      rescue_status = dplyr::case_when(
        rescued_by_former_surname &
          candidate_count == 1L ~
          "former_name_one_candidate",
        rescued_by_former_surname &
          candidate_count > 1L ~
          "former_name_multiple_candidates",
        had_current_candidate ~
          "current_name_candidate_exists",
        TRUE ~
          "still_no_candidate"
      )
    )

  if (
    !base::is.null(existing_status_col) &&
      existing_status_col %in% base::names(amcb_people)
  ) {
    original_no_candidate <- person_status |>
      dplyr::filter(
        .existing_status == no_candidate_value
      )
  } else {
    original_no_candidate <- person_status |>
      dplyr::filter(!had_current_candidate)
  }

  original_no_candidate_n <- base::nrow(original_no_candidate)

  rescued_n <- original_no_candidate |>
    dplyr::filter(rescued_by_former_surname) |>
    base::nrow()

  rescued_one_n <- original_no_candidate |>
    dplyr::filter(
      rescue_status == "former_name_one_candidate"
    ) |>
    base::nrow()

  rescued_multiple_n <- original_no_candidate |>
    dplyr::filter(
      rescue_status == "former_name_multiple_candidates"
    ) |>
    base::nrow()

  still_none_n <- original_no_candidate |>
    dplyr::filter(
      rescue_status == "still_no_candidate"
    ) |>
    base::nrow()

  rescue_summary <- tibble::tibble(
    metric = c(
      "original_no_candidate",
      "rescued_into_candidate_universe",
      "rescued_with_one_candidate",
      "rescued_with_multiple_candidates",
      "still_no_candidate"
    ),
    n = c(
      original_no_candidate_n,
      rescued_n,
      rescued_one_n,
      rescued_multiple_n,
      still_none_n
    ),
    # Scalar condition, vector `n`: dplyr::if_else() forbids the length
    # mismatch, so branch with a plain if/else (base ifelse would truncate
    # the result to length 1).
    pct_of_original_no_candidate =
      if (original_no_candidate_n > 0L) {
        n / original_no_candidate_n
      } else {
        NA_real_
      }
  )

  base::message("Former-name rescue summary:")

  rescue_summary |>
    dplyr::mutate(
      display = base::paste0(
        base::format(n, big.mark = ","),
        " (",
        scales::percent(
          pct_of_original_no_candidate,
          accuracy = 0.1
        ),
        ")"
      )
    ) |>
    dplyr::select(metric, display) |>
    utils::capture.output() |>
    base::paste(collapse = "\n") |>
    base::message()

  base::message(
    "Former-name expansion complete. ",
    "Do not auto-accept these candidates; pass them through the ",
    "existing conservative identity resolver."
  )

  base::list(
    candidate_pairs = candidate_pairs,
    rescue_summary = rescue_summary,
    person_status = person_status,
    former_only_candidate_people = former_only_candidate_people,
    current_candidate_people = current_candidate_people,
    former_candidate_people = former_candidate_people
  )
}
