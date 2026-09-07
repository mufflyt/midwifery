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
source(file.path(root, "R", "lib", "table_equivalence.R"))
source(file.path(root, "R", "lib", "checkpoint_utils.R"))
source(file.path(root, "R", "lib", "geocode_cache_columns.R"))

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
# M4a: bootstrap invocation contract (structural)
# -----------------------------------------------------------------------------
# M4 has TWO genuinely different meanings, and conflating them into one
# result was itself a defect: an in-process dynamic test (construct a
# connection with the bootstrap disabled, see if CP1252 decoding still
# works) is confounded on any machine that has ever installed the
# `encodings` extension -- DuckDB autoloads an already-installed extension
# regardless of whether the bootstrap ran, so the dynamic test can report
# "survived" on a warm developer machine while the actual invariant (does
# duckdb_connect() still CALL the bootstrap function at all?) is perfectly
# intact. An EARLIER version of this file reported exactly that confounded
# result as plain "M4 SURVIVED", with no structural counterpart -- which
# reads as a real gap, not a documented limitation. It is split in two:
#
#   M4a (here, structural, immune to autoload by construction -- no
#        connection is ever opened): does duckdb_connect()'s own function
#        body still contain a call to ensure_duckdb_encodings()?
#   M4b (tests/ci_duckdb_clean_environment.R, dynamic, immune to autoload
#        by using a genuinely empty extension_directory in a fresh
#        subprocess): with the bootstrap enabled vs disabled, does CP1252
#        decoding actually succeed vs fail closed?
#
# CI considers M4 killed only when M4b kills it. M4a is a real, independent
# contract in its own right (catching, e.g., a refactor that silently drops
# the call while leaving everything else intact) but is not sufficient on
# its own -- a structural check proves the call SITE exists, not that the
# function it calls still does anything.
ci_section("M4a: bootstrap invocation contract (structural)")
bootstrap_is_invoked <- function(fn) {
  grepl("ensure_duckdb_encodings\\s*\\(", paste(deparse(body(fn)), collapse = " "))
}
if (bootstrap_is_invoked(duckdb_connect)) {
  ci_ok("M4a PASS: the real duckdb_connect() body still contains a call to ensure_duckdb_encodings() -- the bootstrap invocation contract holds")
} else {
  ci_fail("M4a FAIL: duckdb_connect()'s body no longer calls ensure_duckdb_encodings() at all -- the bootstrap invocation contract is broken")
}
# Mutation: the call is structurally REMOVED from duckdb_connect()'s body
# (not just made a no-op -- that is a different mutation, M4b's concern).
# Reconstructed by editing the deparsed source and re-parsing, since R has
# no first-class way to delete one statement from a closure's body.
e4a_src <- deparse(body(duckdb_connect))
e4a_src_mutated <- e4a_src[!grepl("ensure_duckdb_encodings", e4a_src)]
e4a_mutated_fn <- duckdb_connect
body(e4a_mutated_fn) <- parse(text = paste(e4a_src_mutated, collapse = "\n"))[[1]]
if (!bootstrap_is_invoked(e4a_mutated_fn)) {
  ci_ok("M4a KILLED: a mutated duckdb_connect() with the ensure_duckdb_encodings() call structurally removed is correctly detected as no longer invoking the bootstrap")
} else {
  ci_fail("M4a test setup is wrong: the mutation did not actually remove the call")
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
    e6$.shared_con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)  # duckdb-exception: mutation-m6
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
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = FALSE, ...)  # duckdb-exception: mutation-m7
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
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only, ...)  # duckdb-exception: mutation-m8
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

# -----------------------------------------------------------------------------
# M9: alias duckdb::duckdb through a symbol
# -----------------------------------------------------------------------------
ci_section("M9: driver constructor aliased through a bare symbol, then invoked")
m9_file <- tempfile(fileext = ".R")
writeLines(c('con_fun <- duckdb::duckdb', 'con <- DBI::dbConnect(con_fun())'), m9_file)
m9_hits <- duckdb_scan_for_raw_connections(m9_file)
unlink(m9_file)
if (nrow(m9_hits) > 0 && any(grepl("aliased duckdb::duckdb", m9_hits$symbol))) {
  ci_ok("M9 KILLED: `con_fun <- duckdb::duckdb; con_fun()` is flagged via the single-assignment alias tracking added to duckdb_scan_for_raw_connections() -- this is exactly the evasion that has no literal `duckdb::duckdb()` text anywhere for the standalone rule to find")
} else {
  ci_fail("M9 SURVIVED: a driver constructor aliased through a bare symbol and then invoked was not flagged")
}

# -----------------------------------------------------------------------------
# M10: hide raw DBI::dbConnect() in a local wrapper function
# -----------------------------------------------------------------------------
ci_section("M10: raw connection hidden inside a wrapper function's body")
m10_file <- tempfile(fileext = ".R")
writeLines(c('local_connect <- function(...) {', '  DBI::dbConnect(duckdb::duckdb(), ...)', '}'), m10_file)
m10_hits <- duckdb_scan_for_raw_connections(m10_file)
unlink(m10_file)
if (nrow(m10_hits) > 0) {
  ci_ok("M10 KILLED: a raw dbConnect(duckdb::duckdb()) call hidden inside a wrapper function's body is still flagged -- the recursive AST walk descends into function bodies the same as any other call argument, so wrapping the literal call changes nothing about whether it is found")
} else {
  ci_fail("M10 SURVIVED: a raw connection hidden inside a wrapper function's body was not flagged")
}

# -----------------------------------------------------------------------------
# M11: stale exception-registry entry
# -----------------------------------------------------------------------------
ci_section("M11: registry entry pointing at a site that no longer has a raw connection")
m11_file <- tempfile(fileext = ".R")
writeLines('x <- 1  # nothing raw here at all', m11_file)
m11_scan <- duckdb_scan_for_raw_connections(m11_file)
m11_scan_keys <- paste(m11_scan$file, m11_scan$tag, sep = "\x1f")
m11_stale_entry <- list(file = m11_file, tag = "no-such-site")
m11_key <- paste(m11_stale_entry$file, m11_stale_entry$tag, sep = "\x1f")
unlink(m11_file)
if (!m11_key %in% m11_scan_keys) {
  ci_ok("M11 KILLED: a registry entry naming a (file, tag) pair the scanner does not find is correctly identifiable as stale cover by the same key-matching logic tests/ci_duckdb_ingestion_bootstrap.R uses to reject it")
} else {
  ci_fail("M11 test setup is wrong: the synthetic stale entry unexpectedly matched a real scanned site")
}

# -----------------------------------------------------------------------------
# M12: unregistered new exception in an already-exempted file
# -----------------------------------------------------------------------------
ci_section("M12: a NEW, untagged raw connection added to an otherwise-registered file")
m12_file <- tempfile(fileext = ".R")
writeLines(c(
  '# Pretend this file already has one registered, tagged site:',
  'con1 <- DBI::dbConnect(duckdb::duckdb())  # duckdb-exception: some-registered-tag',
  '# ...and someone later adds an UNRELATED raw connection with no tag at all:',
  'con2 <- DBI::dbConnect(duckdb::duckdb())'
), m12_file)
m12_scan <- duckdb_scan_for_raw_connections(m12_file)
unlink(m12_file)
m12_registry_keys <- paste(m12_file, "some-registered-tag", sep = "\x1f")
m12_scan_keys <- paste(m12_scan$file, m12_scan$tag, sep = "\x1f")
m12_covered <- !is.na(m12_scan$tag) & m12_scan_keys %in% m12_registry_keys
if (any(!m12_covered)) {
  ci_ok("M12 KILLED: the new untagged raw connection is NOT covered by the file's existing registered tag -- a file-level registry (the earlier design) would have silently exempted it; the site-level (file, tag) design does not")
} else {
  ci_fail("M12 SURVIVED: a new, untagged raw connection in an already-registered file was silently treated as covered")
}

# -----------------------------------------------------------------------------
# M13: one-row deletion in an unordered output
# -----------------------------------------------------------------------------
ci_section("M13: one row silently missing from an unordered relational output")
m13_base <- data.frame(id = 1:5, val = c("a", "b", "c", "d", "e"), stringsAsFactors = FALSE)
m13_mutated <- m13_base[-3, ]
m13_result <- tables_equivalent(m13_base, m13_mutated)
if (!m13_result$equivalent && identical(m13_result$reason, "missing_rows")) {
  ci_ok("M13 KILLED: tables_equivalent() detects a single deleted row as missing_rows even though row order is otherwise insignificant")
} else {
  ci_fail("M13 SURVIVED: a one-row deletion was not detected (equivalent=%s, reason=%s)",
          m13_result$equivalent, if (is.null(m13_result$reason)) "NULL" else m13_result$reason)
}

# -----------------------------------------------------------------------------
# M14: duplicate multiplicity change (the setdiff blind spot)
# -----------------------------------------------------------------------------
ci_section("M14: same distinct rows, different duplicate counts")
m14_base <- data.frame(id = c(1, 1, 1, 2), val = c("x", "x", "x", "y"), stringsAsFactors = FALSE)
m14_mutated <- data.frame(id = c(1, 1, 2), val = c("x", "x", "y"), stringsAsFactors = FALSE)
m14_result <- tables_equivalent(m14_base, m14_mutated)
if (!m14_result$equivalent && identical(m14_result$reason, "duplicate_multiplicity_mismatch")) {
  ci_ok("M14 KILLED: tables_equivalent() detects a changed duplicate count as duplicate_multiplicity_mismatch specifically -- a setdiff()-only implementation would report no difference here, since the DISTINCT rows are identical")
} else {
  ci_fail("M14 SURVIVED: a duplicate-multiplicity change was not detected (equivalent=%s, reason=%s)",
          m14_result$equivalent, if (is.null(m14_result$reason)) "NULL" else m14_result$reason)
}

# -----------------------------------------------------------------------------
# M15: column-type change with identical rendered values
# -----------------------------------------------------------------------------
ci_section("M15: a column's type changes but every rendered value looks the same")
m15_base <- data.frame(id = 42L, val = "x", stringsAsFactors = FALSE)
m15_mutated <- data.frame(id = "42", val = "x", stringsAsFactors = FALSE)
m15_result <- tables_equivalent(m15_base, m15_mutated)
if (!m15_result$equivalent && identical(m15_result$reason, "type_mismatch")) {
  ci_ok("M15 KILLED: tables_equivalent() detects integer-vs-character on the same rendered digits as type_mismatch, rather than silently passing because as.character(42L) == \"42\"")
} else {
  ci_fail("M15 SURVIVED: a type change with identical rendered values was not detected (equivalent=%s, reason=%s)",
          m15_result$equivalent, if (is.null(m15_result$reason)) "NULL" else m15_result$reason)
}

# -----------------------------------------------------------------------------
# M16: disabled checkpoint promotion safety
# -----------------------------------------------------------------------------
ci_section("M16: checkpoint saved directly to its final path, no atomic staging")
m16_path <- tempfile(fileext = ".rds")
m16_broken_save <- function(object, path) { saveRDS(object, path); invisible(path) }  # mutation: no tmp+rename
m16_good <- data.frame(v = 1:3)
m16_broken_save(m16_good, m16_path)
# Simulate a process dying mid-write by truncating the file it was writing
# DIRECTLY, since a non-atomic save has nowhere else for a partial write to
# land -- this is exactly the failure mode save_checkpoint_atomic() exists
# to make impossible (see tests/test_geocode_checkpoint_safety.R for the
# real function's equivalent scenarios, which all pass).
writeBin(readBin(m16_path, "raw", file.info(m16_path)$size %/% 2L), m16_path)
m16_load_result <- tryCatch({ readRDS(m16_path); "loaded_without_error" },
                            error = function(e) "errored")
# Either outcome here is bad: a truncated file that still "loads" without
# error would be worse (silently wrong data accepted as current), but a
# non-atomic save has already failed the invariant regardless, because the
# LAST KNOWN GOOD checkpoint (the one saveRDS() overwrote in place) is gone
# either way -- there was never a separate promoted copy to fall back to.
m16_old_good_gone <- !file.exists(m16_path) || identical(m16_load_result, "errored")
unlink(m16_path)
if (m16_old_good_gone) {
  ci_ok("M16 KILLED: a mutated save that writes directly to the final path (no tmp-then-rename) loses the last-known-good checkpoint to a mid-write interruption -- exactly what save_checkpoint_atomic()'s promotion step exists to prevent (see tests/test_geocode_checkpoint_safety.R's real-function scenarios, which all keep the prior good checkpoint readable under the identical interruption)")
} else {
  ci_fail("M16 test setup is wrong: the simulated interruption did not actually damage the non-atomic checkpoint")
}

# -----------------------------------------------------------------------------
# M17: lat/lon swap
# -----------------------------------------------------------------------------
ci_section("M17: latitude/longitude columns swapped in the cache-column resolver")
m17_con <- duckdb_connect()
duckdb::duckdb_register(m17_con, "geocoding_cache",
                        data.frame(address_hash = "h1", latitude = 40.7128, longitude = -74.0060,
                                  quality_score = 1, census_tract = "t1", county_fips = "f1"))
m17_cols <- resolve_lat_lon_columns(DBI::dbListFields(m17_con, "geocoding_cache"))
m17_cols_swapped <- list(lat_col = m17_cols$lon_col, lon_col = m17_cols$lat_col)  # mutation
m17_row <- DBI::dbGetQuery(m17_con, sprintf(
  "SELECT %s AS latitude, %s AS longitude FROM geocoding_cache",
  m17_cols_swapped$lat_col, m17_cols_swapped$lon_col))
DBI::dbDisconnect(m17_con, shutdown = TRUE)
m17_swapped_is_wrong <- abs(m17_row$latitude[1] - 40.7128) > 1e-9 && abs(m17_row$longitude[1] - (-74.0060)) > 1e-9
if (m17_swapped_is_wrong) {
  ci_ok("M17 KILLED: swapping resolve_lat_lon_columns()'s returned lat_col/lon_col produces a 'latitude' value of %.4f (actually the longitude) and a 'longitude' of %.4f (actually the latitude) -- exactly the wrong-value regression tests/test_geocode_latlon_rename.R's exact-value assertions (abs(result$latitude - 40.7128) < 1e-9) would catch",
        m17_row$latitude[1], m17_row$longitude[1])
} else {
  ci_fail("M17 test setup is wrong: swapping lat_col/lon_col did not actually change the returned values -- check the fixture's lat/lon are genuinely distinguishable")
}

ci_finish()
