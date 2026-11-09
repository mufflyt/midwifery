#!/usr/bin/env Rscript
# =============================================================================
# build_midwife_panel.R: ten scenarios the real 2007-2026 NPPES file history
# actually contains
# =============================================================================
# Promoted from an ad hoc bug hunt (2026-08-27) run directly against
# build_midwife_panel.R with ten hand-built single-row NPPES snapshots, each
# reproducing one real schema or concurrency hazard the 20-year file history
# is known to contain: an accented name under a plain-ASCII header, a stray
# whitespace byte, a column absent in an older era, fewer taxonomy slots than
# the modern file provides, a lowercase taxonomy code, no recognisable schema
# at all, two files claiming the same year, a renamed-column era, a stale
# lock from a dead process, and a lock genuinely held by a live one.
#
# All ten passed when this was promoted to a permanent test. That is the
# point of keeping it as one: the next NPPES format change is not obligated
# to preserve any of these behaviours, and nothing else in this repository
# would notice if it broke one.
#
# Each case shells out to a real `Rscript build_midwife_panel.R` against a
# fixture under NPPES_HISTORY, exactly the way the script is actually
# invoked, rather than sourcing its internals -- the concurrency cases
# (lock held / stale) are only real if the lock file and the process it
# names are real.

root <- if (basename(getwd()) == "tests") ".." else "."
script <- normalizePath(file.path(root, "build_midwife_panel.R"))
stopifnot(file.exists(script))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

NPPES_HEADER <- paste(
  "NPI", "Entity Type Code", "Provider Last Name (Legal Name)",
  "Provider First Name", "Provider Middle Name", "Provider Credential Text",
  "Provider First Line Business Practice Location Address",
  "Provider Business Practice Location Address City Name",
  "Provider Business Practice Location Address State Name",
  "Provider Business Practice Location Address Postal Code",
  "NPI Deactivation Date", "Healthcare Provider Taxonomy Code_1",
  sep = ",")

run_case <- function(root_dir, out_dir, env = character(0), timeout_s = 60) {
  old_lock <- Sys.getenv("PANEL_REBUILD", unset = NA)
  args <- c(script)
  full_env <- c(
    sprintf("NPPES_HISTORY=%s", root_dir),
    env,
    # Isolate from the caller's own environment so a real PANEL_REBUILD=1 in
    # the runner cannot change what a resume-vs-rebuild case is testing.
    if (is.na(old_lock)) character(0) else sprintf("PANEL_REBUILD=%s", old_lock)
  )
  res <- suppressWarnings(system2(
    "Rscript", args, env = full_env, stdout = TRUE, stderr = TRUE,
    wait = TRUE, timeout = timeout_s
  ))
  list(status = attr(res, "status") %||% 0L, output = paste(res, collapse = "\n"))
}
`%||%` <- function(a, b) if (is.null(a)) b else a

with_case_dir <- function(case_fn) {
  base <- tempfile("panel_bug_hunt_")
  root_dir <- file.path(base, "root")
  out_dir  <- file.path(base, "out")
  dir.create(root_dir, recursive = TRUE)
  dir.create(out_dir, recursive = TRUE)
  owd <- setwd(out_dir); on.exit({ setwd(owd); unlink(base, recursive = TRUE) }, add = TRUE)
  case_fn(root_dir, out_dir)
}

# -----------------------------------------------------------------------------
cat("\n-- Case 1: Latin-1 body under a clean ASCII header --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2010"))
  fp <- file.path(root_dir, "y2010", "npidata_20050523-20100115.csv")
  con <- file(fp, "wb")
  writeBin(charToRaw(paste0(NPPES_HEADER, "\n")), con)
  # MU\xd1OZ, REN\xc9E in real Latin-1 bytes, not UTF-8 -- the point of the case.
  row <- iconv("1000000001,1,MUÑOZ,RENÉE,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X\n",
               from = "UTF-8", to = "latin1")
  writeBin(charToRaw(row), con)
  close(con)
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 1 exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  panel_ok <- file.exists(panel)
  chk(panel_ok, "Case 1 writes midwife_panel.csv")
  if (panel_ok) {
    d <- read.csv(panel, stringsAsFactors = FALSE, encoding = "UTF-8")
    chk(identical(d$last_name, "MUÑOZ"), "Case 1 decodes last_name as MUÑOZ, not mojibake")
    chk(identical(d$first_name, "RENÉE"), "Case 1 decodes first_name as RENÉE, not mojibake")
  }
})

# -----------------------------------------------------------------------------
cat("\n-- Case 2: entity_type_code has a stray leading space --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2011"))
  writeLines(c(NPPES_HEADER,
               "1000000002, 1,SMITH,JANE,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2011", "npidata_20050523-20110301.csv"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 2 exits 0")
  chk(file.exists(file.path(out_dir, "midwife_panel.csv")),
      "Case 2 does not silently drop the row over a whitespace byte")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 3: provider_middle_name column entirely absent --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2012"))
  writeLines(c(
    "NPI,Entity Type Code,Provider Last Name (Legal Name),Provider First Name,Provider Credential Text,Provider First Line Business Practice Location Address,Provider Business Practice Location Address City Name,Provider Business Practice Location Address State Name,Provider Business Practice Location Address Postal Code,NPI Deactivation Date,Healthcare Provider Taxonomy Code_1",
    "1000000003,1,JONES,MARY,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
    file.path(root_dir, "y2012", "npidata_20050523-20120115.csv"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 3 exits 0 with no middle-name column")
  panel <- file.path(out_dir, "midwife_panel.csv")
  panel_ok <- file.exists(panel)
  chk(panel_ok, "Case 3 writes midwife_panel.csv")
  if (panel_ok) {
    d <- read.csv(panel, stringsAsFactors = FALSE)
    chk(identical(d$last_name, "JONES"), "Case 3 still resolves last_name")
  }
})

# -----------------------------------------------------------------------------
cat("\n-- Case 4: only 4 taxonomy slots instead of the modern 15, midwife in slot 2 --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2013"))
  writeLines(c(
    paste0(NPPES_HEADER, ",Healthcare Provider Taxonomy Code_2,Healthcare Provider Taxonomy Code_3,Healthcare Provider Taxonomy Code_4"),
    "1000000004,1,LEE,ANNA,,CNM,1 MAIN ST,DENVER,CO,80202,,208D00000X,367A00000X,,"),
    file.path(root_dir, "y2013", "npidata_20050523-20130115.csv"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 4 exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  chk(file.exists(panel), "Case 4 finds the midwife taxonomy in slot 2, not just slot 1")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 5: lowercase taxonomy code value --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2014"))
  writeLines(c(NPPES_HEADER,
               "1000000005,1,KIM,SUE,,CNM,1 MAIN ST,DENVER,CO,80202,,367a00000x"),
             file.path(root_dir, "y2014", "npidata_20050523-20140115.csv"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 5 exits 0")
  chk(file.exists(file.path(out_dir, "midwife_panel.csv")),
      "Case 5 matches a lowercase taxonomy code, not just uppercase")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 6: no taxonomy columns at all -- must fail loudly, not silently --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2015"))
  writeLines(c(
    "NPI,Entity Type Code,Provider Last Name (Legal Name),Provider First Name,Provider Middle Name,Provider Credential Text",
    "1000000006,1,PARK,LILY,,CNM"),
    file.path(root_dir, "y2015", "npidata_20050523-20150115.csv"))
  r <- run_case(root_dir, out_dir)
  # This is the one case where success IS failure: a schema this unrecognisable
  # must refuse to produce a panel, not silently produce an empty or wrong one.
  chk(r$status != 0L, "Case 6 refuses to run rather than write an empty panel")
  chk(grepl("schema not recognised|No rows were written", r$output),
      "Case 6 names the reason (unrecognised schema), not a bare stack trace")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 7: two files claim the same year, must pick the EARLIER one --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2016"))
  for (d in c("20160901", "20160115")) {
    writeLines(c(NPPES_HEADER,
                 sprintf("1000000007,1,SNAP_%s,X,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X", d)),
               file.path(root_dir, "y2016", sprintf("npidata_20050523-%s.csv", d)))
  }
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 7 exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  panel_ok <- file.exists(panel)
  chk(panel_ok, "Case 7 writes midwife_panel.csv")
  if (panel_ok) {
    d <- read.csv(panel, stringsAsFactors = FALSE)
    chk(identical(d$last_name, "SNAP_20160115"),
        "Case 7 picked the earlier-dated file (20160115), not the later one (20160901)")
  }
})

# -----------------------------------------------------------------------------
cat("\n-- Case 8: legacy snake_case column-name era --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2017"))
  writeLines(c(
    "npi,entity_type_code,provider_last_name_legal_name_,provider_first_name,provider_middle_name,provider_credential_text,provider_first_line_business_practice_location_address,provider_business_practice_location_address_city_name,provider_business_practice_location_address_state_name,provider_business_practice_location_address_postal_code,npi_deactivation_date,healthcare_provider_taxonomy_code_1",
    "1000000008,1,OKAFOR,CHI,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
    file.path(root_dir, "y2017", "npidata_20050523-20170115.csv"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 8 exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  panel_ok <- file.exists(panel)
  chk(panel_ok, "Case 8 writes midwife_panel.csv")
  if (panel_ok) {
    d <- read.csv(panel, stringsAsFactors = FALSE)
    chk(identical(d$last_name, "OKAFOR"), "Case 8 resolves the renamed-era columns")
  }
})

# -----------------------------------------------------------------------------
cat("\n-- Case 9: a stale lock from a dead process must be cleared --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2018"))
  writeLines(c(NPPES_HEADER,
               "1000000009,1,DIAZ,ROSA,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2018", "npidata_20050523-20180115.csv"))
  writeLines("999999999", file.path(out_dir, "midwife_panel.csv.lock"))  # a PID almost certainly not running
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 9 clears a stale lock and runs")
  chk(grepl("clearing stale lock", r$output), "Case 9 says out loud that it cleared a stale lock")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 10: a lock genuinely held by a live process must block --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2019"))
  writeLines(c(NPPES_HEADER,
               "1000000010,1,NGUYEN,LINH,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2019", "npidata_20050523-20190115.csv"))
  # A short-lived but genuinely running process, not a fabricated PID -- the
  # case this is testing (case10_live_lock_blocks, 2026-08-27) used 60s; 5s is
  # enough to still be alive when build_midwife_panel.R checks, and keeps this
  # test from adding a full minute to every CI run.
  #
  # Getting a PID that actually survives took three tries. `system2(sh, c(-c,
  # "sleep 5 & echo $!"))` re-quotes each args element and handed /bin/sleep a
  # mangled argument on this machine. Backgrounding with a trailing `&` inside
  # a command string run via `system(wait = TRUE)` returns the PID of a
  # short-lived wrapper shell that is already dead by the time it is read back
  # -- R's system() appears to clean up the whole process group once its
  # direct child (the wrapper) exits, background job or not. The fix: launch
  # with wait = FALSE (so R never waits on, and therefore never reaps, a
  # process group at all) and have the process report ITS OWN pid via `$$`
  # before `exec`-ing into sleep, so the PID that gets written is the one
  # `sleep` actually keeps, not an intermediate shell's.
  lockfile <- file.path(out_dir, "midwife_panel.csv.lock")
  system(sprintf("sh -c %s",
                  shQuote(sprintf("echo $$ > %s; exec sleep 5", lockfile))),
         wait = FALSE)
  Sys.sleep(0.3)
  sleeper <- as.integer(readLines(lockfile, warn = FALSE)[1])
  on.exit(tryCatch(system(sprintf("kill %d", sleeper), ignore.stdout = TRUE, ignore.stderr = TRUE),
                    error = function(e) NULL), add = TRUE)
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 10 refuses to run against a live-held lock")
  chk(grepl("is held by running process", r$output),
      "Case 10 names the holding process rather than failing silently")
})

# =============================================================================
# Cases 11-30: added 2026-10-19 alongside the fix for the panel's 2023
# vintage. There was no classic npidata_ zip for April 2023 on record
# anywhere this script looks; the real source turned out to be a third NBER
# distribution -- an npi_<Month>_<Year>.parquet + ptax_<Month>_<Year>.parquet
# pair -- that nothing in this script read until today
# (process_core_parquet_year()). Building it exposed a second, unrelated bug
# already latent in the two EXISTING paths: `tax_scope` had been added to
# every SELECT list after the committed panel was last built, so the next
# incremental resume would silently write 14-column rows against the panel's
# real 13-column header. DuckDB's default reader sniffs the column count from
# the existing rows and then drops every row that does not match it, with no
# error under ignore_errors=true -- a real resume run is what caught it.
# Cases 11-12 are permanent regression coverage for that; cases 13-30 cover
# the new parquet path the same way cases 1-10 cover the other two.
# =============================================================================

suppressPackageStartupMessages({library(duckdb); library(DBI)})

write_parquet_fixture <- function(path, df) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  duckdb::duckdb_register(con, "tmp_df", df)
  DBI::dbExecute(con, sprintf("COPY tmp_df TO '%s' (FORMAT PARQUET)", path))
}

# One row of the wide npi_<Month>_<Year>.parquet shape.
core_npi_row <- function(npi, entity = "1", plname = "SMITH", pfname = "JANE",
                         pmname = NA_character_, pcredential = "CNM",
                         plocline1 = "1 MAIN ST", ploccityname = "DENVER",
                         plocstatename = "CO", ploczip = "80202",
                         npideactdatest = as.Date(NA)) {
  data.frame(npi = npi, entity = entity, plname = plname, pfname = pfname,
             pmname = pmname, pcredential = pcredential, plocline1 = plocline1,
             ploccityname = ploccityname, plocstatename = plocstatename,
             ploczip = ploczip, npideactdatest = npideactdatest,
             stringsAsFactors = FALSE)
}

# One row of the wide ptax_<Month>_<Year>.parquet shape: ptaxcode1..15, named
# slots filled via ... (e.g. ptaxcode1 = "367A00000X"), the rest NA.
core_ptax_row <- function(npi, ...) {
  slots <- list(...)
  base <- as.list(stats::setNames(rep(NA_character_, 15), sprintf("ptaxcode%d", 1:15)))
  for (nm in names(slots)) base[[nm]] <- slots[[nm]]
  do.call(data.frame, c(list(npi = npi), base, stringsAsFactors = FALSE))
}

reshaped_fixture <- function(root_dir, year, date6, last_name, npi, taxcode) {
  d <- file.path(root_dir, sprintf("nber_reshaped_%d", year), "byvar")
  dir.create(d, recursive = TRUE)
  f <- function(field, val) writeLines(c(sprintf("npi,%s", field), sprintf("%d,%s", npi, val)),
                                       file.path(d, sprintf("%s_%s.csv", field, date6)))
  f("entity", "Individual")
  f("ptaxcode1", taxcode)
  f("plname", last_name)
}

# -----------------------------------------------------------------------------
cat("\n-- Case 11: resuming onto an existing panel must not change its column count --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2020"))
  writeLines(c(NPPES_HEADER,
               "1000000011,1,FIRST,A,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2020", "npidata_20050523-20200115.csv"))
  r1 <- run_case(root_dir, out_dir)
  chk(r1$status == 0L, "Case 11 first build exits 0")
  dir.create(file.path(root_dir, "y2021"))
  writeLines(c(NPPES_HEADER,
               "1000000012,1,SECOND,B,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2021", "npidata_20050523-20210115.csv"))
  r2 <- run_case(root_dir, out_dir)   # a plain resume, not PANEL_REBUILD=1
  chk(r2$status == 0L, "Case 11 resume build exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  # Strict, no ignore_errors: a column-count mismatch between the two appended
  # blocks throws here instead of silently dropping the second block.
  n <- tryCatch(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM read_csv_auto('%s')", panel))$n,
               error = function(e) NA_integer_)
  chk(!is.na(n) && n == 2L, "Case 11 both resume years strict-parse as 2 rows, not silently truncated")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 12: resuming through the RESHAPED path keeps the same column count --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2020"))
  writeLines(c(NPPES_HEADER,
               "1000000013,1,BASE,A,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2020", "npidata_20050523-20200115.csv"))
  r1 <- run_case(root_dir, out_dir)
  chk(r1$status == 0L, "Case 12 first (classic) build exits 0")
  reshaped_fixture(root_dir, 2025, "202501", "RESHAPED", 1000000014, "367A00000X")
  r2 <- run_case(root_dir, out_dir)
  chk(r2$status == 0L, "Case 12 reshaped resume build exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  n <- tryCatch(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM read_csv_auto('%s')", panel))$n,
               error = function(e) NA_integer_)
  chk(!is.na(n) && n == 2L, "Case 12 classic + reshaped strict-parse together as 2 rows")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 13: core-parquet pair, basic correct ingestion --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000020, plname = "CORE13"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000020, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 13 exits 0")
  panel <- file.path(out_dir, "midwife_panel.csv")
  panel_ok <- file.exists(panel)
  chk(panel_ok, "Case 13 writes midwife_panel.csv from a core-parquet pair")
  if (panel_ok) {
    d <- read.csv(panel, stringsAsFactors = FALSE)
    chk(identical(d$last_name, "CORE13"), "Case 13 resolves last_name from the npi parquet")
    chk(identical(d$practice_state, "CO"), "Case 13 resolves practice_state from the npi parquet")
    chk(identical(d$tax_class, "midwife"), "Case 13 classifies the midwife taxonomy correctly")
    chk(identical(as.character(d$snapshot_date), "20230409"), "Case 13 stamps the pinned April 2023 release day")
  }
})

# -----------------------------------------------------------------------------
cat("\n-- Case 14: npi parquet with no matching ptax sibling must be skipped, not crash --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000021, plname = "ORPHAN"))
  # no ptax_April_2023.parquet written
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 14 refuses to run (no snapshot discovered at all)")
  chk(grepl("no matching ptax_April_2023.parquet -- skipped", r$output),
      "Case 14 names exactly why the pair was skipped")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 15: a core-parquet vintage with no CORE_PARQUET_DAY entry must error, not guess --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_July_2030.parquet"), core_npi_row(1000000022))
  write_parquet_fixture(file.path(cd, "ptax_July_2030.parquet"),
                        core_ptax_row(1000000022, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 15 refuses to run on an unmapped vintage")
  chk(grepl("no entry in CORE_PARQUET_DAY", r$output),
      "Case 15 names the missing lookup entry rather than silently defaulting a release day")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 16: core-parquet organization rows (entity '2') must be excluded --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"), rbind(
    core_npi_row(1000000023, entity = "1", plname = "PERSON"),
    core_npi_row(1000000024, entity = "2", plname = "ORGANIZATION")))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"), rbind(
    core_ptax_row(1000000023, ptaxcode1 = "367A00000X"),
    core_ptax_row(1000000024, ptaxcode1 = "367A00000X")))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 16 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$last_name, "PERSON"),
      "Case 16 keeps only the individual (entity '1'), drops the organization (entity '2')")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 17: core-parquet blank entity must be excluded, not treated as individual --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000025, entity = "", plname = "BLANKENTITY"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000025, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 17 produces zero rows (schema recognised, nothing matched)")
  chk(grepl("0 rows|No rows were written", r$output),
      "Case 17 reports zero matches rather than wrongly admitting a blank-entity row")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 18: core-parquet taxonomy in a non-first slot (ptaxcode5) --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000026, plname = "SLOT5"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000026, ptaxcode1 = "208D00000X", ptaxcode5 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 18 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$tax_class, "midwife"),
      "Case 18 finds the midwife taxonomy in slot 5, not just slot 1")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 19: core-parquet lowercase taxonomy code value --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000027, plname = "LOWER"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000027, ptaxcode1 = "367a00000x"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 19 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$tax_class, "midwife"),
      "Case 19 matches a lowercase taxonomy code, not just uppercase")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 20: core-parquet NULL (DATE-typed) deactivation date must not crash the cast --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000028, plname = "NODEACT", npideactdatest = as.Date(NA)))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000028, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 20 exits 0 on a NULL DATE deactivation column")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE, na.strings = "")
  chk(nrow(d) == 1L && is.na(d$deactivation_date),
      "Case 20 resolves a NULL deactivation date to empty, not 'NA' or an error")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 21: a duplicated npi in the ptax file must not fan one person into two rows --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000029, plname = "DUPTAX"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"), rbind(
    core_ptax_row(1000000029, ptaxcode1 = "367A00000X"),
    core_ptax_row(1000000029, ptaxcode1 = "367A00000X")))   # malformed: npi appears twice
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 21 exits 0 against a malformed, duplicated ptax source")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L, "Case 21 collapses the duplicate join to exactly one row per NPI")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 22: sibling core/ files (core_, othpid_, plic_) are never mistaken for npi_ --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000030, plname = "REALNPI"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000030, ptaxcode1 = "367A00000X"))
  # Decoy files with a different first token -- must not match `^npi_...`.
  write_parquet_fixture(file.path(cd, "core_April_2023.parquet"),
                        data.frame(npi = 1000000030, junk = "DECOY"))
  write_parquet_fixture(file.path(cd, "othpid_April_2023.parquet"),
                        data.frame(npi = 1000000030, junk = "DECOY"))
  write_parquet_fixture(file.path(cd, "plic_April_2023.parquet"),
                        data.frame(npi = 1000000030, junk = "DECOY"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 22 exits 0 with decoy sibling files present")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$last_name, "REALNPI"),
      "Case 22 reads only the real npi_/ptax_ pair, ignoring core_/othpid_/plic_ decoys")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 23: an unmapped tag must not silently borrow a mapped tag's release day --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000031, plname = "MAPPED_APRIL"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000031, ptaxcode1 = "367A00000X"))
  write_parquet_fixture(file.path(cd, "npi_December_2023.parquet"),
                        core_npi_row(1000000032, plname = "UNMAPPED_DECEMBER"))
  write_parquet_fixture(file.path(cd, "ptax_December_2023.parquet"),
                        core_ptax_row(1000000032, ptaxcode1 = "367A00000X"))
  # December_2023 has no CORE_PARQUET_DAY entry (only April_2023 does). The
  # whole run must refuse rather than quietly keeping only the mapped April
  # pair and dropping December without a word -- a silently smaller panel is
  # exactly the failure mode this script's loud-refusal cases 6/10/15 exist
  # to rule out, and two candidates for one year makes it tempting to paper
  # over the unmapped one instead of stopping.
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 23 refuses to run rather than silently dropping the unmapped tag")
  chk(grepl("December_2023", r$output) && grepl("no entry in CORE_PARQUET_DAY", r$output),
      "Case 23 names December_2023 specifically, not a generic failure")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 24: core-parquet vs. a classic zip for the same year -- earliest date wins --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2023classic"))
  writeLines(c(NPPES_HEADER,
               "1000000033,1,CLASSIC_JAN,X,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2023classic", "npidata_20050523-20230108.csv"))
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000034, plname = "PARQUET_APRIL"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000034, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 24 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$last_name, "CLASSIC_JAN"),
      "Case 24 keeps the earlier-dated classic file (Jan) over the later core-parquet one (Apr)")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 25: core-parquet entity with stray whitespace (' 1') still matches --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000035, entity = " 1", plname = "WHITESPACE"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000035, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 25 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$last_name, "WHITESPACE"),
      "Case 25 does not silently drop the row over a whitespace byte in entity")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 26: core-parquet honours PANEL_TAX_SCOPE=wide, not a hardcoded narrow scope --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  # Family NP (363LF0000X): matches the WIDE prefix '363L' but is NOT one of
  # the narrow scope's enumerated NURSING_TAX codes.
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000036, plname = "FAMILYNP"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000036, ptaxcode1 = "363LF0000X"))
  r_narrow <- run_case(root_dir, out_dir)
  chk(r_narrow$status != 0L, "Case 26 narrow scope: Family NP alone matches nothing")
  r_wide <- run_case(root_dir, out_dir, env = "PANEL_TAX_SCOPE=wide")
  chk(r_wide$status == 0L, "Case 26 wide scope: exits 0")
  # Wide scope writes midwife_panel_wide.csv, not midwife_panel.csv -- "the
  # scope is in the filename" is deliberate (TECHNICAL_APPENDIX_TAXONOMY_SCOPE.md
  # SS3), so a wide build can never be picked up silently as the narrow panel.
  panel <- file.path(out_dir, "midwife_panel_wide.csv")
  d <- if (file.exists(panel)) read.csv(panel, stringsAsFactors = FALSE) else NULL
  chk(!is.null(d) && nrow(d) == 1L && identical(d$last_name, "FAMILYNP"),
      "Case 26 wide scope admits the Family NP row the narrow scope rejected")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 27: a three-way mixed build (classic + reshaped + core-parquet) stays consistent --\n")
with_case_dir(function(root_dir, out_dir) {
  dir.create(file.path(root_dir, "y2021"))
  writeLines(c(NPPES_HEADER,
               "1000000037,1,MIXED_CLASSIC,X,,CNM,1 MAIN ST,DENVER,CO,80202,,367A00000X"),
             file.path(root_dir, "y2021", "npidata_20050523-20210115.csv"))
  reshaped_fixture(root_dir, 2022, "202201", "MIXED_RESHAPED", 1000000038, "367A00000X")
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000039, plname = "MIXED_CORE"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000039, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 27 exits 0 across all three source kinds in one run")
  panel <- file.path(out_dir, "midwife_panel.csv")
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  n <- tryCatch(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM read_csv_auto('%s')", panel))$n,
               error = function(e) NA_integer_)
  chk(!is.na(n) && n == 3L, "Case 27 all three rows strict-parse together, same column shape")
  d <- read.csv(panel, stringsAsFactors = FALSE)
  chk(setequal(d$last_name, c("MIXED_CLASSIC", "MIXED_RESHAPED", "MIXED_CORE")),
      "Case 27 every source kind's row survived with its distinct identity intact")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 28: core-parquet with zero taxonomy-matching rows must be skipped gracefully --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000040, plname = "NOMATCH"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000040, ptaxcode1 = "208D00000X"))  # unrelated specialty
  r <- run_case(root_dir, out_dir)
  chk(r$status != 0L, "Case 28 produces no panel (nothing in scope matched)")
  chk(grepl("No rows were written", r$output),
      "Case 28 reports the zero-match outcome cleanly rather than a bare crash")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 29: core-parquet nursing-only taxonomy classifies as 'nursing', not 'midwife' --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"),
                        core_npi_row(1000000041, plname = "RNONLY"))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000041, ptaxcode1 = "163W00000X"))  # RN, in narrow scope
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 29 exits 0 (RN is in the narrow panel's nursing scope)")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE)
  chk(nrow(d) == 1L && identical(d$tax_class, "nursing"),
      "Case 29 classifies a bare RN taxonomy as nursing, not midwife")
})

# -----------------------------------------------------------------------------
cat("\n-- Case 30: CORE_PARQUET_DAY produces the exact pinned 2023 release date --\n")
with_case_dir(function(root_dir, out_dir) {
  cd <- file.path(root_dir, "core"); dir.create(cd, recursive = TRUE)
  write_parquet_fixture(file.path(cd, "npi_April_2023.parquet"), core_npi_row(1000000042))
  write_parquet_fixture(file.path(cd, "ptax_April_2023.parquet"),
                        core_ptax_row(1000000042, ptaxcode1 = "367A00000X"))
  r <- run_case(root_dir, out_dir)
  chk(r$status == 0L, "Case 30 exits 0")
  d <- read.csv(file.path(out_dir, "midwife_panel.csv"), stringsAsFactors = FALSE,
               colClasses = "character")
  chk(identical(d$snapshot_year, "2023"), "Case 30 snapshot_year is 2023, parsed from the tag")
  chk(identical(d$snapshot_date, "20230409"),
      "Case 30 snapshot_date is exactly 20230409 -- the day already published")
})

# =============================================================================
cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
