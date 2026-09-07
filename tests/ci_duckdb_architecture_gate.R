# =============================================================================
# One aggregate architectural gate, with explicit sub-results
# =============================================================================
# Nine separate test files prove nine separate things about the DuckDB
# bootstrap architecture. Running them separately is right for development
# (a failure points straight at the relevant file) but wrong for a single
# merge-gate decision, which needs one yes/no answer -- and a merge-gate
# that silently treats "this sub-check didn't run" the same as "this
# sub-check passed" is worse than no gate at all. Every sub-result below is
# computed from an actual subprocess run or an actual direct check in this
# process; none is assumed. A sub-check whose subprocess errors, times out,
# or produces no recognizable output is reported FAILED, not skipped into a
# green aggregate.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

run_gate <- function(rel_path, timeout_s = 300) {
  full <- file.path(root, rel_path)
  out <- tryCatch(
    system2("Rscript", shQuote(full), stdout = TRUE, stderr = TRUE, timeout = timeout_s),
    error = function(e) c(paste("R ERROR:", conditionMessage(e))))
  status <- attr(out, "status")
  ok <- is.null(status) && any(grepl("^PASS \\(0 failures\\)$", out))
  list(ok = ok, out = out)
}

sub_results <- list()
record <- function(name, ok, detail = NULL) {
  sub_results[[name]] <<- list(ok = ok, detail = detail)
  if (ok) ci_ok("%s: PASS", name) else ci_fail("%s: FAILED%s", name, if (!is.null(detail)) paste0(" -- ", detail) else "")
}

# -----------------------------------------------------------------------------
# 1 & 2: raw connections outside registry (exact count), registry self-consistency
# -----------------------------------------------------------------------------
ci_section("Raw connections outside registry, and registry self-consistency")
tracked_r <- ci_tracked("*.R")
tracked_full <- file.path(root, tracked_r)
tracked_full <- tracked_full[file.exists(tracked_full)]
scan <- duckdb_scan_for_raw_connections(tracked_full)
scan$file_rel <- if (root == "..") sub("^\\.\\./", "", scan$file) else sub("^\\./", "", scan$file)
registry_keys <- vapply(DUCKDB_RAW_CONNECTION_EXCEPTIONS, function(e) paste(e$file, e$tag, sep = "\x1f"), character(1))
scan_keys <- paste(scan$file_rel, scan$tag, sep = "\x1f")
covered <- !is.na(scan$tag) & scan_keys %in% registry_keys
n_offenders <- length(unique(scan_keys[!covered]))
cat(sprintf("raw production connections outside registry: %d\n", n_offenders))
record("raw production connections outside registry (0 expected)", n_offenders == 0L,
       if (n_offenders > 0L) sprintf("%d unregistered site(s)", n_offenders) else NULL)

ingestion <- run_gate("tests/ci_duckdb_ingestion_bootstrap.R")
registry_consistent <- ingestion$ok && any(grepl("registered, tagged exception site", ingestion$out)) &&
  !any(grepl("^FAIL ", ingestion$out))
record("exception registry self-consistent", registry_consistent,
       if (!registry_consistent) "see tests/ci_duckdb_ingestion_bootstrap.R output" else NULL)
record("encoding regression suite", ingestion$ok && any(grepl("Encoding regression fixtures", ingestion$out)),
       if (!ingestion$ok) "tests/ci_duckdb_ingestion_bootstrap.R did not report PASS" else NULL)

# -----------------------------------------------------------------------------
# 3 & 4: connection contract, independence
# -----------------------------------------------------------------------------
ci_section("Connection contract and independence")
contract <- run_gate("tests/ci_duckdb_connection_contract.R")
record("canonical connection contract", contract$ok && any(grepl("Connection contract", contract$out)))
record("independent connection semantics", contract$ok && any(grepl("Independence between separate", contract$out)))

# -----------------------------------------------------------------------------
# 5: clean-environment bootstrap (M4b)
# -----------------------------------------------------------------------------
ci_section("Clean-environment bootstrap")
clean_env <- run_gate("tests/ci_duckdb_clean_environment.R", timeout_s = 600)
record("clean-environment bootstrap", clean_env$ok, if (!clean_env$ok) "tests/ci_duckdb_clean_environment.R did not report PASS -- a SKIPPED or errored run here is a FAIL, not green" else NULL)

# -----------------------------------------------------------------------------
# 6: AST / structural / dynamic mutation suite (M1-M17)
# -----------------------------------------------------------------------------
ci_section("Mutation suite (M1-M17)")
mutations <- run_gate("tests/ci_duckdb_mutation_tests.R")
all_killed <- mutations$ok && !any(grepl("SURVIVED", mutations$out))
record("AST mutation suite (M1-M17)", all_killed,
       if (!all_killed) "at least one mutation SURVIVED or the suite errored" else NULL)

# -----------------------------------------------------------------------------
# 7: unordered-output equivalence helper
# -----------------------------------------------------------------------------
ci_section("Unordered-output equivalence helper")
table_eq <- run_gate("tests/test_table_equivalence.R")
record("unordered-output equivalence helper", table_eq$ok)

# -----------------------------------------------------------------------------
# 8: geocode migration-only diff (a fact about specific, pinned commits)
# -----------------------------------------------------------------------------
ci_section("Geocode migration-only diff")
# Pinned to the commit that did the actual split (see
# docs/TECHNICAL_APPENDIX_DUCKDB_BOOTSTRAP_ARCHITECTURE.md). Git history is
# immutable once committed, so this stays checkable indefinitely -- unlike
# the working tree, which changes. A line is "pure migration" if it is a
# diff header/context line, a removed raw dbConnect(duckdb::duckdb(), ...)
# line, an added duckdb_connect(...) line, or an added source(medicare_duckdb.R)
# line; anything else in the diff means the split was not actually clean.
MIGRATION_COMMIT <- "9ed95ab"
diff_out <- tryCatch(
  system2("git", c("show", MIGRATION_COMMIT, "--", "geocode_panel_addresses.R", "geocode_queue_cascade.R"),
          stdout = TRUE, stderr = TRUE),
  error = function(e) character(0))
changed_lines <- grep("^[+-][^+-]", diff_out, value = TRUE)
allowed <- grepl('^\\+source\\(file\\.path\\("R", "lib", "medicare_duckdb\\.R"\\)\\)\\s*$', changed_lines) |
  grepl("^\\+.*con <- duckdb_connect\\(", changed_lines) |
  grepl("^-.*con <- dbConnect\\(duckdb::duckdb\\(\\)", changed_lines)
pure_diff <- length(diff_out) > 0 && all(allowed)
record("geocode migration-only diff (commit pinned)", pure_diff,
       if (!pure_diff) sprintf("commit %s's geocode-file diff contains a non-migration line", MIGRATION_COMMIT) else NULL)

# -----------------------------------------------------------------------------
# 9: geocode bug-fix tests
# -----------------------------------------------------------------------------
ci_section("Geocode bug-fix tests")
latlon <- run_gate("tests/test_geocode_latlon_rename.R")
checkpoint <- run_gate("tests/test_geocode_checkpoint_safety.R")
record("geocode bug-fix tests (lat/lon + checkpoint safety)", latlon$ok && checkpoint$ok,
       if (!(latlon$ok && checkpoint$ok)) sprintf("lat/lon=%s checkpoint=%s", latlon$ok, checkpoint$ok) else NULL)

# -----------------------------------------------------------------------------
# Consolidated summary
# -----------------------------------------------------------------------------
ci_section("Aggregate architectural gate summary")
for (nm in names(sub_results)) {
  cat(sprintf("  %-55s %s\n", nm, if (sub_results[[nm]]$ok) "PASS" else "FAIL"))
}
all_pass <- all(vapply(sub_results, function(r) r$ok, logical(1)))
cat(sprintf("\nOVERALL: %s\n", if (all_pass) "PASS" else "FAIL"))

ci_finish()
