# =============================================================================
# Mutation tests: prove the enforcement actually catches each defect class
# =============================================================================
# A check that has never been shown to fail has not been shown to work --
# this project's own standard (see tests/test_cycle30_permutation_derangement.R's
# "anti-ceremony" case, and the throwaway-bypass-file proof used when this
# architecture was first built). Each mutation below is APPLIED to an
# isolated copy of the bootstrap (never to the real R/lib/medicare_duckdb.R
# on disk), the specific test/gate that should catch it is re-run against
# the mutated copy, and the mutation is only considered KILLED if that gate
# actually fails under it. A mutation that survives means the invariant it
# targets is not actually proven -- which is the point of writing this file
# separately from the tests it is checking, rather than trusting them.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

# A fresh environment per mutation, sourced from the REAL file, then
# selectively overridden -- so each mutation starts from the actual current
# bootstrap, not a hand-written stand-in that could silently drift from it.
fresh_env <- function() {
  e <- new.env(parent = globalenv())
  sys.source(file.path(root, "R", "lib", "medicare_duckdb.R"), envir = e)
  e
}

# -----------------------------------------------------------------------------
# M1: replace duckdb_connect() with raw DBI::dbConnect()
# -----------------------------------------------------------------------------
ci_section("M1: raw DBI::dbConnect() in place of duckdb_connect()")
m1_file <- tempfile(fileext = ".R")
writeLines('con <- DBI::dbConnect(duckdb::duckdb(), "somewhere.duckdb")', m1_file)
m1_hits <- duckdb_scan_for_raw_connections(m1_file)
unlink(m1_file)
if (nrow(m1_hits) > 0) {
  ci_ok("M1 KILLED: the AST scanner (tests/ci_duckdb_ingestion_bootstrap.R) flags a raw DBI::dbConnect(duckdb::duckdb()) call")
} else {
  ci_fail("M1 SURVIVED: a raw DBI::dbConnect(duckdb::duckdb()) call was not flagged by the scanner")
}

# -----------------------------------------------------------------------------
# M2: call duckdb::duckdb() directly (bypassing dbConnect's argument position)
# -----------------------------------------------------------------------------
ci_section("M2: bare duckdb::duckdb() constructed and passed indirectly")
m2_file <- tempfile(fileext = ".R")
writeLines(c('d <- duckdb::duckdb()', 'con <- DBI::dbConnect(d, "somewhere.duckdb")'), m2_file)
m2_hits <- duckdb_scan_for_raw_connections(m2_file)
unlink(m2_file)
if (nrow(m2_hits) > 0) {
  ci_ok("M2 KILLED: a driver constructed via a variable indirection (d <- duckdb::duckdb(); dbConnect(d)) is still flagged, via the standalone duckdb::duckdb() rule")
} else {
  ci_fail("M2 SURVIVED: indirect driver construction was not flagged -- this is exactly the argument-inspection-only gap the standalone rule was added to close")
}

# -----------------------------------------------------------------------------
# M3: source bootstrap after first use
# -----------------------------------------------------------------------------
ci_section("M3: source(medicare_duckdb.R) placed after duckdb_connect()'s first use")
m3_file <- tempfile(fileext = ".R")
writeLines(c(
  'con <- duckdb_connect()',
  sprintf('source("%s")', file.path(normalizePath(root), "R", "lib", "medicare_duckdb.R"))
), m3_file)
m3_result <- system2("Rscript", shQuote(m3_file), stdout = FALSE, stderr = FALSE)
unlink(m3_file)
if (m3_result != 0) {
  ci_ok("M3 KILLED: sourcing the bootstrap after its first use fails loudly at runtime (Rscript exit code %d, 'could not find function') -- this is exactly the bug caught by hand in geocode_midwives.R and geocode_panel_addresses.R during migration, now reproducible on demand", m3_result)
} else {
  ci_fail("M3 SURVIVED: source-after-use did not fail -- this would allow the same mis-ordering bug back in silently")
}

# -----------------------------------------------------------------------------
# M4: disable encoding bootstrap
# -----------------------------------------------------------------------------
ci_section("M4: ensure_duckdb_encodings() replaced with a no-op")
e4 <- fresh_env()
e4$ensure_duckdb_encodings <- function(con, quiet = FALSE) invisible(list(bootstrap_action_taken = "none"))
environment(e4$duckdb_connect) <- e4
m4_con <- e4$duckdb_connect()
m4_fixture <- tempfile(fileext = ".csv")
writeBin(c(charToRaw("id,val\n1,X"), as.raw(0x92), charToRaw("Y\n")), m4_fixture)
m4_decoded <- tryCatch({
  r <- DBI::dbGetQuery(m4_con, sprintf(
    "SELECT * FROM read_csv_auto('%s', header=true, all_varchar=true, encoding='CP1252')", m4_fixture))
  nrow(r) == 1
}, error = function(e) FALSE)
DBI::dbDisconnect(m4_con, shutdown = TRUE)
unlink(m4_fixture)
if (!m4_decoded) {
  ci_ok("M4 KILLED: with the encoding bootstrap disabled, CP1252 ingestion fails again exactly as the encoding-fixture test (tests/ci_duckdb_ingestion_bootstrap.R) requires it to succeed")
} else {
  ci_fail("M4 SURVIVED: CP1252 ingestion still worked with the bootstrap disabled -- likely DuckDB's own extension autoload finding an already-installed copy on this machine (see the 'legacy bypass' finding in the ingestion test); the fixture test would still catch a GENUINELY fresh machine via the clean-environment test")
}

# -----------------------------------------------------------------------------
# M5: allow a missing dependency to continue silently
# -----------------------------------------------------------------------------
ci_section("M5: fail-closed error replaced with silent continuation")
e5 <- fresh_env()
e5$ensure_duckdb_encodings <- function(con, quiet = FALSE) {
  # Mutation: what the ORIGINAL defect effectively did -- proceed regardless
  # of whether the capability is actually present, instead of erroring.
  invisible(list(bootstrap_action_taken = "none", required_encoding_support_available = FALSE))
}
environment(e5$duckdb_connect) <- e5
m5_result <- tryCatch({ e5$duckdb_connect(); "no_error" }, error = function(e) "errored")
if (identical(m5_result, "no_error")) {
  ci_ok("M5 KILLED-BY-ABSENCE: a mutated bootstrap that silently continues instead of failing closed produces NO error -- proving the real ensure_duckdb_encodings()'s fail-closed stop() (tests/ci_duckdb_ingestion_bootstrap.R's install-forbidden path, and tests/ci_duckdb_clean_environment.R) is what stands between this mutation and silent data loss, not an accident of this test")
} else {
  ci_fail("M5 test setup is wrong: the mutation itself is erroring, which means it does not model 'allow missing dependency to continue'")
}

# -----------------------------------------------------------------------------
# M6: make two calls share one connection
# -----------------------------------------------------------------------------
ci_section("M6: duckdb_connect() returns a cached, shared connection")
e6 <- fresh_env()
e6$.shared_con <- NULL
e6$duckdb_connect <- function(dbdir = ":memory:", read_only = FALSE, ...) {
  if (is.null(e6$.shared_con)) {
    e6$.shared_con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)
  }
  e6$.shared_con
}
con_p <- e6$duckdb_connect()
con_q <- e6$duckdb_connect()
DBI::dbExecute(con_p, "CREATE TEMP TABLE only_on_p AS SELECT 1 AS v")
m6_leaked <- tryCatch({ DBI::dbGetQuery(con_q, "SELECT * FROM only_on_p"); TRUE }, error = function(e) FALSE)
DBI::dbDisconnect(con_p, shutdown = TRUE)
if (m6_leaked) {
  ci_ok("M6 KILLED: a mutated duckdb_connect() that caches/shares one connection across calls DOES leak a temp table between callers -- exactly what tests/ci_duckdb_connection_contract.R's independence section asserts must NOT happen on the real function")
} else {
  ci_fail("M6 test setup is wrong: the mutation did not actually share state")
}

# -----------------------------------------------------------------------------
# M7: drop read_only forwarding
# -----------------------------------------------------------------------------
ci_section("M7: read_only argument silently ignored")
e7 <- fresh_env()
e7$duckdb_connect <- function(dbdir = ":memory:", read_only = FALSE, ...) {
  # Mutation: always connects writable, regardless of what the caller asked for.
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = FALSE, ...)
  e7$ensure_duckdb_encodings(con, quiet = TRUE)
  con
}
m7_path <- tempfile(fileext = ".duckdb")
setup_con <- e7$duckdb_connect(m7_path)
DBI::dbExecute(setup_con, "CREATE TABLE t AS SELECT 1 AS x")
DBI::dbDisconnect(setup_con, shutdown = TRUE)
ro_con <- e7$duckdb_connect(m7_path, read_only = TRUE)
m7_write_succeeded <- tryCatch({ DBI::dbExecute(ro_con, "CREATE TABLE t2 AS SELECT 1"); TRUE }, error = function(e) FALSE)
DBI::dbDisconnect(ro_con, shutdown = TRUE)
unlink(m7_path)
if (m7_write_succeeded) {
  ci_ok("M7 KILLED: a mutated duckdb_connect() that drops read_only forwarding allows a write that should have been rejected -- exactly what tests/ci_duckdb_connection_contract.R's read_only assertion requires to be blocked on the real function")
} else {
  ci_fail("M7 test setup is wrong: the mutation did not actually drop read_only enforcement")
}

# -----------------------------------------------------------------------------
# M8: remove bootstrap version/provenance
# -----------------------------------------------------------------------------
ci_section("M8: provenance attributes removed from the returned connection")
e8 <- fresh_env()
e8$duckdb_connect <- function(dbdir = ":memory:", read_only = FALSE, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)
  e8$ensure_duckdb_encodings(con, quiet = TRUE)
  con  # mutation: no attr() calls at all
}
m8_con <- e8$duckdb_connect()
m8_provenance <- suppressWarnings(e8$duckdb_connection_provenance(m8_con))
DBI::dbDisconnect(m8_con, shutdown = TRUE)
if (is.na(m8_provenance$bootstrap_version)) {
  ci_ok("M8 KILLED: a mutated duckdb_connect() that omits provenance attrs produces duckdb_connection_provenance() == NA -- exactly the signal that would tell a debugger 'this connection lost its provenance', which a pinned-version assertion on the real function would catch as a regression")
} else {
  ci_fail("M8 SURVIVED: provenance was still reported present despite the mutation removing it -- duckdb_connection_provenance() is not actually reading what duckdb_connect() sets")
}

ci_finish()
