# =============================================================================
# The 4-to-7 exception count is a measurement correction, not a regression
# =============================================================================
# A registry that grows from 4 entries to 7 looks, out of context, exactly
# like new raw connections being introduced. It isn't: the base architecture
# commit (db44c3b) already contained all seven sites' underlying raw
# DBI::dbConnect(duckdb::duckdb()) calls -- three of them (the M6/M7/M8
# mutation-harness re-implementations in tests/ci_duckdb_mutation_tests.R)
# were simply never registered, because that file's own registration was
# missed at commit time. This file does not ASSERT that history -- it
# RE-DERIVES it from git directly, every time it runs, so the claim stays
# checkable indefinitely rather than resting on a comment nobody re-verifies.
#
# Run from the repository root, the way CI runs it.
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))
source(file.path(root, "R", "lib", "medicare_duckdb.R"))

BASE_COMMIT <- "db44c3bd9d30d54c587ee8258901e61677d01ef7"
provenance <- ci_read_head(file.path("tests", "fixtures", "duckdb_exception_registry_provenance.csv"), root = root)

ci_section("Provenance table shape")
if (is.null(provenance)) {
  ci_fail("could not read tests/fixtures/duckdb_exception_registry_provenance.csv")
} else if (nrow(provenance) != length(DUCKDB_RAW_CONNECTION_EXCEPTIONS)) {
  ci_fail("provenance table has %d rows but the live registry has %d entries -- they must describe the same set",
          nrow(provenance), length(DUCKDB_RAW_CONNECTION_EXCEPTIONS))
} else {
  ci_ok("provenance table row count (%d) matches the live registry entry count", nrow(provenance))
}

ci_section("Every provenance row matches a live registry entry exactly")
if (!is.null(provenance)) {
  registry_keys <- vapply(DUCKDB_RAW_CONNECTION_EXCEPTIONS, function(e) paste(e$file, e$tag, sep = "\x1f"), character(1))
  prov_keys <- paste(provenance$file, provenance$tag, sep = "\x1f")
  if (!setequal(registry_keys, prov_keys)) {
    ci_fail("provenance table (file,tag) set does not match the live registry -- only in provenance: %s; only in registry: %s",
            paste(setdiff(prov_keys, registry_keys), collapse = "; "),
            paste(setdiff(registry_keys, prov_keys), collapse = "; "))
  } else {
    ci_ok("every (file, tag) pair in the provenance table matches a live registry entry, and vice versa")
  }
}

ci_section("New unjustified exceptions introduced: re-derived from git history, not asserted")
n_new_unjustified <- 0L
if (!is.null(provenance)) {
  for (f in unique(provenance$file)) {
    rows <- provenance[provenance$file == f, ]
    base_content <- tryCatch(
      system2("git", c("show", paste0(BASE_COMMIT, ":", f)), stdout = TRUE, stderr = TRUE),
      error = function(e) NULL)
    base_status <- attr(base_content, "status")
    if (!is.null(base_status) && base_status != 0) {
      # File did not exist at the base commit at all -- every row for it is
      # a genuinely new site, and must be classified as such, not miscounted
      # as "undercounted".
      genuinely_new <- rows$classification != "INTENTIONALLY_ADDED_BY_THIS_CHANGE"
      if (any(genuinely_new)) {
        ci_fail("%s does not exist at base commit %s, but %d row(s) claim PREEXISTING_AND_PREVIOUSLY_UNDERCOUNTED -- reclassify as INTENTIONALLY_ADDED_BY_THIS_CHANGE",
                f, substr(BASE_COMMIT, 1, 7), sum(genuinely_new))
        n_new_unjustified <- n_new_unjustified + sum(genuinely_new)
      } else {
        ci_ok("%s: %d row(s) correctly classified INTENTIONALLY_ADDED_BY_THIS_CHANGE (file did not exist at base commit)", f, nrow(rows))
      }
      next
    }
    base_file <- tempfile(fileext = ".R")
    writeLines(base_content, base_file)
    base_hits <- nrow(duckdb_scan_for_raw_connections(base_file))
    unlink(base_file)
    # base_hits counts BOTH the dbConnect-argument rule and the standalone
    # duckdb::duckdb() rule per site (2 rows per real site) -- halve it to
    # compare against a per-site row count.
    base_sites <- base_hits %/% 2L
    claimed_preexisting <- sum(rows$classification == "PREEXISTING_AND_PREVIOUSLY_UNDERCOUNTED")
    if (base_sites >= claimed_preexisting) {
      ci_ok("%s: base commit %s already contains >= %d raw-connection site(s) (found %d), consistent with all %d row(s) claiming PREEXISTING_AND_PREVIOUSLY_UNDERCOUNTED",
            f, substr(BASE_COMMIT, 1, 7), claimed_preexisting, base_sites, claimed_preexisting)
    } else {
      ci_fail("%s: base commit %s contains only %d raw-connection site(s), but %d row(s) claim PREEXISTING_AND_PREVIOUSLY_UNDERCOUNTED -- at least %d row(s) are misclassified and should be INTENTIONALLY_ADDED_BY_THIS_CHANGE",
              f, substr(BASE_COMMIT, 1, 7), base_sites, claimed_preexisting, claimed_preexisting - base_sites)
      n_new_unjustified <- n_new_unjustified + (claimed_preexisting - base_sites)
    }
  }
}
cat(sprintf("\nnew unjustified exceptions introduced: %d\n", n_new_unjustified))
if (n_new_unjustified == 0L) {
  ci_ok("0 new unjustified exceptions -- the 4-to-7 registry growth is fully accounted for by base-commit sites that existed but were not yet registered")
} else {
  ci_fail("%d exception(s) claim preexistence but are not supported by the base commit's own content", n_new_unjustified)
}

ci_section("Site-vs-file granularity, reported explicitly (never conflated)")
exception_files <- length(unique(vapply(DUCKDB_RAW_CONNECTION_EXCEPTIONS, function(e) e$file, character(1))))
exception_sites <- length(DUCKDB_RAW_CONNECTION_EXCEPTIONS)
cat(sprintf("exception_files: %d\n", exception_files))
cat(sprintf("exception_sites: %d\n", exception_sites))
ci_ok("exception_files (%d) and exception_sites (%d) are reported as distinct, separately labeled numbers -- never both called \"entries\" interchangeably",
      exception_files, exception_sites)

ci_section("Required field validity (no free-text-only whitelist)")
VALID_CLASSES <- c("definitional", "test-baseline", "negative-control", "mutation-harness", "synthetic-fixture")
for (e in DUCKDB_RAW_CONNECTION_EXCEPTIONS) {
  bad <- character(0)
  if (is.null(e$exception_class) || !e$exception_class %in% VALID_CLASSES) bad <- c(bad, "exception_class")
  if (is.null(e$locator) || !nzchar(e$locator)) bad <- c(bad, "locator")
  if (is.null(e$owner) || !nzchar(e$owner)) bad <- c(bad, "owner")
  if (is.null(e$added_date) || !grepl("^\\d{4}-\\d{2}-\\d{2}$", e$added_date)) bad <- c(bad, "added_date")
  if (is.null(e$removal_condition) || !nzchar(e$removal_condition)) bad <- c(bad, "removal_condition")
  if (length(bad)) {
    ci_fail("%s / %s has invalid or missing field(s): %s", e$file, e$tag, paste(bad, collapse = ", "))
  } else {
    ci_ok("%s / %s: exception_class, locator, owner, added_date, removal_condition all well-formed", e$file, e$tag)
  }
}

ci_finish()
