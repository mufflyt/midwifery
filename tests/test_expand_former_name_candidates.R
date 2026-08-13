#!/usr/bin/env Rscript
# =============================================================================
# Former/maiden-surname candidate expansion -- tests
# =============================================================================
# Locks in the rescue accounting for expand_amcb_former_name_candidates():
# a record with no NPPES candidate under its CURRENT surname is pulled into
# the candidate universe under a FORMER surname, tagged by which surname path
# reached it, and counted -- without ever being declared a match here.
#
# Fixture (4 AMCB x 4 NPPES):
#   A1 SMITH   (matched)      -> current-surname candidate exists, not a rescue
#   A2 WILLIAMS, nee JONES    -> no current candidate; JONES -> 1 NPI (rescued)
#   A3 LEE, nee BAKER; CHURCH -> no current candidate; 2 NPIs (rescued, multi)
#   A4 STONE   (no former)    -> no candidate anywhere (still_no_candidate)
#
# Run: Rscript tests/test_expand_former_name_candidates.R   (exit 1 on failure)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(stringi)
  library(tidyr); library(scales); library(tibble)
})
source(file.path(root, "expand_former_name_candidates.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

amcb_roster <- tibble::tibble(
  amcb_id = c("A1", "A2", "A3", "A4"),
  first_name = c("JANE", "MARY", "ANNA", "RUTH"),
  last_name = c("SMITH", "WILLIAMS", "LEE", "STONE"),
  former_last_name = c("", "JONES", "BAKER; CHURCH", ""),
  match_status = c("matched", "no_candidate", "no_candidate", "no_candidate")
)

nppes_names <- tibble::tibble(
  npi = c("1", "2", "3", "4"),
  provider_first_name = c("JANE", "MARY", "ANNA", "ANNA"),
  provider_last_name = c("SMITH", "JONES", "BAKER", "CHURCH")
)

res <- expand_amcb_former_name_candidates(
  amcb_people = amcb_roster,
  nppes_people = nppes_names,
  nppes_first_col = "provider_first_name",
  nppes_last_col = "provider_last_name"
)

rs <- res$rescue_summary
g <- function(m) rs$n[rs$metric == m]

cat("\n-- rescue summary counts --\n")
chk(g("original_no_candidate") == 3, "3 records start with no current-surname candidate")
chk(g("rescued_into_candidate_universe") == 2, "2 rescued via a former surname")
chk(g("rescued_with_one_candidate") == 1, "1 rescued to exactly one NPI")
chk(g("rescued_with_multiple_candidates") == 1, "1 rescued to multiple NPIs")
chk(g("still_no_candidate") == 1, "1 remains with no candidate at all")

ps <- res$person_status
status_of <- function(id) ps$rescue_status[ps$.amcb_id == id]

cat("\n-- per-person provenance --\n")
chk(status_of("A1") == "current_name_candidate_exists",
    "already-matched person is not counted as a rescue")
chk(status_of("A2") == "former_name_one_candidate",
    "WILLIAMS/nee JONES rescued to a single NPI")
chk(status_of("A3") == "former_name_multiple_candidates",
    "LEE/nee BAKER;CHURCH rescued to multiple NPIs")
chk(status_of("A4") == "still_no_candidate",
    "STONE with no former name stays unrescued")

cat("\n-- block-source provenance is preserved --\n")
cp <- res$candidate_pairs
chk(all(c("current_surname", "former_surname") %in% cp$candidate_block_source),
    "candidate_block_source distinguishes current vs former paths")
chk(!isTRUE(any(res$person_status$rescued_by_former_surname &
                (res$person_status$.existing_status == "matched"))),
    "a rescue never overwrites an already-matched record")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
