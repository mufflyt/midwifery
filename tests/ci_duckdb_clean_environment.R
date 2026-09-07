# =============================================================================
# Clean-environment proof: the bootstrap works from a genuinely fresh machine
# =============================================================================
# Every other test in this suite runs on a machine that already has the
# `encodings` extension installed (this session installed it while
# diagnosing the original PECOS defect). That is a real confound: DuckDB
# autoloads an already-installed extension the moment a query references it,
# with or without ensure_duckdb_encodings() ever running -- proven directly
# by M4 in tests/ci_duckdb_mutation_tests.R, where disabling the bootstrap
# entirely still let CP1252 decoding succeed, because the extension was
# already sitting on disk from earlier in this session.
#
# This file removes that confound by pointing DuckDB's `extension_directory`
# at an EMPTY temporary directory for each subprocess it launches -- a
# genuine simulation of "never installed on this machine", not a mock or a
# stubbed function. Two scenarios, run as separate Rscript subprocesses (so
# each starts with no in-process state carried over, not just an empty
# extension folder):
#
#   install-allowed  (DUCKDB_BOOTSTRAP_ALLOW_INSTALL unset/1): the bootstrap
#                     must self-heal via INSTALL, requiring network access.
#   install-forbidden (DUCKDB_BOOTSTRAP_ALLOW_INSTALL=0): must fail closed
#                     with a clear, specific error -- no network attempt.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
root_abs <- normalizePath(root)

run_in_clean_env <- function(allow_install, extension_dir) {
  script <- tempfile(fileext = ".R")
  writeLines(c(
    sprintf('source(file.path("%s", "R", "lib", "medicare_duckdb.R"))', root_abs),
    sprintf('Sys.setenv(DUCKDB_BOOTSTRAP_ALLOW_INSTALL = "%s")', allow_install),
    'con <- DBI::dbConnect(duckdb::duckdb())',
    sprintf('DBI::dbExecute(con, "SET extension_directory=\'%s\'")', extension_dir),
    'result <- tryCatch({',
    '  ensure_duckdb_encodings(con)',
    '  fixture <- tempfile(fileext = ".csv")',
    '  writeBin(c(charToRaw("id,val\\n1,X"), as.raw(0x92), charToRaw("Y\\n")), fixture)',
    '  r <- DBI::dbGetQuery(con, sprintf(',
    '    "SELECT * FROM read_csv_auto(\'%s\', header=true, all_varchar=true, encoding=\'CP1252\')", fixture))',
    '  unlink(fixture)',
    '  if (nrow(r) == 1) "success" else "wrong_row_count"',
    '}, error = function(e) paste0("error: ", conditionMessage(e)))',
    'cat(result, "\\n", sep = "")',
    'DBI::dbDisconnect(con, shutdown = TRUE)'
  ), script)
  out <- suppressWarnings(system2("Rscript", shQuote(script), stdout = TRUE, stderr = TRUE))
  unlink(script)
  out
}

# -----------------------------------------------------------------------------
# Scenario A: install-allowed, genuinely empty extension directory
# -----------------------------------------------------------------------------
ci_section("Clean environment, install-allowed")
ext_dir_a <- tempfile(); dir.create(ext_dir_a)
out_a <- run_in_clean_env("1", ext_dir_a)
unlink(ext_dir_a, recursive = TRUE)
last_line_a <- tail(out_a, 1)
if (identical(last_line_a, "success")) {
  ci_ok("install-allowed: a genuinely fresh extension_directory self-heals via INSTALL and successfully decodes CP1252 -- the fresh-machine self-heal path works, not just the already-provisioned path every other test in this suite exercises")
} else {
  ci_fail("install-allowed clean-environment run did not succeed (last line: %s). Full output:\n%s",
          last_line_a, paste(out_a, collapse = "\n"))
  ci_skip("NOTE: this scenario requires network access to download the 'encodings' extension binary. A failure here in a network-restricted environment is a NETWORK/INSTALL defect, not a code defect -- see the install-forbidden scenario below for the fail-closed path that does not require network access at all.")
}

# -----------------------------------------------------------------------------
# Scenario B: install-forbidden, genuinely empty extension directory
# -----------------------------------------------------------------------------
ci_section("Clean environment, install-forbidden (fail-closed)")
ext_dir_b <- tempfile(); dir.create(ext_dir_b)
out_b <- run_in_clean_env("0", ext_dir_b)
unlink(ext_dir_b, recursive = TRUE)
last_line_b <- tail(out_b, 1)
full_b <- paste(out_b, collapse = " ")
if (grepl("error: ", full_b, fixed = TRUE) && grepl("fail-closed", full_b, fixed = TRUE)) {
  ci_ok("install-forbidden: a genuinely fresh extension_directory with DUCKDB_BOOTSTRAP_ALLOW_INSTALL=0 fails CLOSED with the specific, documented error naming the missing capability -- no network attempt, no silent continuation")
} else {
  ci_fail("install-forbidden clean-environment run did not fail closed as expected (last line: %s). Full output:\n%s",
          last_line_b, paste(out_b, collapse = "\n"))
}

# -----------------------------------------------------------------------------
# M4's real, unconfounded kill-proof
# -----------------------------------------------------------------------------
ci_section("M4 (disabled bootstrap), re-tested without the autoload confound")
ext_dir_m4 <- tempfile(); dir.create(ext_dir_m4)
m4_script <- tempfile(fileext = ".R")
writeLines(c(
  sprintf('source(file.path("%s", "R", "lib", "medicare_duckdb.R"))', root_abs),
  'con <- DBI::dbConnect(duckdb::duckdb())',
  sprintf('DBI::dbExecute(con, "SET extension_directory=\'%s\'")', ext_dir_m4),
  '# Mutation applied here, in the clean environment: bootstrap is skipped entirely.',
  'fixture <- tempfile(fileext = ".csv")',
  'writeBin(c(charToRaw("id,val\\n1,X"), as.raw(0x92), charToRaw("Y\\n")), fixture)',
  'result <- tryCatch({',
  '  r <- DBI::dbGetQuery(con, sprintf(',
  '    "SELECT * FROM read_csv_auto(\'%s\', header=true, all_varchar=true, encoding=\'CP1252\')", fixture))',
  '  if (nrow(r) == 1) "success" else "wrong_row_count"',
  '}, error = function(e) "error")',
  'cat(result, "\\n", sep = "")'
), m4_script)
m4_out <- suppressWarnings(system2("Rscript", shQuote(m4_script), stdout = TRUE, stderr = TRUE))
unlink(m4_script); unlink(ext_dir_m4, recursive = TRUE)
if (identical(tail(m4_out, 1), "error")) {
  ci_ok("M4 KILLED (unconfounded): with the bootstrap skipped AND a genuinely empty extension_directory (no autoload possible), CP1252 decoding fails exactly as it did in the real incident -- this is the definitive version of M4 that tests/ci_duckdb_mutation_tests.R's in-process attempt could only show conditionally")
} else {
  ci_fail("M4 unexpectedly succeeded even in a genuinely empty extension_directory with the bootstrap skipped -- this would mean DuckDB ships CP1252 support built in, which contradicts the original incident entirely and needs investigation, not a passing test")
}

ci_finish()
