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

#' Source the isochrones canonical address parser
#'
#' @description
#' `R/address_parsing_standardized.R` is the canonical address parser --
#' postmastr with a regex fallback, a YAML healthcare dictionary that
#' standardises building designators and medical facility names, and a DuckDB
#' result cache. Its own banner reads "End of address parsing duplication".
#'
#' It was duplicated here anyway. `norm_addr()` and `norm_addr_drop_unit()` in
#' `R/lib/address_keys.R` are a hand-rolled abbreviation table covering a
#' fraction of the same ground. Measured against the 702 midwives with no
#' organization at their practice address, the hand-rolled table failed on
#' three classes the canonical parser handles: street-suffix expansion
#' ("HIGHLAND AVENUE" vs "HIGHLAND AVE"), building designators
#' ("SUGAR MAPLE DR BLDG 830") and suite designators ("PKWY NE STE 200").
#'
#' @section Why ISOCHRONES_R and not isochrones_home():
#' The same reason [load_isochrones_name_tools()] gives, and it is not a
#' stylistic choice. `ISOCHRONES_HOME` and `ISOCHRONES_R` resolve to DIFFERENT
#' checkouts on this machine. Sourcing the parser from one while the name code
#' comes from the other puts two vintages of `normalize_string()` in a single
#' session and lets load order decide which runs.
#'
#' @section Working directory:
#' The parser `source()`s siblings by RELATIVE path and reads
#' `config/address_parsing_config.yml` relative to the working directory, so it
#' can only be loaded from the isochrones root. `on.exit` restores the caller's
#' directory even on failure -- an unrestored working directory would redirect
#' every later `write_with_provenance()` call in the calling script into the
#' wrong repository.
#'
#' @section KNOWN UPSTREAM DEFECT:
#' USPS suffix abbreviation is applied to street-NAME tokens, so
#' "80 JESSE HILL JR DR SE" normalises to "80 jesse hl jr dr se" -- "Hill" is
#' part of a person's name (Jesse Hill Jr. Drive, Atlanta), not a suffix.
#' Harmless while both sides of a join are normalised identically, wrong when a
#' source spells the name differently. Fix it upstream; a local workaround
#' re-forks the parser.
#'
#' @param quiet [logical(1)]: suppress the confirmation message.
#' @return Invisibly, the path sourced.
#' @family dependencies
#' @export
load_isochrones_address_parser <- function(quiet = FALSE) {
  if (exists("normalize_addresses_canonical", mode = "function"))
    return(invisible("already loaded"))

  iso_r <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
  root <- dirname(iso_r)
  parser <- file.path(iso_r, "address_parsing_standardized.R")
  if (!file.exists(parser)) {
    stop(sprintf(paste0(
      "Canonical address parser not found at %s.\n",
      "  Set ISOCHRONES_R to the isochrones R/ directory, or clone the repo\n",
      "  to ~/isochrones. Use ISOCHRONES_R, not ISOCHRONES_HOME: the two point\n",
      "  at different checkouts on this machine, and all borrowed code must\n",
      "  come from one.\n",
      "  Deliberately NOT falling back to norm_addr(): it is a weaker\n",
      "  hand-rolled table and produces different join keys from the same\n",
      "  addresses."), parser), call. = FALSE)
  }

  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  setwd(root)
  suppressWarnings(suppressMessages(source(parser)))
  setwd(owd)

  if (!exists("normalize_addresses_canonical", mode = "function")) {
    stop("Sourced ", parser,
         " but normalize_addresses_canonical() is still undefined.", call. = FALSE)
  }
  if (!quiet) message("isochrones address parser loaded from ", parser)
  invisible(parser)
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
