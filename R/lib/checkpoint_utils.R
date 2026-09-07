#' Write an R object to disk as a checkpoint, atomically
#'
#' A live geocoding run against Census/ArcGIS is hours of irreplaceable
#' network calls. A checkpoint written directly to its final path can be
#' left truncated if the process dies mid-write, and a later resume would
#' then load corrupt or partial state as if it were good. Writing to a
#' sibling temp file and promoting it via file.rename() (atomic on every
#' POSIX filesystem this repo runs on, since both paths are in the same
#' directory) means a reader can never observe a partially-written
#' checkpoint at the real path: it either sees the old good one, or the new
#' complete one, never something in between.
#'
#' @param object the R object to persist.
#' @param path [character] the final checkpoint path. A sibling temp file
#'   (path + ".tmp") is written first and then promoted via file.rename();
#'   the temp file is never the thing a reader is pointed at.
#' @return path, invisibly.
save_checkpoint_atomic <- function(object, path) {
  tmp <- paste0(path, ".tmp")
  saveRDS(object, tmp)
  file.rename(tmp, path)
  invisible(path)
}

#' Load a checkpoint written by save_checkpoint_atomic()
#'
#' Reads ONLY the promoted path -- never the sibling .tmp file, even if one
#' happens to be present. Leftover debris from an interrupted attempt is not
#' a valid checkpoint and must never be silently accepted as current.
#'
#' @param path [character] the checkpoint path.
#' @return the object previously saved via save_checkpoint_atomic().
load_checkpoint <- function(path) {
  if (!file.exists(path))
    stop(sprintf("load_checkpoint(): no checkpoint at %s", path), call. = FALSE)
  readRDS(path)
}
