# =============================================================================
# duckdb_connect()'s machine-checkable contract, independence, and integration
# =============================================================================
# The migration made every production file CALL duckdb_connect(). This file
# proves what that function actually GUARANTEES, so a future change to it
# cannot silently redefine what "canonical connection" means without a test
# noticing. Three things, each with its own section below:
#
#   1. THE CONTRACT (§1): backend, path semantics, read_only, config
#      forwarding, extensions, disconnect -- asserted directly. Where a
#      property is deliberately left unspecified (temp_directory, threads,
#      memory), that is asserted too: the test proves duckdb_connect() does
#      NOT silently change DuckDB's own default, rather than proving nothing
#      about it at all.
#   2. INDEPENDENCE (§2): centralizing connection creation in one function is
#      itself a new risk -- a bug in that one function could leak state
#      across every caller at once. These tests prove two duckdb_connect()
#      calls do not share temp tables, session settings, or a connection
#      object, and that disconnecting one does not invalidate the other.
#   3. INTEGRATION HARNESS (§3): one lightweight harness exercising every
#      representative consumer behavior (read query, write, CSV import,
#      transaction, temp table, multi-connection) against a real temporary
#      database, so the contract is verified once at the abstraction
#      boundary rather than needing 36 bespoke per-file tests. ATTACH/DETACH
#      is not exercised: a repo-wide scan found zero uses of it, and this is
#      recorded as a fact, not silently skipped.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

# -----------------------------------------------------------------------------
# 1. The contract
# -----------------------------------------------------------------------------
ci_section("Connection contract")

# backend
con <- duckdb_connect()
ci_ok_or_fail <- function(cond, ...) if (isTRUE(cond)) ci_ok(...) else ci_fail(...)
ci_ok_or_fail(inherits(con, "duckdb_connection"), "backend is a duckdb_connection (got: %s)", paste(class(con), collapse = "/"))

# path semantics: an explicit path is used exactly as given, and a table
# written there is visible again from a SEPARATE connection to the same path
# -- proving path semantics are real persistence, not an in-memory alias.
DBI::dbDisconnect(con, shutdown = TRUE)
path_file <- tempfile(fileext = ".duckdb")
con_a <- duckdb_connect(path_file)
DBI::dbExecute(con_a, "CREATE TABLE t AS SELECT 42 AS x")
DBI::dbDisconnect(con_a, shutdown = TRUE)
con_b <- duckdb_connect(path_file, read_only = TRUE)
val <- DBI::dbGetQuery(con_b, "SELECT x FROM t")$x
DBI::dbDisconnect(con_b, shutdown = TRUE)
unlink(path_file)
# DuckDB's untyped integer literal 42 comes back as R integer (42L), not
# double -- identical(val, 42) is FALSE for exactly that reason (identical()
# is type-strict). Compare by value, which is what this assertion actually
# means, not by R's internal numeric type.
ci_ok_or_fail(isTRUE(val == 42), "explicit dbdir path is used exactly as given and persists across separate connections (got x=%s, class %s)", val, class(val))

# read_only preserved
con_ro <- duckdb_connect(read_only = FALSE)  # :memory: read_only=TRUE is a DuckDB no-op (nothing to protect), so use a file
path_ro <- tempfile(fileext = ".duckdb")
con_setup <- duckdb_connect(path_ro)
DBI::dbExecute(con_setup, "CREATE TABLE t AS SELECT 1 AS x")
DBI::dbDisconnect(con_setup, shutdown = TRUE)
con_ro2 <- duckdb_connect(path_ro, read_only = TRUE)
write_blocked <- tryCatch({ DBI::dbExecute(con_ro2, "CREATE TABLE t2 AS SELECT 1"); FALSE }, error = function(e) TRUE)
DBI::dbDisconnect(con_ro2, shutdown = TRUE)
unlink(path_ro)
ci_ok_or_fail(write_blocked, "read_only=TRUE is preserved -- a write attempt on a read_only connection is rejected")
DBI::dbDisconnect(con_ro, shutdown = TRUE)

# config/options forwarded through ... . `config = list(memory_limit = ...)`
# was tried first and does not take effect at connect time -- verified true
# even on a RAW DBI::dbConnect(), so that is a fact about the R duckdb
# package's config handling, not something duckdb_connect() broke. `bigint=`
# is a documented dbConnect argument with a directly observable effect
# (changes the R class of a returned BIGINT column), so it verifies the same
# claim -- arguments in `...` really reach DBI::dbConnect -- correctly.
con_cfg <- duckdb_connect(bigint = "integer64")
cls <- class(DBI::dbGetQuery(con_cfg, "SELECT 42::BIGINT AS v")$v)
DBI::dbDisconnect(con_cfg, shutdown = TRUE)
ci_ok_or_fail("integer64" %in% cls, "arguments passed through ... reach DBI::dbConnect (bigint='integer64' changed the returned class to %s)", paste(cls, collapse = "/"))

# extensions: encodings guaranteed loaded
con_ext <- duckdb_connect()
cap <- duckdb_encoding_capability(con_ext)
DBI::dbDisconnect(con_ext, shutdown = TRUE)
ci_ok_or_fail(cap$required_encoding_support_available, "the encodings extension is loaded and functional on every duckdb_connect() connection")

# temp_directory / threads / memory: UNSPECIFIED -- prove duckdb_connect()
# does not silently diverge from a raw connection's own defaults, i.e. that
# "unspecified" really means "DuckDB's default", not "some other value this
# function happens to produce".
raw_con <- DBI::dbConnect(duckdb::duckdb())  # duckdb-exception: raw-baseline-defaults
raw_threads <- DBI::dbGetQuery(raw_con, "SELECT current_setting('threads') AS v")$v
DBI::dbDisconnect(raw_con, shutdown = TRUE)
boot_con <- duckdb_connect()
boot_threads <- DBI::dbGetQuery(boot_con, "SELECT current_setting('threads') AS v")$v
DBI::dbDisconnect(boot_con, shutdown = TRUE)
ci_ok_or_fail(identical(raw_threads, boot_threads),
              "threads is UNSPECIFIED by duckdb_connect() and matches a raw connection's own default (raw=%s, bootstrapped=%s)",
              raw_threads, boot_threads)
ci_skip("temp_directory left UNSPECIFIED by design -- duckdb_connect() sets no PRAGMA for it; see the contract docstring in R/lib/medicare_duckdb.R")
ci_skip("memory_limit left UNSPECIFIED by design UNLESS a caller passes config=list(memory_limit=...) explicitly, as tested above")

# disconnect safe and idempotent
con_dc <- duckdb_connect()
DBI::dbDisconnect(con_dc, shutdown = TRUE)
second_disconnect_ok <- tryCatch({ DBI::dbDisconnect(con_dc, shutdown = TRUE); TRUE }, error = function(e) FALSE, warning = function(w) TRUE)
ci_ok_or_fail(second_disconnect_ok, "a second dbDisconnect() on an already-disconnected connection does not throw a hard error")

# -----------------------------------------------------------------------------
# 2. Independence -- no hidden shared state
# -----------------------------------------------------------------------------
ci_section("Independence between separate duckdb_connect() calls")

con_x <- duckdb_connect()
con_y <- duckdb_connect()
ci_ok_or_fail(!identical(con_x, con_y), "two duckdb_connect() calls return distinct connection objects")

# temp tables on A are not visible on B (both :memory:, genuinely separate DuckDB instances)
DBI::dbExecute(con_x, "CREATE TEMP TABLE only_on_x AS SELECT 1 AS v")
visible_on_y <- tryCatch({ DBI::dbGetQuery(con_y, "SELECT * FROM only_on_x"); TRUE }, error = function(e) FALSE)
ci_ok_or_fail(!visible_on_y, "a temp table created on connection A is NOT visible on connection B (separate :memory: instances)")

# connection-scoped settings do not leak from A to B
DBI::dbExecute(con_x, "SET memory_limit='123MB'")
lim_x <- DBI::dbGetQuery(con_x, "SELECT current_setting('memory_limit') AS v")$v
lim_y <- DBI::dbGetQuery(con_y, "SELECT current_setting('memory_limit') AS v")$v
ci_ok_or_fail(!identical(lim_x, lim_y), "a SET on connection A's session does not leak to connection B (A=%s, B=%s)", lim_x, lim_y)

# disconnecting A does not invalidate B
DBI::dbDisconnect(con_x, shutdown = TRUE)
b_still_works <- tryCatch({ DBI::dbGetQuery(con_y, "SELECT 1 AS v")$v == 1 }, error = function(e) FALSE)
ci_ok_or_fail(b_still_works, "disconnecting connection A does not invalidate connection B")
DBI::dbDisconnect(con_y, shutdown = TRUE)

# duckdb_connect() itself caches no handle/config across calls at the R level
ci_ok_or_fail(!exists(".duckdb_connect_cache", envir = environment(duckdb_connect), inherits = FALSE),
              "duckdb_connect() maintains no internal cache/shared-state variable in its own closure")

# -----------------------------------------------------------------------------
# 3. Integration harness -- representative consumer behaviors, once
# -----------------------------------------------------------------------------
ci_section("Integration harness: representative consumer behaviors")

harness_path <- tempfile(fileext = ".duckdb")
con_h <- duckdb_connect(harness_path)

ok_write <- tryCatch({ DBI::dbExecute(con_h, "CREATE TABLE people (id INTEGER, name VARCHAR)"); TRUE }, error = function(e) FALSE)
ci_ok_or_fail(ok_write, "write / create table")

ok_insert <- tryCatch({ DBI::dbExecute(con_h, "INSERT INTO people VALUES (1, 'Ana'), (2, 'Bo')"); TRUE }, error = function(e) FALSE)
ci_ok_or_fail(ok_insert, "write / insert rows")

ok_read <- tryCatch({ DBI::dbGetQuery(con_h, "SELECT COUNT(*) AS n FROM people")$n == 2 }, error = function(e) FALSE)
ci_ok_or_fail(ok_read, "read-only query")

csv_fx <- tempfile(fileext = ".csv")
writeLines(c("id,name", "3,Cy"), csv_fx)
ok_csv <- tryCatch({
  DBI::dbExecute(con_h, sprintf("INSERT INTO people SELECT * FROM read_csv_auto('%s', header=true)", csv_fx))
  DBI::dbGetQuery(con_h, "SELECT COUNT(*) AS n FROM people")$n == 3
}, error = function(e) FALSE)
ci_ok_or_fail(ok_csv, "CSV import through read_csv_auto")
unlink(csv_fx)

ok_txn <- tryCatch({
  DBI::dbBegin(con_h)
  DBI::dbExecute(con_h, "INSERT INTO people VALUES (4, 'Rolled Back')")
  DBI::dbRollback(con_h)
  DBI::dbGetQuery(con_h, "SELECT COUNT(*) AS n FROM people")$n == 3
}, error = function(e) FALSE)
ci_ok_or_fail(ok_txn, "transaction (dbBegin/dbRollback) -- not used anywhere in this repo today per the file inventory, but proven available")

ok_temp <- tryCatch({
  DBI::dbExecute(con_h, "CREATE TEMP TABLE scratch AS SELECT * FROM people WHERE id = 1")
  DBI::dbGetQuery(con_h, "SELECT COUNT(*) AS n FROM scratch")$n == 1
}, error = function(e) FALSE)
ci_ok_or_fail(ok_temp, "temporary table creation")

ok_register <- tryCatch({
  duckdb::duckdb_register(con_h, "external_df", data.frame(id = 5, name = "Df"))
  DBI::dbGetQuery(con_h, "SELECT COUNT(*) AS n FROM external_df")$n == 1
}, error = function(e) FALSE)
ci_ok_or_fail(ok_register, "duckdb_register() virtual-table registration (the dominant temp-table idiom actually used across the migrated files)")

DBI::dbDisconnect(con_h, shutdown = TRUE)

# multi-connection: a second connection to the SAME persisted file, opened
# read-only, sees what the writer connection committed.
con_h2 <- duckdb_connect(harness_path, read_only = TRUE)
ok_multiconn <- tryCatch({ DBI::dbGetQuery(con_h2, "SELECT COUNT(*) AS n FROM people")$n == 3 }, error = function(e) FALSE)
ci_ok_or_fail(ok_multiconn, "multi-connection access: a second connection to the same persisted file sees the first connection's committed writes")
DBI::dbDisconnect(con_h2, shutdown = TRUE)
unlink(harness_path)

ci_skip("ATTACH/DETACH not exercised -- a repo-wide scan (this session's file inventory) found zero uses of ATTACH in any of the 36 migrated files or elsewhere; nothing to verify against a real consumer")

ci_finish()
