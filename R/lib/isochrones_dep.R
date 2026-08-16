#!/usr/bin/env Rscript
#' @title Dependency on the isochrones repo's variety-sentence engine
#'
#' @description
#' This project renders per-county and per-district map prose using the engine
#' that lives in mufflyt/isochrones at `R/variety_sentences.R`. That repo is the
#' CANONICAL home; nothing here re-implements or copies it.
#'
#' @section Why a path dependency rather than vendoring:
#' Copying the engine in would be easier and is the wrong call. This codebase
#' has already been bitten three times by the same failure -- the gender gate,
#' the credential helpers and `rank_one_to_one()` each existed in multiple
#' files, load order decided which ran, and a fix applied to one was a fix
#' applied to none. A second copy of the prose engine, drifting from the one
#' the urogyn maps use, would reproduce that exactly.
#'
#' @section Resolution order:
#' \enumerate{
#'   \item `ISOCHRONES_HOME` environment variable, if set.
#'   \item `~/isochrones`, the conventional checkout location.
#' }
#'
#' @section It fails loudly, and that is deliberate:
#' If the engine cannot be found the loader aborts with instructions. It does
#' NOT fall back to a local stub. A silent fallback would render sentences that
#' look right while diverging from the maps they are supposed to match, which is
#' worse than not rendering them at all.
#'
#' @section Branch caveat, correct as of 2026-08-09:
#' `R/variety_sentences.R` exists on the `feature/variety-sentence-engine`
#' branch of isochrones and, once merged, on `main`. It is NOT on
#' `slice/manuscript-sap-ledger`. If your isochrones checkout is sitting on the
#' slice branch, this loader will abort until that branch has the file --
#' correctly, because the engine genuinely is not there.
#'
#' @family dependencies
#' @author Tyler Muffly, MD + Claude Code
#' @name isochrones_dep
NULL

#' Locate the isochrones checkout
#' @return [character(1)] path to the repo root.
#' @family dependencies
#' @export
isochrones_home <- function() {
  h <- Sys.getenv("ISOCHRONES_HOME")
  if (nzchar(h)) return(path.expand(h))
  path.expand("~/isochrones")
}

#' Source the variety-sentence engine, aborting if it is unavailable
#'
#' @param quiet [logical(1)]: suppress the confirmation message.
#' @return Invisibly, the path sourced.
#' @family dependencies
#' @export
load_variety_sentence_engine <- function(quiet = FALSE) {
  if (exists("mm_rotate_facts", mode = "function")) return(invisible("already loaded"))

  root <- isochrones_home()
  engine <- file.path(root, "R", "variety_sentences.R")

  if (!dir.exists(root)) {
    stop(sprintf(paste0(
      "isochrones checkout not found at %s.\n",
      "  The variety-sentence engine lives in mufflyt/isochrones.\n",
      "  Set ISOCHRONES_HOME to your checkout, or clone it to ~/isochrones."), root),
      call. = FALSE)
  }
  if (!file.exists(engine)) {
    stop(sprintf(paste0(
      "Found the isochrones checkout at %s, but R/variety_sentences.R is not there.\n",
      "  The engine was extracted on branch feature/variety-sentence-engine\n",
      "  (commit 4638d677c) and is absent from slice/manuscript-sap-ledger.\n",
      "  Check out a branch that has it, or merge that branch.\n",
      "  Deliberately NOT falling back to a local copy: a second definition would\n",
      "  drift from the one the urogyn maps use."), root), call. = FALSE)
  }

  source(engine)
  if (!exists("mm_rotate_facts", mode = "function")) {
    stop("Sourced ", engine, " but mm_rotate_facts() is still undefined.", call. = FALSE)
  }
  if (!quiet) {
    cli::cli_alert_success("variety-sentence engine loaded from {engine}")
  }
  invisible(engine)
}

#' Source the isochrones name-matching and NPI-validation tools
#'
#' @description
#' Three things this project needed already exist in isochrones, and each was
#' briefly re-implemented here before being replaced by this loader:
#'
#' \describe{
#'   \item{`luhn_check_npi()`}{`R/utils/npi_luhn_qa.R`. isochrones already
#'     carried three copies of the Luhn check; a fourth here made four.}
#'   \item{`parse_physician_name_enhanced()`}{`R/name_parsing_protocol_enhanced.R`.
#'     humaniformat-backed, vectorised, and returns parse confidence and
#'     warnings alongside the parts -- strictly more than the scalar
#'     `parse_person()` it replaces.}
#'   \item{`are_nickname_variants()`}{`R/enhanced_name_parsing.R`, over the
#'     dictionary in `R/nickname_system.R`. This is the piece that resolves
#'     Beth/Elizabeth, which the local prefix rule could never reach and which
#'     was logged here as a permanent miss.}
#' }
#'
#' @section Why the whole chain is sourced:
#' `enhanced_name_parsing.R` calls `normalize_string()` and `get_nickname_map()`,
#' so `string_normalization.R` and `nickname_system.R` come with it. Sourcing
#' only the leaf file yields "could not find function normalize_string" at the
#' first nickname comparison, i.e. at match time rather than at load time.
#'
#' @section Which checkout, and why not isochrones_home():
#' This resolves `ISOCHRONES_R` exactly as `R/amcb_name_keys.R:44` and
#' `match_nppes.R:63` do, NOT via `isochrones_home()`. The two are not the same
#' place on this machine: `ISOCHRONES_HOME` points at `~/isochrones-main`
#' (branch `main`) while `ISOCHRONES_R` is unset and defaults to `~/isochrones`
#' (a feature branch). `enhanced_name_parsing.R` needs `normalize_string()`,
#' which `amcb_name_keys.R` has already sourced from the `ISOCHRONES_R`
#' checkout -- resolving differently here would put two copies of it in one
#' session and let load order decide which one runs. All name code must come
#' from ONE checkout.
#'
#' @section Cache:
#' `NAME_PARSER_CACHE_DISABLE=1` is set for the same reason `match_nppes.R:60`
#' sets it: the parser's read-through cache resolves its path with `here()`
#' relative to the isochrones checkout, which is not this project's root.
#'
#' @param quiet [logical(1)]: suppress the confirmation message.
#' @return Invisibly, the character vector of files sourced.
#' @family dependencies
#' @export
load_isochrones_name_tools <- function(quiet = FALSE) {
  needed <- c("luhn_check_npi", "parse_physician_name_enhanced",
              "are_nickname_variants")
  if (all(vapply(needed, exists, logical(1), mode = "function"))) {
    return(invisible("already loaded"))
  }

  iso_r <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
  root <- dirname(iso_r)
  if (!dir.exists(iso_r)) {
    stop(sprintf(paste0(
      "isochrones R/ directory not found at %s.\n",
      "  Name parsing, nickname resolution and the NPI Luhn check live there.\n",
      "  Set ISOCHRONES_R to the isochrones R/ directory, or clone the repo\n",
      "  to ~/isochrones. Use ISOCHRONES_R, not ISOCHRONES_HOME: the name code\n",
      "  in R/amcb_name_keys.R already resolves that variable, and the two point\n",
      "  at different checkouts on this machine.\n",
      "  Deliberately NOT falling back to local copies: duplicate name logic is\n",
      "  how this codebase has been bitten before -- a fix applied to one copy\n",
      "  is a fix applied to none."), iso_r), call. = FALSE)
  }

  Sys.setenv(NAME_PARSER_CACHE_DISABLE = "1")

  files <- c("utils/npi_luhn_qa.R", "string_normalization.R",
             "nickname_system.R", "enhanced_name_parsing.R",
             "name_parsing_protocol_enhanced.R")
  paths <- file.path(iso_r, files)
  missing <- paths[!file.exists(paths)]
  if (length(missing)) {
    stop(sprintf(paste0(
      "Found the isochrones checkout at %s, but these are missing:\n  %s\n",
      "  Check out a branch that has them."), root,
      paste(missing, collapse = "\n  ")), call. = FALSE)
  }
  for (p in paths) suppressWarnings(suppressMessages(source(p)))

  still <- needed[!vapply(needed, exists, logical(1), mode = "function")]
  if (length(still)) {
    stop("Sourced the isochrones name tools but these are still undefined: ",
         paste(still, collapse = ", "), call. = FALSE)
  }
  if (!quiet) message("isochrones name tools loaded from ", iso_r)
  invisible(paths)
}
