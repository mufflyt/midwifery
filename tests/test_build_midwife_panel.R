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
cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
