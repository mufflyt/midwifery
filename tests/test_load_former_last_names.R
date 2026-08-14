#!/usr/bin/env Rscript
# =============================================================================
# External former-surname ingest -- tests
# =============================================================================
# Confirms attach_former_last_names() normalizes an external former/maiden
# export onto certification_number (long OR wide shape), de-duplicates and
# collapses per person, leaves the roster otherwise intact, and -- the point of
# the whole thing -- that its output drops straight into
# expand_amcb_former_name_candidates() and produces the expected rescues.
#
# Run: Rscript tests/test_load_former_last_names.R   (exit 1 on any failure)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(stringi)
  library(tidyr); library(tibble)
})
source(file.path(root, "load_former_last_names.R"))
source(file.path(root, "expand_former_name_candidates.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

roster <- tibble::tibble(
  certification_number = c("C1", "C2", "C3", "C4"),
  first_name = c("JANE", "MARY", "ANNA", "RUTH"),
  middle_name = c("Q", "", "", ""),
  last_name = c("SMITH", "WILLIAMS", "LEE", "STONE")
)

# --- long shape: one row per (id, former surname) ----------------------------
long_src <- tibble::tibble(
  certification_number = c("C2", "C3", "C3", "C3", "C2", "X9"),
  former_last_name = c("Jones", "Baker", "Church", "baker", "WILLIAMS", "Ghost")
)

attached <- attach_former_last_names(roster, long_src)
former_of <- function(id) attached$former_last_name[attached$certification_number == id]

cat("\n-- long-shape ingest --\n")
chk(nrow(attached) == 4, "roster row count unchanged (external-only ids dropped)")
chk(former_of("C3") == "BAKER; CHURCH", "multiple formers collapsed, case-deduped, upper-cased")
chk(grepl("JONES", former_of("C2")) && grepl("WILLIAMS", former_of("C2")),
    "all of a person's formers are gathered")
chk(is.na(former_of("C1")) && is.na(former_of("C4")), "no-former rows are NA")
chk(!"X9" %in% attached$certification_number, "id absent from roster is not introduced")
chk(all(c("first_name", "last_name") %in% names(attached)), "roster columns preserved")

# --- wide shape: several former-name columns in one row ----------------------
wide_src <- tibble::tibble(
  certification_number = c("C2", "C3"),
  maiden_name = c("Jones", "Baker"),
  former_last_name_2 = c(NA, "Church")
)
attached_wide <- attach_former_last_names(
  roster, wide_src,
  source_former_cols = c("maiden_name", "former_last_name_2")
)
fw <- function(id) attached_wide$former_last_name[attached_wide$certification_number == id]
cat("\n-- wide-shape ingest --\n")
chk(fw("C2") == "JONES", "single former from a wide row")
chk(fw("C3") == "BAKER; CHURCH", "multiple former columns gathered from one row")

# --- guard -------------------------------------------------------------------
cat("\n-- guard --\n")
err <- tryCatch({
  attach_former_last_names(roster, tibble::tibble(certification_number = "C2"))
  FALSE
}, error = function(e) TRUE)
chk(err, "missing former-name column raises a clear error")

# --- end to end: attach -> expand rescues the no-candidate rows ---------------
nppes <- tibble::tibble(
  npi = c("1", "2", "3", "4"),
  provider_first_name = c("JANE", "MARY", "ANNA", "ANNA"),
  provider_last_name = c("SMITH", "JONES", "BAKER", "CHURCH")   # note: no WILLIAMS/LEE/STONE
)
res <- expand_amcb_former_name_candidates(
  amcb_people = attached,
  nppes_people = nppes,
  amcb_id_col = "certification_number",   # the roster's id column
  nppes_first_col = "provider_first_name",
  nppes_last_col = "provider_last_name"
)
g <- function(m) res$rescue_summary$n[res$rescue_summary$metric == m]
cat("\n-- attach -> expand end to end --\n")
chk(g("original_no_candidate") == 3, "C2/C3/C4 have no current-surname candidate")
chk(g("rescued_into_candidate_universe") == 2, "C2 (Jones) and C3 (Baker/Church) rescued via former name")
chk(g("still_no_candidate") == 1, "C4 (Stone, no former) stays unrescued")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
