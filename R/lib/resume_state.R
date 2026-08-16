# =============================================================================
# Checkpoint / resume state: what a long job knows when it starts again
# =============================================================================
# Extracted from scrape_healthgrades_midwives.R so it can be tested without a
# network. The logic is unchanged; only its location is.
#
# WHY THIS PARTICULAR CODE DESERVES A TEST. It is the only part of this
# repository that has already destroyed data. From the comment it replaces:
#
#   RECOVERY GUARD (added 2026-08-09 after losing 5,963 completed searches).
#   OUTPUT is rewritten wholesale from `done` at every checkpoint, so a missing
#   or reset checkpoint does not merely lose progress -- it TRUNCATES the CSV
#   that held it. 482 KB of results became 552 bytes.
#
# The guard added afterwards was never tested, because testing it meant running
# a scraper. It is the classic shape of an untested recovery path: written in
# response to an incident, correct as far as anyone could tell by reading, and
# exercised for the first time by the next incident.
#
# THE MERGE IS FLAT ON PURPOSE. utils::modifyList() looks like the tool for
# folding two checkpoints together and is not: it recurses into any element
# that is itself a list, and a tibble IS a list, so it merges column by column
# INSIDE each certificant and dies on row recycling. Name-keyed replacement is
# the whole point -- a record is replaced entire or not at all.
# =============================================================================

#' Rebuild the work-completed map from a checkpoint and a prior output file
#'
#' @param done `list`: checkpoint contents, named by certification number.
#'   Empty list when there is no checkpoint.
#' @param prior `data.frame` or NULL: a previously written output file, which
#'   may hold MORE completed work than the checkpoint does.
#' @param id_col `character(1)`: the identifier column in `prior`.
#' @return `list` named by identifier, with checkpoint entries winning.
resume_recover_done <- function(done, prior, id_col = "certification_number") {
  if (is.null(done)) done <- list()
  if (is.null(prior) || !nrow(prior) || !id_col %in% names(prior)) return(done)

  n_prior <- length(unique(prior[[id_col]]))
  # Only rebuild when the CSV genuinely knows MORE. A checkpoint that is ahead
  # of the file is the normal case and must not be overwritten by a stale file.
  if (n_prior <= length(done)) return(done)

  recovered <- split(prior, prior[[id_col]])
  # FLAT name-keyed replacement, never modifyList(). Checkpoint entries win:
  # they are the fresher pass.
  recovered[names(done)] <- done
  recovered
}

#' What remains to be done
#'
#' @param roster `data.frame`: the full work list.
#' @param done `list`: completed work, named by identifier.
#' @param id_col `character(1)`.
#' @param n_limit `integer`: optional bound for a partial batch.
resume_todo <- function(roster, done, id_col = "certification_number",
                        n_limit = NA_integer_) {
  todo <- roster[!as.character(roster[[id_col]]) %in% names(done), , drop = FALSE]
  if (!is.na(n_limit)) todo <- utils::head(todo, n_limit)
  todo
}

#' The output a run would write, given what it has completed
#'
#' Kept as a function because the truncation incident was caused by this
#' relationship: the output is derived WHOLLY from `done`, so anything `done`
#' forgets, the file forgets too.
resume_output <- function(done) {
  if (!length(done)) return(NULL)
  dplyr::bind_rows(done)
}
