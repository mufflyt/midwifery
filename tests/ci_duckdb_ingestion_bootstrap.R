# =============================================================================
# CSV ingestion bootstrap: enforcement, not just documentation
# =============================================================================
# A CMS PECOS extract silently lost 10 real enrollment records to
# `ignore_errors = TRUE` -- two of them accented or apostrophe'd names
# ("COURTNEY ÉLAN MCCALL", "CARNELL D'ANDRE JOHNSON") -- because the file was
# Windows-1252, not UTF-8 or Latin-1, and DuckDB's built-in CSV reader only
# knows those two plus UTF-16. `INSTALL encodings; LOAD encodings;` fixes it.
# See docs/TECHNICAL_APPENDIX_CSV_INGESTION_ENCODING.md and
# docs/TECHNICAL_APPENDIX_DUCKDB_BOOTSTRAP_ARCHITECTURE.md.
#
# SUPERSEDES the first version of this file, which used a regex ratchet and
# an inline allowlist vector. Both were upgraded after the first version was
# put into production use:
#
#   - the regex missed nothing this session's migration needed, but a
#     structural (AST) scanner also catches multi-line calls and named-
#     argument forms a regex would need separate cases for, and -- proven
#     live, not hypothetically -- it found TWO real unmigrated call sites
#     (analysis/audit_identity_flips.R, analysis/measure_taxonomy_scope_ceiling.R)
#     that were added to the repo after the original migration pass and
#     before this rewrite. That is exactly the regression class this file
#     exists to catch, caught in the act rather than in a postmortem.
#   - the inline allowlist became DUCKDB_RAW_CONNECTION_EXCEPTIONS in
#     R/lib/medicare_duckdb.R: a structured registry with file/reason/owner/
#     expiry_condition per entry, so "this is fine" is a checkable, attributed
#     claim rather than an anonymous vector entry.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

# -----------------------------------------------------------------------------
# 1. Structural (AST) bypass check -- see duckdb_scan_for_raw_connections()
# -----------------------------------------------------------------------------
ci_section("No raw dbConnect(duckdb::duckdb()) outside the exception registry")

tracked_r <- ci_tracked("*.R")
tracked_full <- file.path(root, tracked_r)
tracked_full <- tracked_full[file.exists(tracked_full)]

scan <- duckdb_scan_for_raw_connections(tracked_full)
# root is only ever "." or ".." here (see the resolution above), so a literal
# prefix strip is sufficient -- no need for a generic path-escaping utility.
scan$file_rel <- if (root == "..") sub("^\\.\\./", "", scan$file) else sub("^\\./", "", scan$file)

# SITE-LEVEL matching: a hit is covered only if its (file, tag) pair matches
# a registry entry exactly -- not merely if its FILE appears anywhere in the
# registry. A hit with no tag at all (NA) can never match, by construction:
# an untagged raw connection in an otherwise-registered file is exactly the
# "new, unrelated raw connection silently exempted" gap this design closes.
registry_key <- function(entries) vapply(entries, function(e) paste(e$file, e$tag, sep = "\x1f"),
                                         character(1))
registry_keys <- registry_key(DUCKDB_RAW_CONNECTION_EXCEPTIONS)
scan_keys <- paste(scan$file_rel, scan$tag, sep = "\x1f")

covered <- !is.na(scan$tag) & scan_keys %in% registry_keys
offenders <- scan[!covered, , drop = FALSE]
if (nrow(offenders)) {
  for (i in seq_len(nrow(offenders)))
    ci_fail("raw DuckDB connection outside the exception registry -- file: %s, line: %s, tag: %s, symbol: %s -- route through duckdb_connect() (R/lib/medicare_duckdb.R) or add a justified, tagged DUCKDB_RAW_CONNECTION_EXCEPTIONS entry",
            offenders$file_rel[i], offenders$line[i],
            ifelse(is.na(offenders$tag[i]), "<none>", offenders$tag[i]), offenders$symbol[i])
} else {
  ci_ok("every tracked .R file's DuckDB connection is either duckdb_connect() or a registered, tagged exception site (%d files scanned, %d distinct raw-connection sites, %d files with any raw dbConnect() at all)",
        length(tracked_full), length(unique(scan_keys)), length(unique(scan$file_rel)))
}

# Explicit upper bound: the registry may not grow past
# DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX without a conscious edit to that
# constant, right next to the registry it bounds -- see its docstring.
if (length(DUCKDB_RAW_CONNECTION_EXCEPTIONS) > DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX) {
  ci_fail("DUCKDB_RAW_CONNECTION_EXCEPTIONS has grown to %d entries, past its declared upper bound of %d -- if this growth is genuinely justified, raise DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX in R/lib/medicare_duckdb.R deliberately, in the same change, with a reason",
          length(DUCKDB_RAW_CONNECTION_EXCEPTIONS), DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX)
} else {
  ci_ok("exception registry size (%d) is within its declared upper bound (%d)",
        length(DUCKDB_RAW_CONNECTION_EXCEPTIONS), DUCKDB_RAW_CONNECTION_EXCEPTIONS_MAX)
}

# The registry itself may only shrink: an entry naming a (file, tag) that no
# longer exists, or whose file no longer exists at all, is stale cover and
# must be removed, not left in place. (This is exactly what happened to the
# old tests/test_cache_vintage_detect.R entry, removed when the regex-only
# false-positive it covered stopped applying under the AST scanner.)
seen_keys <- character(0)
for (entry in DUCKDB_RAW_CONNECTION_EXCEPTIONS) {
  f <- entry$file
  full <- file.path(root, f)
  key <- paste(entry$file, entry$tag, sep = "\x1f")
  if (key %in% seen_keys) {
    ci_fail("DUCKDB_RAW_CONNECTION_EXCEPTIONS has a duplicate entry for %s / tag %s -- one real site should have exactly one registry entry", f, entry$tag)
  }
  seen_keys <- c(seen_keys, key)
  if (!file.exists(full)) {
    ci_fail("DUCKDB_RAW_CONNECTION_EXCEPTIONS entry '%s' (tag %s) no longer exists -- remove it (owner: %s)", f, entry$tag, entry$owner)
    next
  }
  if (!key %in% scan_keys) {
    ci_fail("DUCKDB_RAW_CONNECTION_EXCEPTIONS entry '%s' (tag %s, %s) no longer corresponds to an actual tagged raw-connection site -- remove it, don't leave stale cover (owner: %s)",
            f, entry$tag, entry$locator, entry$owner)
  } else {
    ci_ok("registry entry %s / %s (%s) still applies (class: %s; owner: %s; added: %s; removal condition: %s)",
          f, entry$tag, entry$locator, entry$exception_class, entry$owner, entry$added_date, entry$removal_condition)
  }
}

# -----------------------------------------------------------------------------
# 2. Encoding regression fixture matrix
# -----------------------------------------------------------------------------
ci_section("Encoding regression fixtures")

# Each fixture is built from raw bytes, never through a text connection, so
# none of these depend on this machine's default locale. All exercise the
# CP1252 byte class that broke the real PECOS load; the malformed fixture is
# the negative control -- ingestion must FAIL it, not silently coerce it.
make_fixture <- function(byte_after_comma) {
  f <- tempfile(fileext = ".csv")
  writeBin(c(charToRaw("id,val\n1,X"), byte_after_comma, charToRaw("Y\n")), f)
  f
}

fixtures <- list(
  valid_utf8            = list(bytes = charToRaw("é"), expect = "success", note = "plain UTF-8, no CP1252 needed at all"),
  cp1252_smart_quote     = list(bytes = as.raw(0x92), expect = "success", note = "right single quotation mark (the exact byte from the real PECOS defect)"),
  cp1252_em_dash         = list(bytes = as.raw(0x97), expect = "success", note = "em dash"),
  cp1252_nbsp            = list(bytes = as.raw(0xA0), expect = "success", note = "non-breaking space (also technically valid Latin-1, but the fixture proves CP1252 handles it too)")
)

for (nm in names(fixtures)) {
  spec <- fixtures[[nm]]
  fx <- make_fixture(spec$bytes)
  con <- duckdb_connect()
  ok <- tryCatch({
    r <- DBI::dbGetQuery(con, sprintf(
      "SELECT * FROM read_csv_auto('%s', header=true, all_varchar=true, encoding='CP1252')", fx))
    nrow(r) == 1
  }, error = function(e) FALSE)
  DBI::dbDisconnect(con, shutdown = TRUE)
  unlink(fx)
  if (identical(spec$expect, "success")) {
    if (ok) ci_ok("fixture '%s' (%s) ingests successfully through the canonical bootstrap", nm, spec$note)
    else ci_fail("fixture '%s' (%s) FAILED to ingest -- regression in CP1252 support", nm, spec$note)
  }
}

# Malformed byte sequence: a lone continuation byte with no valid lead byte
# under ANY common single-byte encoding's printable range in this position is
# not achievable (single-byte encodings map every byte to something), so the
# malformed case here is a genuinely truncated multi-byte UTF-8 sequence fed
# to a UTF-8 (not CP1252) read -- ingestion must fail closed, and this
# project's own convention is that a failure must be loud, not silently
# coerced into an empty or wrong value. See §"Do not normalize silently" in
# docs/TECHNICAL_APPENDIX_DUCKDB_BOOTSTRAP_ARCHITECTURE.md.
malformed_fx <- make_fixture(as.raw(0xC0))  # 0xC0 is not a valid UTF-8 lead byte at all
con <- duckdb_connect()
malformed_result <- tryCatch({
  DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_csv_auto('%s', header=true, all_varchar=true)", malformed_fx))  # plain UTF-8, no CP1252
  "succeeded"
}, error = function(e) "failed")
DBI::dbDisconnect(con, shutdown = TRUE)
unlink(malformed_fx)
if (identical(malformed_result, "failed")) {
  ci_ok("malformed byte sequence (invalid UTF-8 lead byte) correctly fails UTF-8 ingestion rather than being silently coerced")
} else {
  ci_fail("malformed byte sequence was silently accepted by plain UTF-8 ingestion -- this project does not normalize malformed bytes silently just to make ingestion succeed")
}

# Direct raw connection / legacy bypass reproduces the ORIGINAL defect
# PATTERN, not "any raw connection must fail forever". A first attempt at
# this test asserted that a raw connection with an EXPLICIT encoding='CP1252'
# request must fail, and that assertion was wrong: DuckDB autoloads an
# already-installed extension the moment a query references it, with or
# without duckdb_connect()'s explicit LOAD. Once `encodings` is installed
# anywhere on this machine (which it now is, from this very test file
# running earlier in the same session), a raw connection can find it too --
# that is DuckDB's own autoload behavior, not something duckdb_connect()
# grants exclusively. Asserting otherwise here would have been an
# overclaim caught by actually running the test, not by reasoning about it.
#
# The TRUE, narrower claim this test can make without uninstalling the
# extension from the machine (a disruptive side effect on shared state well
# outside this test's scope): the ORIGINAL defect was never "the extension
# isn't loaded" in isolation -- it was that `ignore_errors = TRUE` was used
# INSTEAD of requesting an encoding at all, because nobody ingesting the
# PECOS file knew a non-UTF-8 encoding needed handling. That pattern -- no
# `encoding=` argument, `ignore_errors = TRUE` -- silently drops the bad row
# regardless of which connection function opened it, exactly like the real
# incident. Proving a raw connection is REFUSED the capability when the
# extension is genuinely absent (not just un-loaded on one connection)
# belongs in the clean-environment test (see
# tests/ci_duckdb_clean_environment.R, §"install-forbidden"), which controls
# DuckDB's extension_directory directly rather than relying on this
# machine's already-populated one.
legacy_con <- DBI::dbConnect(duckdb::duckdb())  # deliberately bypassing duckdb_connect() -- duckdb-exception: legacy-defect-control
legacy_fx <- make_fixture(as.raw(0x92))
legacy_dropped <- tryCatch({
  r <- DBI::dbGetQuery(legacy_con, sprintf(
    "SELECT * FROM read_csv_auto('%s', header=true, all_varchar=true, ignore_errors=true)", legacy_fx))
  nrow(r) == 0L  # the bad row is silently dropped, not decoded and not errored
}, error = function(e) FALSE)
DBI::dbDisconnect(legacy_con, shutdown = TRUE)
unlink(legacy_fx)
if (legacy_dropped) {
  ci_ok("legacy pattern (ignore_errors=TRUE, no encoding requested) reproduces the ORIGINAL defect exactly: the row is silently dropped, on a raw connection just as it was in the real incident")
} else {
  ci_fail("legacy pattern (ignore_errors=TRUE, no encoding) did not reproduce row-dropping -- this test no longer demonstrates the original defect")
}

ci_finish()
