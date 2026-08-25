#!/usr/bin/env Rscript
# =============================================================================
# Does L10 detect a cache identity that is not really an identity?
# =============================================================================
# Seven ways a "cache fingerprint" can exist and mean nothing. Each is planted
# in R/lib/cache_vintage.R and must be killed by L10 itself -- not by an
# unrelated file-not-found, which is why every case asserts the law's own file
# is the one that fails.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
GATE <- file.path(root, "tests", "test_cache_vintage_declared.R")
LIB  <- file.path(root, "R", "lib", "cache_vintage.R")
stopifnot(file.exists(GATE), file.exists(LIB))

caught <- 0L; planted <- 0L; problems <- character(0)
chk <- function(ok, m) { if (isTRUE(ok)) cat(sprintf("  ok   %s\n", m))
  else { problems <<- c(problems, m); cat(sprintf("  FAIL %s\n", m)) } }

cv_run <- function(lib_lines = NULL) {
  dir <- file.path(tempdir(), paste0("cv_", as.integer(stats::runif(1) * 1e9)))
  dir.create(file.path(dir, "tests"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "R", "lib"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(dir, "artifacts"), recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  file.copy(GATE, file.path(dir, "tests", "test_cache_vintage_declared.R"))
  if (is.null(lib_lines)) file.copy(LIB, file.path(dir, "R", "lib", "cache_vintage.R"))
  else writeLines(lib_lines, file.path(dir, "R", "lib", "cache_vintage.R"))
  # enough sidecars that the corpus assertion holds; content is irrelevant here
  for (i in 1:60) writeLines('{"artifact":"x","inputs":[{"path":"a.csv","sha256":"z"}]}',
                             file.path(dir, "artifacts", sprintf("a%02d.csv.provenance.json", i)))
  dir.create(file.path(dir, ".git"), showWarnings = FALSE)
  out <- suppressWarnings(system2("sh",
    c("-c", shQuote(sprintf("cd %s && Rscript tests/test_cache_vintage_declared.R 2>&1",
                            shQuote(dir)))), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  list(text = paste(out, collapse = "\n"), failed = !is.null(st) && st != 0L)
}

# The real library with one behaviour swapped, so the mutation is the defect
# rather than a rewrite that happens to break.
base_lines <- readLines(LIB, warn = FALSE)
swap_fingerprint <- function(body) c(
  base_lines[1:(grep("^geocode_cache_fingerprint <- function", base_lines) - 1)],
  body,
  base_lines[grep("^cache_provenance_entry <- function", base_lines):length(base_lines)])

PRELUDE <- c(
  "geocode_cache_fingerprint <- function(path, table = 'geocoding_cache') {",
  "  absent <- function(reason) list(available = FALSE, reason = reason, path = path,",
  "    n_entries = NA_integer_, content_sha256 = NA_character_,",
  "    schema_fields = NA_character_, snapshot_utc = NA_character_)")

read_rows <- c(
  "  if (!file.exists(path)) return(absent('missing'))",
  "  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = TRUE),",
  "                  error = function(e) NULL)",
  "  if (is.null(con)) return(absent('locked'))",
  "  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)",
  "  if (!table %in% DBI::dbListTables(con)) return(absent('no table'))",
  "  have <- DBI::dbListFields(con, table)")

kills <- function(id, label, lib_lines) {
  planted <<- planted + 1L
  r <- cv_run(lib_lines)
  if (r$failed) caught <<- caught + 1L
  cat(sprintf("[MUTATION] L10 %s %s\n", id, if (r$failed) "DETECTED" else "SURVIVED"))
  chk(r$failed, sprintf("L10  %s", label))
  if (!r$failed) cat("       the law passed; the mutation survived\n")
}

cat("\n-- the unmutated library passes --\n")
r <- cv_run(); chk(!r$failed, "clean scaffold")
if (r$failed) cat(substr(r$text, 1, 1200), "\n")

cat("\n-- planted defects --\n")

kills("identity-from-mtime", "identity taken from mtime instead of content",
  swap_fingerprint(c(PRELUDE,
    "  if (!file.exists(path)) return(absent('missing'))",
    "  list(available = TRUE, reason = NA_character_, path = path, n_entries = 1L,",
    "       content_sha256 = as.character(openssl::sha256(as.character(file.info(path)$mtime))),",
    "       schema_fields = 'mtime', snapshot_utc = NA_character_)",
    "}")))

kills("rows-not-sorted", "rows hashed in table order, so row order becomes identity",
  swap_fingerprint(c(PRELUDE, read_rows,
    "  use <- intersect(CACHE_SCIENTIFIC_FIELDS, have)",
    "  q <- sprintf('SELECT %s FROM %s', paste(sprintf('\"%s\"', use), collapse=', '), table)",
    "  d <- DBI::dbGetQuery(con, q)",
    "  for (cc in intersect(c('latitude','longitude'), names(d))) d[[cc]] <- sprintf('%.6f', as.numeric(d[[cc]]))",
    "  flat <- paste(do.call(paste, c(lapply(d, as.character), sep='|')), collapse='\\n')",
    "  list(available = TRUE, reason = NA_character_, path = path, n_entries = nrow(d),",
    "       content_sha256 = as.character(openssl::sha256(flat)),",
    "       schema_fields = paste(use, collapse=','), snapshot_utc = NA_character_)",
    "}")))

omit_fields <- function(drop) swap_fingerprint(c(PRELUDE, read_rows,
    sprintf("  use <- setdiff(intersect(CACHE_SCIENTIFIC_FIELDS, have), c(%s))",
            paste(sprintf("'%s'", drop), collapse = ", ")),
    "  q <- sprintf('SELECT %s FROM %s ORDER BY %s',",
    "    paste(sprintf('\"%s\"', use), collapse=', '), table,",
    "    paste(sprintf('\"%s\"', use), collapse=', '))",
    "  d <- DBI::dbGetQuery(con, q)",
    "  for (cc in intersect(c('latitude','longitude'), names(d))) d[[cc]] <- sprintf('%.6f', as.numeric(d[[cc]]))",
    "  flat <- paste(do.call(paste, c(lapply(d, as.character), sep='|')), collapse='\\n')",
    "  list(available = TRUE, reason = NA_character_, path = path, n_entries = nrow(d),",
    "       content_sha256 = as.character(openssl::sha256(flat)),",
    "       schema_fields = paste(use, collapse=','), snapshot_utc = NA_character_)",
    "}"))

kills("omits-coordinates", "coordinates left out of the fingerprint",
      omit_fields(c("latitude", "longitude")))
kills("omits-resolution-status", "match type and validation status left out",
      omit_fields(c("match_type", "validation_status")))
kills("omits-source", "the geocoder that produced the answer left out",
      omit_fields(c("geocoder_provenance", "county_fips", "census_tract")))

kills("missing-equals-populated", "an absent cache reported as a valid snapshot",
  swap_fingerprint(c(PRELUDE,
    "  if (!file.exists(path)) return(list(available = TRUE, reason = NA_character_,",
    "    path = path, n_entries = 0L, content_sha256 = strrep('0', 64),",
    "    schema_fields = '', snapshot_utc = NA_character_))",
    base_lines[(grep("^  if \\(!file.exists\\(path\\)\\) return\\(absent", base_lines)[1] + 1):
               (grep("^cache_provenance_entry <- function", base_lines) - 2)],
    "}")))

kills("stale-validates-newer", "one identity for every snapshot",
  swap_fingerprint(c(PRELUDE,
    "  if (!file.exists(path)) return(absent('missing'))",
    "  list(available = TRUE, reason = NA_character_, path = path, n_entries = 1L,",
    "       content_sha256 = strrep('a', 64), schema_fields = 'const',",
    "       snapshot_utc = NA_character_)",
    "}")))

cat(sprintf("\n%d/%d cache-vintage mutations detected\n", caught, planted))
if (length(problems)) {
  cat(sprintf("\nFAILED (%d)\n", length(problems)))
  for (f in problems) cat(sprintf("  - %s\n", f)); quit(status = 1)
}
cat("PASS (0 failures)\n")
