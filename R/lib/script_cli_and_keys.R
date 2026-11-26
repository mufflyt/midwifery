#!/usr/bin/env Rscript
#' @title Helpers four or more root scripts had each written for themselves
#'
#' @description
#' Three bodies that `tools/measure_code_complexity.R` pass 3 found copied
#' verbatim across scripts, each under a different name, which is the shape
#' `tests/ci_hygiene.R` H4 cannot see: H4 compares NAMES, and a renamed copy
#' has no name in common with its twin.
#'
#' They live together because each is too small to earn a file of its own and
#' all three are "things a standalone script needs before it starts": read an
#' argument, normalise a name, collapse a set to a key.
#'
#' @section What was duplicated:
#' \itemize{
#'   \item `cli_arg()` was `tp_arg()`, `tpf_arg()`, `gal_arg()` and `tl_arg()`
#'     in four scripts, byte-identical apart from the name.
#'   \item `identity_key_norm()` was `audit2013_norm()` and `drift_norm()`.
#'   \item `collapse_key_set()` was `dac_spine_collapse_set()` and
#'     `drift_collapse_set()`.
#' }
#'
#' @section Why not sooner:
#' A copy is cheaper than a shared file until the copies disagree. These had
#' not disagreed yet; they were consolidated before they could, which is the
#' only moment when the move costs nothing.

#' Read a `--key=value` command-line argument
#'
#' @param key [character(1)] argument name, without the leading dashes.
#' @param default returned when the argument is absent.
#' @return [character(1)] the value, or `default`.
cli_arg <- function(key, default) {
  hit <- grep(paste0("^--", key, "="), commandArgs(TRUE), value = TRUE)
  if (!length(hit)) return(default)
  sub(paste0("^--", key, "="), "", hit[1])
}

#' Normalise a name to an identity-comparison key
#'
#' Upper-case, every non-alphanumeric run to one space, trimmed, empty to NA.
#'
#' @param x [character] names as recorded.
#' @return [character] the key, `NA` where the input had no usable characters.
identity_key_norm <- function(x) {
  x |>
    toupper() |>
    stringr::str_replace_all("[^A-Z0-9 ]", " ") |>
    stringr::str_squish() |>
    dplyr::na_if("")
}

#' Collapse a set of values to one order-independent key
#'
#' Sorted so that the key does not depend on row order, de-duplicated and
#' pipe-joined; `NA` when the set is empty.
#'
#' @param x [character] values in any order, possibly with `NA` or `""`.
#' @return [character(1)] the key.
collapse_key_set <- function(x) {
  v <- unique(x[!is.na(x) & nzchar(x)])
  if (length(v) == 0L) return(NA_character_)
  paste(sort(v), collapse = "|")
}
