# =============================================================================
# The data vault: one shared folder for the gitignored person-level inputs
# =============================================================================
# This project runs on more than one machine, and its person-level inputs are
# deliberately not in git. The linkage freeze was regenerated three times in
# two days under one filename (7473a8a6, b84e07ec, 1a7bd6a8), and the current
# one existed only on the machine that built it, so a rebuild on any other
# machine either stopped or -- worse -- ran against an older copy that
# happened to be lying around.
#
# The vault fixes both halves:
#   WHERE   one folder, synced by Dropbox and kept "available offline", found
#           the same way on every machine (vault_root()).
#   WHICH   files are never overwritten; each carries the first 8 hex digits of
#           its sha256 in its name, <stem>_<sha8>_<YYYY-MM-DD>.<ext>, and every
#           lookup re-hashes the file against the full sha256 the tracked
#           manifest records (vault_find()). A stale, partial or evicted copy
#           stops the build; it is never used.
#
# See docs/DATA_VAULT.md. Nothing here writes to the repository.
# =============================================================================

VAULT_DIRNAME <- "midwifery-data"

#' Where the vault is, on this machine
#'
#' In order: MIDWIFERY_VAULT; the Dropbox folder Dropbox's own config names
#' (~/.dropbox/info.json); the usual Dropbox locations. Stops with setup
#' instructions when none exists -- a missing vault is a setup problem, not a
#' reason to fall back to whatever copy is in artifacts/.
#' @param must_exist [logical(1)]
#' @return [character(1)] or NA_character_
vault_root <- function(must_exist = TRUE) {
  env <- Sys.getenv("MIDWIFERY_VAULT", "")
  if (nzchar(env)) {
    if (dir.exists(env)) return(normalizePath(env))
    stop("MIDWIFERY_VAULT is set to ", env, ", which does not exist.", call. = FALSE)
  }
  cands <- character(0)
  info <- path.expand("~/.dropbox/info.json")
  if (file.exists(info)) {
    cfg <- tryCatch(jsonlite::read_json(info), error = function(e) list())
    cands <- c(cands, vapply(cfg, function(a) if (is.null(a$path)) NA_character_ else a$path, character(1)))
  }
  cands <- c(cands, Sys.glob(path.expand("~/Library/CloudStorage/Dropbox*")), Sys.glob(path.expand("~/Dropbox*")))
  hits <- unique(file.path(cands[!is.na(cands)], VAULT_DIRNAME))
  hits <- hits[dir.exists(hits)]
  if (length(hits) == 1L) return(normalizePath(hits))
  if (length(hits) > 1L)
    stop("More than one data vault found; set MIDWIFERY_VAULT to the one to use:\n  ",
         paste(hits, collapse = "\n  "), call. = FALSE)
  if (must_exist)
    stop(paste0("No data vault on this machine. Create a folder named '", VAULT_DIRNAME,
                "' in Dropbox, set it to 'available offline', or set MIDWIFERY_VAULT. ",
                "See docs/DATA_VAULT.md."), call. = FALSE)
  NA_character_
}

#' The vault file name for a given stem, hash and date
#' @param stem [character(1)] e.g. "amcb_npi_linkage_FROZEN"
#' @param sha256 [character(1)] full hex digest
#' @param date [character(1)|Date] when the file was built
#' @param ext [character(1)] extension without the dot
vault_name <- function(stem, sha256, date, ext = "csv") {
  sprintf("%s_%s_%s.%s", stem, substr(tolower(sha256), 1, 8), format(as.Date(date)), ext)
}

#' Find the vault copy of a file by its sha256, and prove it is that file
#'
#' @param stem [character(1)] the file's stem.
#' @param sha256 [character(1)] the full digest a tracked manifest records.
#' @param root [character(1)] the vault; defaults to vault_root().
#' @return [character(1)] the verified path.
vault_find <- function(stem, sha256, root = vault_root()) {
  sha256 <- tolower(sha256)
  pat <- sprintf("^%s_%s_\\d{4}-\\d{2}-\\d{2}\\.[A-Za-z0-9]+$", stem, substr(sha256, 1, 8))
  hits <- list.files(root, pattern = pat, full.names = TRUE)
  if (!length(hits))
    stop(sprintf("No %s_%s_* in the vault (%s). Publish it from the machine that has it: see docs/DATA_VAULT.md.",
                 stem, substr(sha256, 1, 8), root), call. = FALSE)
  if (length(hits) > 1L)
    stop("More than one vault file for one hash: ", paste(basename(hits), collapse = ", "), call. = FALSE)
  if (isTRUE(file.info(hits)$size == 0))
    stop(hits, " is empty -- probably an online-only placeholder. Set the vault folder to 'available offline'.",
         call. = FALSE)
  got <- digest::digest(file = hits, algo = "sha256")
  if (!identical(got, sha256))
    stop(sprintf("%s hashes to %s..., not the %s... its name claims. Do not use it; re-publish from the source.",
                 hits, substr(got, 1, 8), substr(sha256, 1, 8)), call. = FALSE)
  hits
}

#' Copy a file into the vault under its hash-bearing name
#'
#' Never overwrites. Publishing a file whose name is already taken succeeds
#' only if the existing copy is byte-identical.
#' @param path [character(1)] the local file.
#' @param stem [character(1)] its stem in the vault.
#' @param date [character(1)|Date] build date; defaults to the file's mtime.
#' @param root [character(1)] the vault.
#' @return [character(1)] the vault path, invisibly.
vault_publish <- function(path, stem, date = as.Date(file.info(path)$mtime), root = vault_root()) {
  if (!file.exists(path)) stop("no such file: ", path, call. = FALSE)
  sha <- digest::digest(file = path, algo = "sha256")
  dest <- file.path(root, vault_name(stem, sha, date, tools::file_ext(path)))
  if (file.exists(dest)) {
    if (identical(digest::digest(file = dest, algo = "sha256"), sha)) return(invisible(dest))
    stop(dest, " already exists with different contents; refusing to overwrite.", call. = FALSE)
  }
  # Already published under another date: that copy is this file if it hashes
  # the same, and a second copy would only make vault_find() ambiguous.
  same_hash <- list.files(root, pattern = sprintf("^%s_%s_", stem, substr(sha, 1, 8)), full.names = TRUE)
  same_hash <- same_hash[!endsWith(same_hash, ".partial")]
  if (length(same_hash)) {
    if (identical(digest::digest(file = same_hash[1], algo = "sha256"), sha)) return(invisible(same_hash[1]))
    stop(same_hash[1], " shares this file's hash prefix but not its contents; resolve by hand.", call. = FALSE)
  }
  tmp <- paste0(dest, ".partial")
  if (!file.copy(path, tmp, overwrite = FALSE)) stop("copy to the vault failed: ", tmp, call. = FALSE)
  if (!identical(digest::digest(file = tmp, algo = "sha256"), sha)) {
    unlink(tmp)
    stop("the vault copy does not hash like the source; removed it.", call. = FALSE)
  }
  file.rename(tmp, dest)
  invisible(dest)
}

#' The current linkage freeze: artifacts/ if it is the right file, else the vault
#'
#' @param manifest [character(1)] the tracked manifest naming the current freeze.
#' @param local [character(1)] the conventional in-repo location.
#' @return [character(1)] a path whose sha256 is the manifest's.
vault_linkage_freeze <- function(manifest = "artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json",
                                 local = "artifacts/amcb_npi_linkage_FROZEN.csv") {
  sha <- tolower(jsonlite::read_json(manifest)$artifact_sha256)
  if (file.exists(local) && identical(digest::digest(file = local, algo = "sha256"), sha)) return(local)
  vault_find("amcb_npi_linkage_FROZEN", sha)
}

#' The newest vault copy of an input no manifest pins
#'
#' For person-level inputs without a tracked manifest (practice locations, DAC
#' affiliations, ...). "Newest" is the date in the file name, not the file's
#' mtime, which sync rewrites. The caller records the chosen file's hash in its
#' output's provenance, so the choice is never invisible.
#' @param stem [character(1)]
#' @param root [character(1)]
#' @return [character(1)]
vault_latest <- function(stem, root = vault_root()) {
  pat <- sprintf("^%s_[0-9a-f]{8}_(\\d{4}-\\d{2}-\\d{2})\\.[A-Za-z0-9]+$", stem)
  hits <- list.files(root, pattern = pat)
  if (!length(hits)) stop(sprintf("No %s_* in the vault (%s).", stem, root), call. = FALSE)
  dates <- as.Date(sub(pat, "\\1", hits, perl = TRUE))
  newest <- hits[dates == max(dates)]
  if (length(newest) > 1L)
    stop("Two ", stem, " files share the newest date; pin one: ", paste(newest, collapse = ", "), call. = FALSE)
  p <- file.path(root, newest)
  if (isTRUE(file.info(p)$size == 0))
    stop(p, " is empty -- probably an online-only placeholder.", call. = FALSE)
  p
}
