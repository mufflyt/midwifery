#' @title Run-scoped validation outputs with atomic promotion
#'
#' @description
#' Two verifier processes were once running against this worktree at the same
#' time, both calling `write_csv()` on the same canonical paths from different
#' code revisions. Whichever finished last silently won, and the surviving files
#' could in principle have been a mixture: file A from run 1, file B from run 2,
#' with nothing in either recording that they did not come from the same
#' analysis. Nothing errored. Nothing looked wrong.
#'
#' The fix is to make the canonical location unwritable by a running verifier.
#' Each run writes only into `validation/run-<run_id>/`, which no other run can
#' name. `validation/latest` is a symlink, and it is repointed by a single
#' `rename()` -- a POSIX atomic operation -- only after the run has completed
#' successfully. A reader therefore always sees one whole, self-consistent set
#' of outputs from one run, never a blend of two.
#'
#' @section Why a symlink rather than copying into place:
#' Copying N files into `latest/` is N separate non-atomic writes, which
#' reintroduces the interleaving this exists to prevent -- just with a smaller
#' window. Repointing one symlink is a single atomic operation regardless of how
#' many files the run produced.
#'
#' @section Why not a lock:
#' A lock makes the second verifier fail or block. Run-scoped directories let
#' both finish, keep both sets of results for comparison, and still leave
#' `latest` unambiguous. Concurrent promotion is safe: each promoted directory
#' is complete, so last-writer-wins picks one whole run rather than a mixture.
#'
#' @family validation-provenance

#' Begin a validation run
#'
#' @param base [character(1)]: directory holding all runs.
#' @param run_id [character(1)]: optional; defaults to timestamp + PID, which
#'   cannot collide between concurrent processes on one machine.
#' @return [list] with `id`, `dir`, and `base`.
validation_run_begin <- function(base = "artifacts/validation", run_id = NULL) {
  if (is.null(run_id))
    run_id <- sprintf("%s-%d", format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"),
                      Sys.getpid())
  dir <- file.path(base, paste0("run-", run_id))
  if (dir.exists(dir))
    stop("validation run directory already exists, refusing to reuse: ", dir)
  dir.create(dir, recursive = TRUE)
  list(id = run_id, dir = dir, base = base)
}

#' Path for one output inside a run
#'
#' @param run the object returned by [validation_run_begin()].
#' @param filename [character(1)].
validation_run_path <- function(run, filename) file.path(run$dir, filename)

#' Publish a completed run as `latest`
#'
#' Call ONLY after every output has been written and every gate has passed. A
#' run that promoted on failure would publish a broken result under the name
#' readers trust.
#'
#' @param run the object returned by [validation_run_begin()].
#' @return the path of the `latest` link, invisibly.
validation_run_promote <- function(run) {
  latest <- file.path(run$base, "latest")
  tmp    <- file.path(run$base, paste0(".latest.", run$id))
  # Relative target so the tree stays valid if the worktree is moved or the
  # whole validation directory is copied elsewhere.
  ok <- file.symlink(basename(run$dir), tmp)
  if (!ok) stop("could not stage the latest symlink at ", tmp)
  if (!file.rename(tmp, latest)) {
    unlink(tmp)
    stop("could not atomically promote ", run$dir, " to ", latest)
  }
  invisible(latest)
}

#' Resolve the current `latest` run directory
#'
#' @param base [character(1)].
#' @return [character(1)] path, or NA when no run has been promoted.
validation_run_latest <- function(base = "artifacts/validation") {
  latest <- file.path(base, "latest")
  if (!file.exists(latest)) return(NA_character_)
  normalizePath(latest, mustWork = FALSE)
}
