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
