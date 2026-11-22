#!/usr/bin/env Rscript
# =============================================================================
# The raw-connection exception registry and the AST scanner that enforces it
# =============================================================================
# CI-ONLY, SO IT LIVES WITH THE GATES. Every caller of
# `duckdb_scan_for_raw_connections()` is a gate --
# tests/ci_duckdb_architecture_gate.R, tests/ci_duckdb_ingestion_bootstrap.R,
# tests/ci_duckdb_exception_provenance.R and tests/ci_duckdb_mutation_tests.R
# -- and it has no production caller anywhere in the repository. It used to
# live in R/lib/medicare_duckdb.R, which 30-odd scripts source (pipeline stage
# 4 among them) to reach `open_medicare_duckdb()`; all of them were parsing
# 343 lines of gate machinery they never call. The 2026-11-20 complexity audit
# measured the scanner at cyclomatic complexity 98 over 156 lines -- the worst
# function in the pipeline's source closure, and in the wrong file.
#
# NOTHING ABOUT THE RULE CHANGED. Same registry, same site-level tag matching,
# same documented alias-resolution boundary, same return shape
# (`data.frame(file, line, tag, symbol)`). The mutation suite
# (tests/ci_duckdb_mutation_tests.R, M1-M17) is what proves that, and it runs
# against this file now.
#
# THE NAME IS NEITHER ci_*, test_* NOR helper-*. nightly.yml globs
# `tests/test*.R`, so a shared library named like a gate would be run as one.
# It was called helper-duckdb-scan.R for an hour, which was worse:
# `testthat::test_file()` auto-sources every `tests/helper-*.R` into the test
# directory, from the test directory -- so all ten test_file()-invoked suites
# in ci.yml began sourcing this scanner, and all of them broke on
# `tests/R/lib/ast_walk.R`, the relative path this file resolves from the
# working directory. The P4 lesson in tests/test_ponytail_cuts_saboteurs.R,
# arriving from a direction that gate does not scan.
#
# The call-tree walker this scanner used to carry is now R/lib/ast_walk.R,
# shared with .code_closure() in R/lib/artifact_provenance.R.
# =============================================================================

.duckdb_scan_root <- local({
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
})
source(file.path(.duckdb_scan_root, "R", "lib", "ast_walk.R"))

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
       removal_condition = "If mutation M8 is ever removed from this file, remove this entry too."),
  # BOTH OF THESE WERE COMMENTED BUT NOT REGISTERED, and the nightly of
  # 2026-11-18 is where that surfaced. The sites carried
  # `# duckdb-exception: test fixture`, which the scanner reads as the single
  # token "test" (its pattern is `duckdb-exception:\\s*(\\S+)`), and no entry
  # for the file existed at all -- so the comment exempted nothing, which is
  # precisely the behaviour this registry is for. One tag per site rather than
  # one shared tag for both: a shared tag would also cover a THIRD connection
  # added later with the same comment, which is the file-level cover this
  # design replaced.
  list(file = "tests/test_zip_normalizer_saboteurs.R",
       tag = "zip-sql-typed-column",
       locator = "Z14b (a column that is not VARCHAR)",
       reason = "In-memory connection -- dbConnect(duckdb::duckdb()) with no dbdir -- holding a three-column CREATE TABLE of INTEGER/VARCHAR/DOUBLE ZIPs, to prove zip5_sql() survives the non-VARCHAR column that killed the core-parquet panel build. No external file is read on it, so there is no encoding hazard to bootstrap against, and duckdb_connect() would point a saboteur suite at the production warehouse.",
       exception_class = "synthetic-fixture",
       owner = "ZIP normalizer maintainer",
       added_date = "2026-11-19",
       removal_condition = "If Z14b stops constructing its own typed table -- or is ever changed to read an external file on this connection -- remove this entry."),
  list(file = "tests/test_zip_normalizer_saboteurs.R",
       tag = "zip-sql-agreement",
       locator = "Z14 (the generated SQL agrees with the R function)",
       reason = "In-memory connection carrying sixteen probe values written with dbWriteTable() from an R data frame, so the SQL zip5_sql() generates and the R normalizer can be run over identical input and compared. Same reasoning as zip-sql-typed-column: nothing is read from disk and the comparison needs a real connection.",
       exception_class = "synthetic-fixture",
       owner = "ZIP normalizer maintainer",
       added_date = "2026-11-19",
       removal_condition = "If the SQL-vs-R agreement check is ever removed from this file, remove this entry too.")
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
#'
#' 7 -> 9 on 2026-11-19, deliberately and with the reason recorded: the two ZIP
#' saboteur sites above. They are not new connections -- they have existed
#' since the 2026-11-16 ZIP sweep, carrying an exception comment the scanner
#' could not match -- so this raise registers an existing footprint rather
#' than admitting new bypasses. The speed bump worked: the gate refused them
#' for three days and the nightly said so every morning.
DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX <- 9L

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
  # The walker lives in R/lib/ast_walk.R now: walk_call_tree(). Same traversal
  # (visit the call, recurse into arguments 2..n, descend a pairlist or list),
  # same handling of nodes that cannot be walked -- it was written twice, once
  # here and once in .code_closure(), each with its own paragraph about R's
  # empty symbol. See that file for the paragraph.

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
      walk_call_tree(top_list[[i]], function(node) {
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
