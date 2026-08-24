#!/usr/bin/env Rscript
# =============================================================================
# Scientific invariants that CI must enforce
# =============================================================================
#
# Every check here exists because the corresponding defect ACTUALLY OCCURRED in
# this project, survived review, and reached an artifact or a reported number.
# None is hypothetical. A test that cannot name the bug it prevents is a test
# that will be deleted the first time it is inconvenient.
#
#   G1  A "license number" that encodes the certification_number is not
#       observed licensure evidence. 11,355 rows of
#       {STATE}-RN-APRN-{certification_number} were summarised into per-state
#       board-verification counts and a 74%-coverage claim.
#
#   G2  Surname comparison must never be substring containment. "Anderson"
#       matched "Sanderson" on a live roster and wrote wrong certificant rows.
#
#   G3  A frozen truth artifact must not contain matcher outcomes. Truth that
#       carries the arm's own candidate counts cannot adjudicate that arm.
#
#   G4  The identity linkage must not consume board-license fields. That
#       boundary is what kept the BON provenance defect out of the NPI results;
#       it holds today and must keep holding.
#
# Row-level inputs are gitignored, so data-dependent checks resolve through
# MIDWIFERY_TEST_DATA_DIR and SKIP loudly when it is unset -- never silently.
# =============================================================================

suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("tests", "helper-external-data.R"))

fails <- 0L
ok   <- function(m) cat(sprintf("  ok   %s\n", m))
bad  <- function(m) { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
chk  <- function(cond, m) if (isTRUE(cond)) ok(m) else bad(m)
skip <- function(m) cat(sprintf("  SKIP %s\n", m))

# =============================================================================
cat("\n-- G1: derived identifiers must not pose as observed evidence --\n")
# =============================================================================
# GUARD THE GENERATOR, NOT THE OUTPUT. The BON artifacts are gitignored, so a
# data-level check would SKIP forever in CI and protect nothing. The defect was
# in tracked source: a line that builds a "license number" out of the row's own
# certification_number. That line is greppable and always present in CI.
#
# KNOWN OFFENDERS are registered, not hidden. They still emit synthesised
# identifiers and must be fixed; registering them here means a THIRD instance
# fails the build instead of blending in, and the count is reprinted on every
# run so it cannot be quietly forgotten.
DERIVED_ID_PATTERN <- "license[a-z_]*\"?\\]?\\s*=.*certification_number"
KNOWN_DERIVED_ID_OFFENDERS <- c(
  "harvest_all_tier1_live_bon_datasets.py",   # tier1_license_number
  "scrape_20_more_state_bons.py"              # scraped_license_num
)

# Prove the detector can fail: a synthetic offender must be caught. A guard
# that has never been shown to fire is not evidence of anything.
.synthetic <- 'r["tier1_license_number"] = f"{st}-RN-CNM-{r.get(\'certification_number\')}"'
chk(grepl(DERIVED_ID_PATTERN, .synthetic),
    "detector fires on a synthetic derived-identifier line (negative control)")

src <- c(list.files(".", pattern = "[.](R|py)$", full.names = FALSE),
         list.files("R", pattern = "[.]R$", full.names = TRUE))
hits <- character(0)
for (f in src) {
  txt <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
  code <- txt[!grepl("^\\s*#", txt)]
  if (any(grepl(DERIVED_ID_PATTERN, code))) hits <- c(hits, f)
}
new_hits <- setdiff(basename(hits), KNOWN_DERIVED_ID_OFFENDERS)
chk(length(new_hits) == 0,
    sprintf("no NEW source builds a license identifier from certification_number%s",
            if (length(new_hits)) paste0(" -- found: ", paste(new_hits, collapse = ", ")) else ""))
cat(sprintf("  note registered offenders still present: %d (%s) -- must be fixed\n",
            length(intersect(basename(hits), KNOWN_DERIVED_ID_OFFENDERS)),
            paste(intersect(basename(hits), KNOWN_DERIVED_ID_OFFENDERS), collapse = ", ")))

# Opportunistic data check: runs only when the row-level artifacts are supplied.
lic_files <- Filter(file.exists, vapply(c(
  "artifacts/tier1_live_bon_all_states_complete.csv",
  "artifacts/scraped_20_state_bons_midwives_master.csv"), mw_data_path, character(1)))
if (!length(lic_files)) {
  skip("G1 data-level check: BON artifacts not supplied (set MIDWIFERY_TEST_DATA_DIR)")
} else {
  for (f in lic_files) {
    d <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE, n_max = 20000))
    for (lc in grep("licen", names(d), ignore.case = TRUE, value = TRUE)) {
      if (!"certification_number" %in% names(d)) next
      v <- as.character(d[[lc]]); k <- as.character(d$certification_number)
      keep <- !is.na(v) & !is.na(k) & nzchar(v) & nzchar(k)
      if (!any(keep)) next
      chk(mean(str_detect(v[keep], fixed(k[keep]))) < 0.5,
          sprintf("%s$%s does not embed certification_number", basename(f), lc))
    }
  }
}

# =============================================================================
cat("\n-- G2: surname matching must reject containment --\n")
# =============================================================================
# The scraper attaches its packages and then calls
# load_isochrones_name_tools() at top level, which reads ~/isochrones. That
# repository is PRIVATE and this CI is public, so on a runner the source()
# stops and takes G3 and G4 down with it -- three invariants lost to one
# unavailable sibling.
#
# So the load is guarded and the failure is a LOUD SKIP, which is the class
# tests/ci_nightly_exceptions.txt already calls `external-private` and which
# four other suites in this repository are registered under. It runs for real
# wherever the checkout exists: locally, and in any CI given a deploy key.
#
# This is NOT the tryCatch-that-hides-a-bug: a missing package was installable
# and was installed, whereas a private repository a public runner has no
# credentials for is a fact about the environment, not about the code.
if (!file.exists("scrape_healthgrades_midwives.R")) {
  skip("G2 scraper absent")
} else if (inherits(try(suppressWarnings(suppressMessages(
             invisible(capture.output(source("scrape_healthgrades_midwives.R"))))),
           silent = TRUE), "try-error")) {
  skip("G2 matcher unavailable: scrape_healthgrades_midwives.R needs the private ~/isochrones checkout (set ISOCHRONES_HOME). The seven pinned false matches are NOT checked in this run.")
} else {
  if (!exists("name_matches_roster", mode = "function")) {
    bad("G2 name_matches_roster() is not defined -- the matcher lost its entry point")
  } else {
    # observed false matches: each wrote a wrong certificant row in production
    chk(!name_matches_roster("Laura Sanderson, CNM", "Laura", "Anderson"),
        "ANDERSON must not match SANDERSON (observed false match)")
    chk(!name_matches_roster("Jessica Williamson, CNM", "Jessica", "Williams"),
        "WILLIAMS must not match WILLIAMSON (observed false match)")
    chk(!name_matches_roster("Elizabeth Martinez, CNM", "Elizabeth Jean", "Martin"),
        "MARTIN must not match MARTINEZ (observed false match)")
    chk(!name_matches_roster("Melinda Jones, CNM", "Linda A.", "Jones"),
        "LINDA must not match MELINDA (observed false match, given name)")
    # legitimate variation that must survive: losing these is a silent recall cut
    chk(name_matches_roster("Carolyn Nelson-Becker, CNM", "Carolyn", "Nelson"),
        "married/hyphenated surname must still match")
    chk(name_matches_roster("Sherece Dyer Hill, CNM", "Sherece", "Dyer"),
        "unhyphenated compound surname must still match")
    chk(name_matches_roster("Michele Oconnor, CNM", "Michele", "O’Connor"),
        "apostrophe variation must still match")
  }
}

# =============================================================================
cat("\n-- G3: frozen truth must carry no matcher outcomes --\n")
# =============================================================================
truth_files <- Sys.glob(c("artifacts/*truth_frozen.csv", "*truth_frozen.csv"))
if (!length(truth_files)) {
  skip("G3 no frozen truth artifact in this checkout")
} else {
  forbidden <- "candidate|retained|accepted_npi|arm_|_rank|false_|unique_|ambiguity"
  for (f in truth_files) {
    nm <- names(read_csv(f, show_col_types = FALSE, progress = FALSE, n_max = 1))
    hit <- grep(forbidden, nm, ignore.case = TRUE, value = TRUE)
    chk(length(hit) == 0,
        sprintf("%s carries no outcome columns%s", basename(f),
                if (length(hit)) paste0(" -- found: ", paste(hit, collapse = ", ")) else ""))
  }
}

# =============================================================================
cat("\n-- G4: identity linkage must not consume board-license fields --\n")
# =============================================================================
# The BON provenance defect did not reach the NPI results BECAUSE this boundary
# held. It is not self-enforcing; a single join would erase it.
linkage_src <- Filter(file.exists, c("match_amcb_to_npi.R", "reconcile_linkage.R",
                                     "build_midwife_panel.R",
                                     list.files("R", pattern = "[.]R$", full.names = TRUE)))
bon_fields <- c("tier1_license_number", "scraped_license_num",
                "bon_verification_status", "tier1_verification_source")
offenders <- character(0)
for (f in linkage_src) {
  txt <- readLines(f, warn = FALSE)
  code <- txt[!grepl("^\\s*#", txt)]          # comments may discuss it; code may not use it
  if (any(sapply(bon_fields, function(b) any(grepl(b, code, fixed = TRUE))))) {
    offenders <- c(offenders, f)
  }
}
chk(length(offenders) == 0,
    sprintf("no linkage source consumes BON license fields%s",
            if (length(offenders)) paste0(" -- found in: ", paste(offenders, collapse = ", ")) else ""))

# =============================================================================
cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES", fails,
            if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
