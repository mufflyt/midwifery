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

#' The volume's canonical spelling, named ONCE in this repository
#'
#' tests/test_duckdb_volume_resolution.R H1/H2 forbid this literal in every
#' tracked executable file but this one, because the original incident was a
#' second drive called "MufflySamsung 1" silently answering for the first. A
#' path spelled out at a call site cannot be corrected centrally when the
#' mount is renamed, and 19 files had spelled it out -- every nightly failed on
#' H1/H2 for that reason alone.
SAMSUNG_VOLUME_CANONICAL <- "/Volumes/MufflySamsung"

#' Resolve a database on the Samsung volume, honouring an explicit override
#'
#' The sibling of samsung_volume_path() for the many scripts that read a
#' NAMED DuckDB off the volume and accept an environment variable instead.
#' Those scripts used to spell the mount path out as a Sys.getenv() default,
#' which is both the H1/H2 violation and the rename bug: a hardcoded default
#' keeps pointing at the old mount after macOS renames it.
#'
#' WHEN NOTHING IS MOUNTED THIS RETURNS A PATH, NOT NA. Callers already follow
#' it with their own `if (!file.exists(db)) stop("missing required input: ",
#' db)`, and NA there would print "missing required input: NA" -- strictly
#' worse than the hardcoded default it replaced. So the canonical location is
#' returned unresolved, the caller's existing check fails as before, and the
#' message still names somewhere a human can go and look.
#'
#' @param relative [character(1)] path below the volume root, e.g.
#'   "DuckDB/medicaid_provider_enrollment_segments.duckdb".
#' @param env_var [character(1)] environment variable checked first; "" to skip.
#' @return [character(1)] the override, the resolved path, or the canonical
#'   location when the volume is not mounted.
samsung_duckdb_path <- function(relative, env_var = "") {
  override <- if (nzchar(env_var)) Sys.getenv(env_var, "") else ""
  if (nzchar(override)) return(override)
  hit <- samsung_volume_path(relative, must_exist = FALSE)
  if (!is.na(hit)) return(hit)
  file.path(SAMSUNG_VOLUME_CANONICAL, relative)
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

#' The bootstrap's own version, stamped onto every connection it creates
#'
#' Bumped whenever `ensure_duckdb_encodings()` or `duckdb_connect()` changes
#' semantics (which extensions load, what defaults apply, what provenance is
#' recorded) -- not on every unrelated edit to this file. The point is that
#' `attr(con, "duckdb_bootstrap_version")` lets someone debugging a connection
#' three months from now answer "which bootstrap semantics made this?"
#' without having to `git blame` the whole file.
DUCKDB_BOOTSTRAP_VERSION <- "1.0.0"

#' The raw-connection exception registry and its AST scanner moved
#'
#' Both were CI-only. `DUCKDB_RAW_CONNECTION_EXCEPTIONS`,
#' `DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX` and
#' `duckdb_scan_for_raw_connections()` now live in
#' `tests/duckdb_architecture_scan.R`, sourced by the four
#' `tests/ci_duckdb_*.R` gates that are their only callers.
#'
#' WHY. The scanner was the most complex function in this repository's
#' pipeline -- cyclomatic complexity 98 over 156 lines, measured by the
#' 2026-11-20 audit -- and it has no production caller at all: it parses
#' tracked source files to police them. This file is sourced by 30-odd
#' scripts, pipeline stage 4 among them, every one of which was parsing and
#' evaluating 343 lines of gate machinery to reach `open_medicare_duckdb()`.
#' The scanner did not get simpler; it got out of the way.
#'
#' The runtime chokepoint it polices is unchanged and still lives here:
#' `duckdb_connect()`, `open_medicare_duckdb()`, `ensure_duckdb_encodings()`.
#' @name duckdb_raw_connection_registry_moved
NULL

#' Structured probe of DuckDB encoding-bootstrap capability on this connection
#'
#' TESTS SHOULD ASSERT ON THIS, NOT PARSE LOG STRINGS. `ensure_duckdb_encodings()`
#' logs for a human; this returns a plain list for a test. The two are kept in
#' sync by `ensure_duckdb_encodings()` calling this function internally rather
#' than duplicating the probing logic.
#'
#' @param con a DBI connection to a DuckDB database.
#' @return a `list` with:
#'   - `dependency_present` [logical]: is the `encodings` extension installed
#'     (regardless of whether it is currently loaded)?
#'   - `dependency_loadable` [logical]: does `LOAD encodings` succeed?
#'   - `required_encoding_support_available` [logical]: can this connection
#'     actually decode CP1252 right now (the property that matters --
#'     `dependency_loadable` could in principle be TRUE while a future DuckDB
#'     release renamed the encoding identifier, which is exactly the kind of
#'     drift a string-only check would miss).
#'   - `bootstrap_action_taken` [character]: one of `"none"` (already loaded),
#'     `"loaded"` (was installed, just needed LOAD), or `"installed_and_loaded"`
#'     (had to INSTALL first).
duckdb_encoding_capability <- function(con) {
  loadable <- tryCatch({
    DBI::dbExecute(con, "LOAD encodings")
    TRUE
  }, error = function(e) FALSE)

  installed_list <- tryCatch(
    DBI::dbGetQuery(con, "SELECT extension_name, installed FROM duckdb_extensions() WHERE extension_name = 'encodings'"),
    error = function(e) NULL)
  present <- isTRUE(loadable) || (!is.null(installed_list) && nrow(installed_list) > 0 && isTRUE(installed_list$installed[1]))

  # decode(BLOB, VARCHAR) -> VARCHAR is the encodings extension's real
  # signature; encode() takes exactly one argument (always UTF-8 in), so a
  # pure-ASCII string round-trips through any correctly-loaded encoding.
  cp1252_ok <- if (loadable) {
    tryCatch({
      r <- DBI::dbGetQuery(con, "SELECT decode(encode('test'), 'CP1252') AS ok")
      isTRUE(nrow(r) == 1) && isTRUE(r$ok[1] == "test")
    }, error = function(e) FALSE)
  } else FALSE

  list(dependency_present = present,
       dependency_loadable = isTRUE(loadable),
       required_encoding_support_available = isTRUE(loadable) && isTRUE(cp1252_ok),
       bootstrap_action_taken = "none")  # overwritten by ensure_duckdb_encodings() when it actually acts
}


#' Ensure the DuckDB `encodings` extension is loaded on this connection
#'
#' CANONICAL CSV-INGESTION BOOTSTRAP. Every DuckDB connection in this repo
#' that might read an externally-sourced CSV must call this (indirectly, via
#' `duckdb_connect()`) before any `read_csv()` / `read_csv_auto()` call. It
#' exists because a CMS PECOS extract silently lost 10 real enrollment records
#' -- including two accented/curly-quote names -- to `ignore_errors = TRUE`
#' before this was written: the file was Windows-1252, not UTF-8 or Latin-1,
#' and DuckDB's built-in reader only knows utf-8/utf-16/latin-1. See
#' `docs/TECHNICAL_APPENDIX_CSV_INGESTION_ENCODING.md`.
#'
#' INSTALL is an environment/setup concern (fetches and caches the extension
#' binary; wants to happen once per machine); LOAD is a per-session concern
#' (cheap, must happen on every connection that might touch a CSV). This
#' function does both, in that order, so a fresh machine is self-healing, but
#' only ever logs the (slower, one-time) INSTALL step -- LOAD is silent on
#' every ordinary call so this does not become log noise.
#'
#' FAIL-CLOSED CONTROL. "0"/"false"/"no" (case-insensitive) refuses to
#' INSTALL a missing extension; "1"/unset (the default) allows the
#' install-then-load fallback. This exists so CI (or any environment with a
#' no-network policy) can distinguish three failure classes that
#' `ignore_errors = TRUE`-style tolerance used to conflate: a CODE defect
#' (wrong SQL), a DEPENDENCY/bootstrap defect (extension genuinely missing,
#' but installable), and a NETWORK/install defect (installable in principle,
#' but this environment won't allow the attempt). Only the third should ever
#' produce this specific "fail closed" error.
DUCKDB_BOOTSTRAP_ALLOW_INSTALL_VAR <- "DUCKDB_BOOTSTRAP_ALLOW_INSTALL"

#' @param con a DBI connection to a DuckDB database.
#' @param quiet [logical] suppress the one-time "installing" message.
#' @return the result of `duckdb_encoding_capability(con)`, invisibly, with
#'   `bootstrap_action_taken` set to what actually happened on this call
#'   (`"none"`, `"loaded"`, or `"installed_and_loaded"`). Tests should assert
#'   on this returned list, not on log text -- logging is for a human
#'   debugging a session, not the contract this function guarantees.
ensure_duckdb_encodings <- function(con, quiet = FALSE) {
  probe <- duckdb_encoding_capability(con)
  if (probe$required_encoding_support_available) {
    probe$bootstrap_action_taken <- "none"
    return(invisible(probe))
  }

  allow_install <- tolower(trimws(Sys.getenv(DUCKDB_BOOTSTRAP_ALLOW_INSTALL_VAR, "1")))
  if (allow_install %in% c("0", "false", "no")) {
    stop(sprintf(paste0(
      "ensure_duckdb_encodings(): the 'encodings' extension is not loadable ",
      "on this connection, and %s=%s forbids installing it (fail-closed mode).\n",
      "  This is a DEPENDENCY/bootstrap defect, not a code defect: the fix is ",
      "to pre-install the extension on this machine/image (`INSTALL encodings;` ",
      "once, with network access), or set %s=1 to allow this call to install ",
      "it itself.\n  Missing capability: CP1252 (and other non-UTF-8) CSV ",
      "decoding -- see docs/TECHNICAL_APPENDIX_CSV_INGESTION_ENCODING.md."),
      DUCKDB_BOOTSTRAP_ALLOW_INSTALL_VAR, allow_install,
      DUCKDB_BOOTSTRAP_ALLOW_INSTALL_VAR), call. = FALSE)
  }

  if (!quiet) message("ensure_duckdb_encodings(): 'encodings' extension not ",
                      "yet installed on this machine -- installing now ",
                      "(one-time; cached for future sessions).")
  DBI::dbExecute(con, "INSTALL encodings")
  DBI::dbExecute(con, "LOAD encodings")

  probe2 <- duckdb_encoding_capability(con)
  probe2$bootstrap_action_taken <- if (probe$dependency_present) "loaded" else "installed_and_loaded"
  if (!probe2$required_encoding_support_available)
    stop(paste0("ensure_duckdb_encodings(): installed and loaded 'encodings', ",
                "but CP1252 decoding still does not work on this connection. ",
                "This is a code/version defect, not a missing-dependency one -- ",
                "do not silently proceed."), call. = FALSE)
  invisible(probe2)
}

#' Open a DuckDB connection with the CSV-ingestion bootstrap applied
#'
#' THE SINGLE CHOKE POINT. Every `dbConnect(duckdb::duckdb(), ...)` call in
#' this repo -- against the shared warehouse, a geocoding cache, or a bare
#' in-memory database for `read_csv_auto()` + `duckdb_register()` work --
#' should be this function instead. Signature-compatible with
#' `DBI::dbConnect(duckdb::duckdb(), dbdir, read_only, ...)`, so the
#' migration at every call site is mechanical: drop the nested
#' `duckdb::duckdb()` driver construction and call this directly.
#'
#' `tests/ci_duckdb_ingestion_bootstrap.R` enforces that no script bypasses
#' this: it is a ratchet over an explicit allowlist of not-yet-migrated call
#' sites, and that list may only shrink.
#'
#' CONTRACT (see docs/TECHNICAL_APPENDIX_DUCKDB_BOOTSTRAP_ARCHITECTURE.md
#' for the machine-checked version of this list, `tests/ci_duckdb_connection_contract.R`):
#'   - backend: always DuckDB (`duckdb::duckdb()`); not configurable, on purpose.
#'   - path semantics: `dbdir` is passed through to `DBI::dbConnect` unchanged
#'     -- ":memory:" (default) or an explicit path are both explicit and
#'     reproducible; this function never guesses or rewrites a path.
#'   - read_only: preserved exactly as passed; default FALSE matches
#'     `DBI::dbConnect`'s own default, not `open_medicare_duckdb()`'s
#'     read-only-by-default policy (that policy lives one layer up, in the
#'     domain-specific opener, not here).
#'   - config/options: anything in `...` is forwarded verbatim to
#'     `DBI::dbConnect`; this function adds no options of its own beyond the
#'     encodings bootstrap.
#'   - extensions: `encodings` is guaranteed loaded (or this call errors --
#'     see `ensure_duckdb_encodings()`'s fail-closed mode). No other
#'     extension is installed or loaded here.
#'   - temp_directory / threads / memory: UNSPECIFIED. This function does not
#'     set DuckDB's `temp_directory`, `threads`, or `memory_limit` PRAGMAs;
#'     whatever DuckDB's own defaults are for the running version apply,
#'     unchanged. Documented here as unspecified rather than left to become
#'     an accidental, undocumented behavior.
#'   - disconnect: the caller owns the connection and must `DBI::dbDisconnect()`
#'     it; this function does not register it anywhere or track it for later
#'     cleanup (see "no hidden state" below).
#'   - independence / no hidden state: each call returns a genuinely new
#'     connection object with its own DuckDB instance state. This function
#'     caches nothing across calls -- no shared handle, no shared
#'     configuration object, no package-level environment mutated as a side
#'     effect. Two connections from two calls (even to the same `dbdir`) do
#'     not share temp tables, session-scoped settings, or transactions;
#'     disconnecting one has no effect on the other. See
#'     `tests/ci_duckdb_connection_contract.R` §"independence".
#'
#' @param dbdir [character] path to the database, or ":memory:" (the
#'   `DBI::dbConnect` default) for a fresh in-memory database.
#' @param read_only [logical] default FALSE, matching `DBI::dbConnect`.
#' @param ... passed through to `DBI::dbConnect`.
#' @return a DBI connection with the `encodings` extension already loaded and
#'   `attr(., "duckdb_bootstrap_version")` / `attr(., "duckdb_bootstrap_action")`
#'   set for provenance (see `duckdb_connection_provenance()`).
#' Create the spill directory DuckDB has already been told to use
#'
#' FAILS ONLY ON BIG QUERIES, WHICH IS WHY IT SURVIVED THIS LONG. The duckdb R
#' package points `temp_directory` at `<tempdir()>/duckdb/temp` but never
#' creates it, and DuckDB itself does not create the parent chain. A query
#' small enough to stay in memory never touches the path, so an interactive
#' probe and every modest extract look healthy; a query large enough to spill
#' aborts with `IO Error: Failed to create directory ... No such file or
#' directory`. That is how the 2025 Open Payments extract (a 9.2 GB scan)
#' failed on 2026-11-15 while the 2015-2023 warehouse extracts in the same
#' session succeeded.
#'
#' Creating it here, in the one bootstrap every script already routes through,
#' fixes it for all callers rather than per-script. Deliberately best-effort:
#' if the directory cannot be made, this returns FALSE and leaves the
#' connection usable, so a caller whose query never spills is not blocked by a
#' directory it would not have used.
#'
#' @param con [DBI connection] an open DuckDB connection.
#' @return [logical] invisibly, TRUE when the spill directory exists
#'   afterwards, FALSE when it could not be created or determined.
ensure_duckdb_temp_directory <- function(con) {
  spill_dir <- tryCatch(
    DBI::dbGetQuery(con, "SELECT current_setting('temp_directory') AS td")$td,
    error = function(e) NULL)
  if (!length(spill_dir) || is.na(spill_dir[1]) || !nzchar(spill_dir[1])) {
    base::message("duckdb_connect(): no temp_directory reported; ",
                  "leaving spill configuration untouched")
    return(invisible(FALSE))
  }
  if (dir.exists(spill_dir[1])) return(invisible(TRUE))
  made <- dir.create(spill_dir[1], recursive = TRUE, showWarnings = FALSE)
  if (made) {
    base::message("duckdb_connect(): created DuckDB spill directory ",
                  spill_dir[1])
  } else {
    base::message("duckdb_connect(): could NOT create DuckDB spill directory ",
                  spill_dir[1], " -- a query large enough to spill will fail")
  }
  invisible(dir.exists(spill_dir[1]))
}

duckdb_connect <- function(dbdir = ":memory:", read_only = FALSE, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)  # duckdb-exception: bootstrap-definition
  ensure_duckdb_temp_directory(con)
  probe <- ensure_duckdb_encodings(con, quiet = TRUE)
  attr(con, "duckdb_bootstrap_version") <- DUCKDB_BOOTSTRAP_VERSION
  attr(con, "duckdb_bootstrap_action") <- probe$bootstrap_action_taken
  con
}

#' Report which bootstrap semantics created a connection
#'
#' PROVENANCE, NOT INFERENCE. Reads the attributes `duckdb_connect()` stamped
#' at creation time; does not attempt to reconstruct them by re-probing the
#' connection, because a connection's live state (e.g. whether `encodings`
#' happens to still be loaded) can drift after creation in ways that say
#' nothing about which bootstrap version actually created it.
#'
#' @param con a DBI connection.
#' @return a `list(bootstrap_version, bootstrap_action)`, or a list of NAs
#'   with a warning if `con` was not created by `duckdb_connect()` (e.g. the
#'   one legitimate raw connection inside `duckdb_connect()` itself, or a
#'   connection from an allowlisted exception).
duckdb_connection_provenance <- function(con) {
  v <- attr(con, "duckdb_bootstrap_version")
  a <- attr(con, "duckdb_bootstrap_action")
  if (is.null(v)) {
    warning("duckdb_connection_provenance(): this connection carries no ",
            "bootstrap provenance -- it was not created by duckdb_connect().",
            call. = FALSE)
    return(list(bootstrap_version = NA_character_, bootstrap_action = NA_character_))
  }
  list(bootstrap_version = v, bootstrap_action = a)
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
  con <- duckdb_connect(dbdir = p, read_only = read_only)
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
