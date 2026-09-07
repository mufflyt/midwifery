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

#' The bootstrap's own version, stamped onto every connection it creates
#'
#' Bumped whenever `ensure_duckdb_encodings()` or `duckdb_connect()` changes
#' semantics (which extensions load, what defaults apply, what provenance is
#' recorded) -- not on every unrelated edit to this file. The point is that
#' `attr(con, "duckdb_bootstrap_version")` lets someone debugging a connection
#' three months from now answer "which bootstrap semantics made this?"
#' without having to `git blame` the whole file.
DUCKDB_BOOTSTRAP_VERSION <- "1.0.0"

#' The ONLY sanctioned exceptions to "every connection goes through duckdb_connect()"
#'
#' A STRUCTURED REGISTRY, not an inline vector in a test file, and SITE-LEVEL,
#' not file-level. An earlier version of this registry matched by file alone:
#' any raw connection anywhere in a registered file was silently exempt. That
#' had a real, live gap -- `tests/ci_duckdb_mutation_tests.R` was never listed
#' at all, and its three raw connections (M6/M7/M8's mutated re-implementations
#' of `duckdb_connect()`, which must construct a raw connection to simulate a
#' broken one) went undetected until this registry was rebuilt to check every
#' tracked file's ACTUAL scan output against it directly. A file-level entry
#' would also have silently exempted any NEW, unrelated raw connection added
#' later to an already-registered file. Both gaps close the same way: an
#' entry now names one exact site via a `# duckdb-exception: <tag>` comment at
#' that call site (see `duckdb_scan_for_raw_connections()`), and only a site
#' actually carrying the matching tag is exempt -- not its whole file.
#'
#' `tests/ci_duckdb_ingestion_bootstrap.R` asserts both directions: every
#' tagged raw-connection site found by the scanner is either registered here
#' or fails CI, and every entry here still corresponds to a real, live tagged
#' site (a tag whose site was edited away, or whose comment was dropped, is
#' stale cover and fails too). The registry can shrink freely; growing it
#' means editing this object, in the open, with a reason.
#'
#' @format A list of records, each:
#'   `list(file, tag, locator, reason, exception_class, owner, added_date, removal_condition)`
#'   - `tag`: matches the `# duckdb-exception: <tag>` comment at the exact
#'     call site (see the scanner's `tag` column).
#'   - `locator`: human-readable pointer to the function/mutation the site
#'     lives in, since raw line numbers drift with unrelated edits.
#'   - `exception_class`: one of `"definitional"` (is the chokepoint itself),
#'     `"test-baseline"` (a deliberate raw connection used as a comparison
#'     baseline), `"negative-control"` (deliberately reproduces a defect),
#'     `"mutation-harness"` (simulates a broken re-implementation), or
#'     `"synthetic-fixture"` (no CSV/encoding hazard exists on this connection
#'     at all).
#'   - `added_date`: when the exception was registered (ISO date string).
#'   - `removal_condition`: what would make this entry stale (see
#'     `expiry_condition`'s successor name -- kept as one field, renamed for
#'     clarity of intent).
DUCKDB_RAW_CONNECTION_EXCEPTIONS <- list(
  list(file = "R/lib/medicare_duckdb.R",
       tag = "bootstrap-definition",
       locator = "duckdb_connect()",
       reason = "This file IS the chokepoint's own definition of duckdb_connect(); it necessarily contains the one real DBI::dbConnect(duckdb::duckdb()) call in the repo.",
       exception_class = "definitional",
       owner = "medicare_duckdb.R maintainer",
       added_date = "2026-09-07",
       removal_condition = "Never -- this is definitional, not a bypass."),
  list(file = "tests/test_cache_vintage_declared.R",
       tag = "synthetic-fixture",
       locator = "mk_cache()",
       reason = "Writes a synthetic fixture directly via dbWriteTable() on an in-memory R data frame. No CSV is ever read on this connection, so there is no encoding hazard to bootstrap against.",
       exception_class = "synthetic-fixture",
       owner = "cache-vintage test maintainer",
       added_date = "2026-09-07",
       removal_condition = "If this test is ever changed to read_csv/read_csv_auto an external file, remove this entry and migrate to duckdb_connect()."),
  list(file = "tests/ci_duckdb_ingestion_bootstrap.R",
       tag = "legacy-defect-control",
       locator = "legacy pattern reproduction (legacy_con)",
       reason = "Deliberately constructs a raw, unbootstrapped connection (ignore_errors=TRUE, no encoding requested) as a negative control proving the ORIGINAL PECOS defect is reproducible without duckdb_connect() -- this is the test demonstrating the bug this whole system fixes, not a bypass of it.",
       exception_class = "negative-control",
       owner = "DuckDB bootstrap architecture maintainer",
       added_date = "2026-09-07",
       removal_condition = "If the legacy-reproduction negative control is ever removed from this file, remove this entry too."),
  list(file = "tests/ci_duckdb_connection_contract.R",
       tag = "raw-baseline-defaults",
       locator = "raw_con (UNSPECIFIED-defaults comparison baseline)",
       reason = "Deliberately constructs a raw connection as the comparison baseline for the 'threads/memory are UNSPECIFIED and match DuckDB's own default' contract assertion -- proving duckdb_connect() does not silently diverge from a raw connection's defaults requires an actual raw connection to compare against.",
       exception_class = "test-baseline",
       owner = "DuckDB bootstrap architecture maintainer",
       added_date = "2026-09-07",
       removal_condition = "If the raw-vs-bootstrapped default-comparison assertion is ever removed from this file, remove this entry too."),
  list(file = "tests/ci_duckdb_mutation_tests.R",
       tag = "mutation-m6",
       locator = "M6: e6$duckdb_connect() (cached/shared-connection mutation)",
       reason = "M6 simulates a duckdb_connect() that caches and shares one connection across calls, to prove the independence assertion catches it. Simulating that mutation requires actually constructing a raw connection -- there is nothing to route through the real duckdb_connect() here, since this code IS a stand-in for a broken one.",
       exception_class = "mutation-harness",
       owner = "DuckDB bootstrap architecture maintainer",
       added_date = "2026-09-07",
       removal_condition = "If mutation M6 is ever removed from this file, remove this entry too."),
  list(file = "tests/ci_duckdb_mutation_tests.R",
       tag = "mutation-m7",
       locator = "M7: e7$duckdb_connect() (dropped read_only forwarding mutation)",
       reason = "M7 simulates a duckdb_connect() that ignores the caller's read_only argument, to prove the read-only contract assertion catches it. Same reasoning as M6: the mutation IS a raw-connection re-implementation by construction.",
       exception_class = "mutation-harness",
       owner = "DuckDB bootstrap architecture maintainer",
       added_date = "2026-09-07",
       removal_condition = "If mutation M7 is ever removed from this file, remove this entry too."),
  list(file = "tests/ci_duckdb_mutation_tests.R",
       tag = "mutation-m8",
       locator = "M8: e8$duckdb_connect() (dropped provenance attrs mutation)",
       reason = "M8 simulates a duckdb_connect() that omits the provenance attributes, to prove duckdb_connection_provenance() actually reads what the real function sets rather than always reporting present. Same reasoning as M6/M7.",
       exception_class = "mutation-harness",
       owner = "DuckDB bootstrap architecture maintainer",
       added_date = "2026-09-07",
       removal_condition = "If mutation M8 is ever removed from this file, remove this entry too.")
  # tests/test_cache_vintage_detect.R was in this registry under the regex-based
  # scanner (duckdb_scan_for_raw_connections()'s predecessor), which matched the
  # pattern inside a STRING LITERAL the test builds as example output text. The
  # AST-based scanner correctly does not flag it at all -- it never executes a
  # real connection -- so the entry was removed rather than left as stale cover
  # once the file it was protecting stopped needing protection.
)

#' Explicit upper bound on how many exception-registry entries may exist
#'
#' Not a hard ceiling that blocks a legitimately justified new entry forever
#' -- it is a speed bump: raising it requires a conscious edit to this
#' constant, right next to the registry it bounds, so the registry cannot
#' quietly grow one entry at a time without anyone having to look at the
#' total. Current count: 7 real, distinct call sites, each with a specific,
#' named reason and owner (see DUCKDB_RAW_CONNECTION_EXCEPTIONS's docstring
#' for how the count of 4 in an earlier version of this file undercounted --
#' it was file-level, and missed three sites in a file that was never listed
#' at all).
DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX <- 7L

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

#' AST-based scan for raw DuckDB connection construction
#'
#' STRUCTURAL, NOT TEXTUAL. Walks each file's actual parse tree (via
#' `parse(path, keep.source = TRUE)` and recursive descent over call nodes),
#' rather than pattern-matching source text. This survives what a regex
#' ratchet does not: a `dbConnect()` call broken across multiple lines, an
#' argument passed by name (`drv = duckdb::duckdb()`) instead of
#' positionally, and any reformatting that changes whitespace without
#' changing meaning.
#'
#' LIMITED ALIAS RESOLUTION -- documented boundary, not a claim of full
#' coverage. A single, static, unconditional assignment of a bare driver
#' reference to a name -- `con_fun <- duckdb::duckdb` / `con_fun <- duckdb`,
#' anywhere in the file -- is tracked, and any later call through that name
#' (`con_fun()`, or `con_fun()` passed as `dbConnect()`'s driver argument) is
#' flagged exactly as if the literal `duckdb::duckdb()` text were there. This
#' closes the specific evasion where the driver constructor is referenced,
#' not invoked, at the point of aliasing.
#'
#' What this does NOT resolve: conditional or reassigned bindings (`if (x)
#' f <- duckdb::duckdb else f <- something_else`), `assign()`/`get()`
#' indirection, aliasing `dbConnect` itself combined with a driver built by
#' some other non-literal mechanism, cross-file aliasing, or dynamic
#' dispatch. Full symbolic/points-to analysis across a whole codebase is a
#' much larger undertaking than this repo's actual risk profile justifies,
#' and the project's own convention (call `dbConnect`/`DBI::dbConnect`
#' directly, never rebind it) makes that residual gap low-cost. This is
#' "closes the obvious evasions," not "provably exhaustive" -- and the
#' mutation suite (`tests/ci_duckdb_mutation_tests.R`, M9/M10) exercises
#' exactly the boundary this paragraph describes.
#'
#' @param files [character] paths to scan.
#' @return a `data.frame(file, line, tag, symbol)`, one row per raw
#'   connection construction found; zero rows if none. `line` is the
#'   enclosing top-level statement's first line (nested calls do not
#'   reliably carry their own srcref in R), which is sufficient to locate
#'   the offending statement even when it is not the exact sub-expression
#'   line. `tag` is the site-level exception marker (`NA` if absent) -- see
#'   `DUCKDB_RAW_CONNECTION_EXCEPTIONS`'s docstring for how it is matched.
duckdb_scan_for_raw_connections <- function(files) {
  callee_name <- function(call_node) {
    fn <- call_node[[1]]
    if (is.symbol(fn)) return(as.character(fn))
    if (is.call(fn) && length(fn) == 3 && identical(fn[[1]], as.symbol("::")))
      return(paste0(as.character(fn[[2]]), "::", as.character(fn[[3]])))
    NA_character_
  }
  is_bare_duckdb_driver_call <- function(node) {
    is.call(node) && callee_name(node) %in% c("duckdb", "duckdb::duckdb")
  }
  # A REFERENCE to the driver constructor that is NOT itself invoked -- the
  # RHS of `x <- duckdb::duckdb` or `x <- duckdb` (no parens). Distinct from
  # is_bare_duckdb_driver_call(), which matches an actual invocation. This
  # exists to close one specific evasion: `con_fun <- duckdb::duckdb;
  # con_fun()` never contains the literal text `duckdb::duckdb()` anywhere,
  # so the standalone-call rule below has nothing to match against it.
  is_bare_duckdb_driver_ref <- function(node) {
    if (is.symbol(node)) return(identical(as.character(node), "duckdb"))
    if (is.call(node) && length(node) == 3 && identical(node[[1]], as.symbol("::")))
      return(identical(paste0(as.character(node[[2]]), "::", as.character(node[[3]])),
                        "duckdb::duckdb"))
    FALSE
  }
  # R's call trees carry a special "empty symbol" for omitted arguments (the
  # blank in `df[, "col"]`, or in `alist()`-style formals). It is not safely
  # indexable or bindable by ordinary means -- even a `for` loop's own
  # element-binding step can raise "argument is missing" on it before any
  # check in the loop body runs. Rather than trying to out-guess every
  # language-object edge case this can appear in, each recursive step is
  # wrapped defensively: a node this scanner cannot safely descend into is
  # skipped, not fatal. This trades a theoretical blind spot (an unreachable
  # dbConnect() nested inside a construct so unusual it cannot be walked) for
  # practical robustness across arbitrary real-world R source -- an explicit,
  # documented "where practical" limit, consistent with this function's
  # stated scope.
  walk_calls <- function(node, visit) {
    tryCatch({
      if (is.call(node)) {
        visit(node)
        n <- length(node)
        if (n >= 2) for (i in 2:n) tryCatch(walk_calls(node[[i]], visit), error = function(e) invisible(NULL))
      } else if (is.pairlist(node) || is.list(node)) {
        n <- length(node)
        if (n >= 1) for (i in 1:n) tryCatch(walk_calls(node[[i]], visit), error = function(e) invisible(NULL))
      }
    }, error = function(e) invisible(NULL))
  }

  # PASS 1: collect simple single-assignment aliases of the bare driver
  # reference, anywhere in the file -- `x <- duckdb::duckdb` / `x <- duckdb`
  # (no parens: a REFERENCE, not a call). This closes the specific evasion
  # `con_fun <- duckdb::duckdb; con_fun()`, where the literal driver-call
  # text `duckdb::duckdb()` never appears anywhere for the standalone-call
  # rule below to find. Deliberately narrow -- a single static assignment
  # of a bare name, anywhere in the file -- not conditional reassignment,
  # not cross-file, not assign()/get(), not S4/R6 dispatch. Full points-to
  # analysis is out of scope for this repo's actual risk profile (see this
  # function's docstring); this closes the obvious evasion, not all of them.
  collect_driver_aliases <- function(top_list) {
    aliases <- character(0)
    visit <- function(node) {
      tryCatch({
        if (is.call(node) && length(node) == 3 &&
            (identical(node[[1]], as.symbol("<-")) || identical(node[[1]], as.symbol("=")))) {
          target <- node[[2]]; rhs <- node[[3]]
          if (is.symbol(target) && is_bare_duckdb_driver_ref(rhs))
            aliases <<- c(aliases, as.character(target))
        }
        if (is.call(node)) {
          n <- length(node)
          if (n >= 2) for (i in 2:n) tryCatch(visit(node[[i]]), error = function(e) invisible(NULL))
        } else if (is.pairlist(node) || is.list(node)) {
          n <- length(node)
          if (n >= 1) for (i in 1:n) tryCatch(visit(node[[i]]), error = function(e) invisible(NULL))
        }
      }, error = function(e) invisible(NULL))
    }
    for (i in seq_along(top_list)) visit(top_list[[i]])
    unique(aliases)
  }

  out <- lapply(files, function(path) {
    exprs <- tryCatch(parse(path, keep.source = TRUE), error = function(e) NULL)
    if (is.null(exprs)) return(NULL)
    top_srcrefs <- attr(exprs, "srcref")
    top_list <- as.list(exprs)
    aliased_driver_names <- collect_driver_aliases(top_list)
    # Raw file lines, read once, for tag lookup below. `as.character()` on a
    # srcref reconstructs only the parsed expression's OWN token span, which
    # excludes a trailing same-line comment (`x <- 1  # tag` loses "# tag"
    # entirely) -- reading the real lines by the srcref's line range sidesteps
    # that and sees exactly what a human reading the file would see.
    raw_lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
    hits <- list()
    for (i in seq_along(top_list)) {
      stmt_line <- if (!is.null(top_srcrefs) && length(top_srcrefs) >= i) top_srcrefs[[i]][1] else NA_integer_
      # SITE-LEVEL exception tag. A raw connection is exempted at the exact
      # call site, not the whole file: a `# duckdb-exception: <tag>` comment
      # ANYWHERE within the enclosing top-level statement's own line range
      # (not just its first line -- a mutation's `x$duckdb_connect <-
      # function(...) { ... }` is one top-level statement whose raw call is
      # many lines below where it starts) marks this exact site as claiming
      # an exception. `NA` if no tag is present. This closes a real gap the
      # earlier file-level registry had: a NEW, unrelated raw connection
      # added later to an already-exempted file was previously invisible to
      # the offender check. It no longer is -- only a site actually carrying
      # the matching tag is exempt.
      stmt_tag <- NA_character_
      if (!is.null(top_srcrefs) && length(top_srcrefs) >= i) {
        sr <- as.numeric(top_srcrefs[[i]])
        l1 <- sr[1]; l2 <- if (length(sr) >= 3) sr[3] else sr[1]
        stmt_text <- if (l1 >= 1 && l2 <= length(raw_lines) && l1 <= l2)
          paste(raw_lines[l1:l2], collapse = "\n") else ""
        m <- regmatches(stmt_text, regexpr("duckdb-exception:\\s*(\\S+)", stmt_text))
        if (length(m) && nzchar(m))
          stmt_tag <- sub("duckdb-exception:\\s*(\\S+).*", "\\1", m)
      }
      walk_calls(top_list[[i]], function(node) {
        nm <- callee_name(node)
        if (is.na(nm)) return(invisible(NULL))
        if (nm %in% c("dbConnect", "DBI::dbConnect")) {
          args <- as.list(node)[-1]
          drv_arg <- if (!is.null(names(args)) && "drv" %in% names(args)) args[["drv"]] else args[[1]]
          drv_is_aliased_call <- !is.null(drv_arg) && is.call(drv_arg) &&
            is.symbol(drv_arg[[1]]) && as.character(drv_arg[[1]]) %in% aliased_driver_names
          if (!is.null(drv_arg) && (is_bare_duckdb_driver_call(drv_arg) || drv_is_aliased_call))
            hits[[length(hits) + 1]] <<- list(line = stmt_line, tag = stmt_tag,
                                              symbol = paste0(nm, "(duckdb::duckdb(), ...)"))
        }
        # A SEPARATE, direct rule for `duckdb::duckdb()` / `duckdb()` as a
        # call anywhere, not only inline inside dbConnect(). This is what
        # catches the indirection a purely dbConnect-argument-based rule
        # cannot: `d <- duckdb::duckdb(); con <- dbConnect(d)` never puts the
        # driver construction textually inside the dbConnect() call, but it
        # is exactly as much a bypass of duckdb_connect() as the inline form.
        if (nm %in% c("duckdb", "duckdb::duckdb"))
          hits[[length(hits) + 1]] <<- list(line = stmt_line, tag = stmt_tag, symbol = paste0(nm, "()"))
        # A call THROUGH a discovered alias -- `con_fun()` where `con_fun`
        # was assigned from a bare `duckdb`/`duckdb::duckdb` reference above.
        if (nm %in% aliased_driver_names)
          hits[[length(hits) + 1]] <<- list(line = stmt_line, tag = stmt_tag,
                                            symbol = sprintf("%s()  # aliased duckdb::duckdb", nm))
      })
    }
    if (!length(hits)) return(NULL)
    data.frame(file = path,
               line = vapply(hits, `[[`, integer(1), "line"),
               tag = vapply(hits, `[[`, character(1), "tag"),
               symbol = vapply(hits, `[[`, character(1), "symbol"),
               stringsAsFactors = FALSE)
  })
  out <- out[!vapply(out, is.null, logical(1))]
  if (!length(out)) return(data.frame(file = character(), line = integer(), symbol = character()))
  do.call(rbind, out)
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
duckdb_connect <- function(dbdir = ":memory:", read_only = FALSE, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)  # duckdb-exception: bootstrap-definition
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
