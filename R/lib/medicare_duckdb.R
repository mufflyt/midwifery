# =============================================================================
# Find the warehouse without caring what macOS decided to call the volume
# =============================================================================
# macOS leaves a stale mount point in /Volumes after an unclean unmount and then
# mounts the real disk with " 1" appended. So the SAME drive is
# /Volumes/MufflySamsung on one boot and /Volumes/MufflySamsung 1 on the next,
# and nothing in the repo controls which.
#
# Eight scripts here hardcoded the first spelling. The volume is currently the
# second. That would be a trivial bug except for what DuckDB does with a path
# that does not exist: dbConnect() CREATES the database. So the failure is not
# an error, it is a 12 KB empty warehouse, zero rows from every query, and a run
# that reports success having measured nothing.
#
# That already happened. Both files exist on the volume right now:
#
#   /Volumes/MufflySamsung 1/DuckDB/nber_my_duckdb.duckdb   84.3 GB, 454 tables
#   /Volumes/MufflySamsung 1/nber_my_duckdb.duckdb           12 KB,   0 tables
#
# The second is the wreckage of exactly this mistake. An audit run against it
# finds no disagreements -- and that reads as a clean result, not a broken one.
#
# The fix is not to rename the disk. It is for discovery to be a glob over
# MufflySamsung*, for a candidate to have to LOOK like the real warehouse before
# it is accepted, and for anything ambiguous to stop loudly.
#
# DISCOVERY NEVER CREATES OR MODIFIES A CANDIDATE. resolve_*() touches the
# filesystem only through Sys.glob() and file.info(); it never opens a database.
# Connections are read-only unless a caller deliberately asks otherwise.
# =============================================================================

#' Resolve any path on the Samsung volume, whatever macOS called it
#'
#' The warehouse is not the only thing on that drive: facility-affiliation
#' extracts, NPPES downloads and isochrone runs are all addressed the same way
#' and break the same way on a rename. Those fail loudly (file not found) rather
#' than silently, which is why they were less urgent -- but they are the same
#' bug and there is no reason to keep two conventions.
#'
#' @param relative [character] path below the volume root, e.g.
#'   "nppes_historical_downloads/august_2026".
#' @param must_exist [logical] stop when nothing matches.
#' @return [character] the resolved absolute path, or NA when absent and
#'   must_exist is FALSE.
samsung_volume_path <- function(relative, must_exist = TRUE) {
  hits <- Sys.glob(file.path("/Volumes/MufflySamsung*", relative))
  hits <- hits[file.exists(hits)]
  if (length(hits) == 1L) return(hits)
  if (length(hits) > 1L)
    stop(sprintf(paste("%s matches %d mounted volumes:\n  %s\n  Guessing would",
                       "silently pick one drive's data over another's."),
                 relative, length(hits), paste(hits, collapse = "\n  ")),
         call. = FALSE)
  if (must_exist)
    stop(sprintf(paste("%s not found under any /Volumes/MufflySamsung* mount.\n",
                       " Mount the drive, or pass an explicit path."), relative),
         call. = FALSE)
  NA_character_
}

#' Where the warehouse might be, whatever macOS called the volume today
DUCKDB_GLOB_DEFAULT <- "/Volumes/MufflySamsung*/DuckDB/nber_my_duckdb.duckdb"

#' Smallest plausible size for the real warehouse
#'
#' The production database is tens of GB. Anything under a gigabyte is a
#' mistakenly-created DuckDB at a wrong mount path, which is the failure this
#' whole file exists to prevent.
DUCKDB_MIN_BYTES <- 1e9

#' Resolve the one real warehouse path, or stop
#'
#' @param glob [character] pattern(s) to search. Parameterised so the resolver
#'   can be exercised against fixtures rather than the live volume.
#' @param env_var [character] environment variable checked first.
#' @param min_bytes [numeric] size floor for a plausible candidate.
#' @param quiet [logical] suppress the resolved-path message.
#' @return [character] a single existing, plausible path.
#' The ONE environment variable that controls the warehouse
#'
#' MEDICARE_DUCKDB, because the warehouse is shared infrastructure rather than
#' a midwifery-specific asset. MIDWIFERY_DUCKDB is a DEPRECATED alias, honoured
#' only so an existing shell profile does not silently stop working; it warns.
#' Two live variables would mean nobody could tell which one was in force.
DUCKDB_ENV_VAR <- "MEDICARE_DUCKDB"
DUCKDB_ENV_VAR_DEPRECATED <- "MIDWIFERY_DUCKDB"

resolve_midwifery_duckdb <- function(glob = DUCKDB_GLOB_DEFAULT,
                                     env_var = DUCKDB_ENV_VAR,
                                     min_bytes = DUCKDB_MIN_BYTES,
                                     quiet = FALSE) {
  # An explicit override is honoured, but is NOT exempt from existing. Pointing
  # at a missing file is the original bug; accepting it here would reintroduce
  # it for anyone who sets the variable.
  override <- if (nzchar(env_var)) Sys.getenv(env_var, "") else ""
  if (!nzchar(override) && nzchar(env_var)) {
    dep <- Sys.getenv(DUCKDB_ENV_VAR_DEPRECATED, "")
    if (nzchar(dep)) {
      warning(sprintf("%s is deprecated; use %s. Honouring it this once.",
                      DUCKDB_ENV_VAR_DEPRECATED, DUCKDB_ENV_VAR), call. = FALSE)
      override <- dep
    }
  }
  if (nzchar(override)) {
    if (!file.exists(override))
      stop(sprintf(paste("%s points at a file that does not exist:\n  %s\n",
                         " Refusing to continue -- dbConnect() would CREATE an",
                         "empty database there and every query would return",
                         "zero rows."), env_var, override), call. = FALSE)
    if (!quiet) message("Resolved midwifery DuckDB (from ", env_var, "): ", override)
    return(override)
  }

  cand <- unique(unlist(lapply(glob, Sys.glob)))
  cand <- cand[file.exists(cand)]
  if (!quiet) message("DuckDB candidates found: ", length(cand))
  if (!length(cand))
    stop(paste0("no warehouse found matching:\n  ", paste(glob, collapse = "\n  "),
                "\n  Mount the volume or set ", env_var, ".\n",
                "  Refusing to fall back to a hardcoded path, which is how an",
                " empty database gets created."), call. = FALSE)

  sz <- file.info(cand)$size
  plausible <- cand[!is.na(sz) & sz >= min_bytes]
  if (!quiet) message("Plausible after size validation: ", length(plausible))

  if (length(plausible) != 1L) {
    gb <- if (length(sz)) sz / 1e9 else rep(NA_real_, length(cand))
    detail <- paste(sprintf("%s (%.1f GB)", cand, gb), collapse = "\n  ")
    stop(sprintf(paste("expected exactly ONE plausible warehouse, found %d.\n",
                       " Candidates:\n  %s\n  Set %s to choose deliberately.",
                       "Guessing between them is how the wrong one gets used."),
                 length(plausible), detail, env_var), call. = FALSE)
  }
  if (!quiet) message("Resolved midwifery DuckDB: ", plausible)
  plausible
}

#' Open the warehouse read-only, asserting the tables the caller needs
#'
#' A table that exists but is EMPTY is treated as missing. An empty npi_org_all
#' is the signature of the decoy database, and a caller that proceeds from it
#' produces a confident answer about nothing.
#'
#' @param required_tables [character] must exist and be non-empty.
#' @param path [character] optional explicit path, else resolved.
#' @param read_only [logical] TRUE. Set FALSE only to deliberately write.
#' @return a DBI connection; the caller must dbDisconnect().
open_medicare_duckdb <- function(required_tables = character(), path = NULL,
                                 read_only = TRUE) {
  p <- if (is.null(path)) resolve_midwifery_duckdb() else path
  if (!file.exists(p))
    stop(sprintf("refusing to open a warehouse that does not exist: %s", p),
         call. = FALSE)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = p, read_only = read_only)
  ok <- FALSE
  on.exit(if (!ok) try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)

  have <- DBI::dbListTables(con)
  missing <- setdiff(required_tables, have)
  if (length(missing))
    stop(sprintf(paste("%s has %d table(s) but not: %s\n",
                       " This is the wrong database."),
                 p, length(have), paste(missing, collapse = ", ")), call. = FALSE)
  for (tb in required_tables) {
    n <- DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", tb))$n
    if (!length(n) || is.na(n) || n == 0L)
      stop(sprintf(paste("%s in %s is EMPTY.\n  An empty table is treated as a",
                         "missing one: a run over it reports zero findings and",
                         "looks like a clean result."), tb, p), call. = FALSE)
  }
  ok <- TRUE
  con
}
