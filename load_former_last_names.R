#!/usr/bin/env Rscript
# =============================================================================
# Ingest an external former/maiden-surname export onto the AMCB roster
# =============================================================================
#
# expand_former_name_candidates.R rescues the "no candidate at all" bucket by
# blocking on a former/maiden surname, but the AMCB scrape provides no such
# column. This attaches one from an EXTERNAL source the repository cannot
# originate itself -- marriage records, voter name-history, or a licensing
# board's name-change log -- normalizing it onto `certification_number` and
# collapsing multiple former surnames per certificant into the single delimited
# string the expander's `split_former_surnames()` understands.
#
# It accepts either shape of source:
#   * wide -- one row per person with one or more former-name columns; or
#   * long -- several rows per person, one former surname each.
# Point `source_former_cols` at the relevant column(s); rows are grouped by id
# regardless.
#
# The function is source()-able (defines a function, runs nothing). The guarded
# runner at the bottom reads env-configured paths for a standalone pass.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
})

#' Attach external former/maiden surnames to the AMCB roster
#'
#' @param roster AMCB roster (data frame) keyed by `roster_id_col`; returned
#'   unchanged except for the added column, so it can flow straight into
#'   `expand_amcb_former_name_candidates()`.
#' @param former_source External former-name table (data frame).
#' @param roster_id_col,source_id_col Join keys on each side.
#' @param source_former_cols Column(s) in `former_source` holding former
#'   surnames.
#' @param former_col_out Name of the collapsed column added to the roster
#'   (the expander's `amcb_former_col`, default `former_last_name`).
#' @param sep Separator for collapsing multiple former surnames. Defaults to
#'   "; ", one of the delimiters the expander splits on.
#' @return `roster` with `former_col_out` added: a `sep`-joined, de-duplicated,
#'   upper-cased string of former surnames per certificant, or NA where none.
attach_former_last_names <- function(
    roster,
    former_source,
    roster_id_col = "certification_number",
    source_id_col = "certification_number",
    source_former_cols = c("former_last_name"),
    former_col_out = "former_last_name",
    sep = "; "
) {
  if (!roster_id_col %in% base::names(roster)) {
    base::stop("roster has no column '", roster_id_col, "'", call. = FALSE)
  }
  missing_src <- base::setdiff(
    c(source_id_col, source_former_cols),
    base::names(former_source)
  )
  if (base::length(missing_src) > 0L) {
    base::stop(
      "former_source missing columns: ",
      base::paste(missing_src, collapse = ", "),
      call. = FALSE
    )
  }

  norm_surname <- function(x) {
    v <- stringr::str_squish(stringr::str_to_upper(base::as.character(x)))
    v[base::is.na(v) | v == ""] <- NA_character_
    v
  }

  # One de-duplicated, sorted, delimited string of former surnames per id.
  collapsed <- former_source |>
    dplyr::transmute(
      .id = stringr::str_squish(base::as.character(.data[[source_id_col]])),
      dplyr::across(dplyr::all_of(source_former_cols), norm_surname)
    ) |>
    tidyr::pivot_longer(
      dplyr::all_of(source_former_cols),
      values_to = ".former"
    ) |>
    dplyr::filter(!base::is.na(.data$.id), !base::is.na(.data$.former)) |>
    dplyr::distinct(.data$.id, .data$.former) |>
    dplyr::arrange(.data$.id, .data$.former) |>
    dplyr::group_by(.data$.id) |>
    dplyr::summarise(
      .former_joined = base::paste(.data$.former, collapse = sep),
      .groups = "drop"
    )

  out <- roster
  if (former_col_out %in% base::names(out)) {
    base::message(
      "roster already had '", former_col_out,
      "'; overwriting from the external source."
    )
    out[[former_col_out]] <- NULL
  }

  out$.rid <- stringr::str_squish(base::as.character(out[[roster_id_col]]))
  out <- out |>
    dplyr::left_join(collapsed, by = c(".rid" = ".id"))
  out[[former_col_out]] <- out$.former_joined
  out$.former_joined <- NULL
  out$.rid <- NULL
  out
}

# -----------------------------------------------------------------------------
# Standalone runner (guarded so source() does not trigger it)
# -----------------------------------------------------------------------------

if (base::sys.nframe() == 0L) {
  roster_path <- base::Sys.getenv("AMCB_ROSTER", "midwives.csv")
  source_path <- base::Sys.getenv("FORMER_NAME_SOURCE", "amcb_former_names.csv")
  out_path    <- base::Sys.getenv("FORMER_NAME_OUT", "midwives_with_former_names.csv")
  id_col      <- base::Sys.getenv("FORMER_SOURCE_ID_COL", "certification_number")
  cols_env    <- base::Sys.getenv("FORMER_SOURCE_COLS", "former_last_name")
  former_cols <- base::trimws(base::strsplit(cols_env, ",")[[1]])

  base::stopifnot(base::file.exists(roster_path), base::file.exists(source_path))

  roster <- readr::read_csv(
    roster_path,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  )
  src <- readr::read_csv(
    source_path,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  )

  out <- attach_former_last_names(
    roster, src,
    source_id_col = id_col,
    source_former_cols = former_cols
  )

  readr::write_csv(out, out_path, na = "")

  n_with <- base::sum(
    !base::is.na(out$former_last_name) & out$former_last_name != ""
  )
  base::message(base::sprintf(
    "Attached former surnames to %s of %s roster rows -> %s",
    base::format(n_with, big.mark = ","),
    base::format(base::nrow(out), big.mark = ","),
    out_path
  ))
}
