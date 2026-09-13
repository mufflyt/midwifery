#!/usr/bin/env Rscript
# =============================================================================
# Three populations, three definitions: R/lib/cohort_definitions.R
# =============================================================================
# The 11,093-row tracked roster was being read as "the active midwife
# cohort". It is the 2026-08-10 freeze's 11,920 ACTIVE, primary-linked
# certificants restricted to the 40 states of a fabricated board "scrape"
# (reconcile_trilliant_cohort.R: 787 in 11 other jurisdictions, 40 at military,
# territorial or foreign addresses, 0 unexplained). Used as a denominator for a
# CMS hospital-affiliation analysis, it would have dropped every midwife in NJ,
# AK, RI, VT, DC, WV, DE, HI, SD, ND and WY -- people CMS observes perfectly
# well -- because of a board dataset that has nothing to do with CMS.
#
# These tests pin the separation: the canonical cohort is defined once, each
# subset is taken from it, and board coverage cannot shrink the CMS subset.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "cohort_definitions.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}
cohort_refuses <- function(expr) inherits(try(expr, silent = TRUE), "try-error")

linkage <- data.frame(
  certification_number = c("A1", "A2", "A3", "A4", "A5", "A6", "A7", "A7"),
  status       = c("ACTIVE", "ACTIVE", "ACTIVE", "RETIRED", "ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE"),
  linkage_tier = c("primary_midwifery", "primary_midwifery", "primary_midwifery", "primary_midwifery",
                   "sensitivity_nursing", "primary_midwifery", "primary_midwifery", "primary_midwifery"),
  npi          = c("1000000001", "1000000002", "1000000003", "1000000004",
                   "1000000005", "", "1000000007", "1000000007"),
  nppes_state  = c("WA", "NJ", "FL", "WA", "TX", "CO", "AE", "AE"),
  stringsAsFactors = FALSE)

cat("\n-- CANONICAL COHORT --\n")
coh <- canonical_active_primary(linkage)
chk(setequal(coh$certification_number, c("A1", "A2", "A3", "A7")),
    "T1 ACTIVE + primary_midwifery + an NPI, and nothing else")
chk(!"A4" %in% coh$certification_number, "T2 a RETIRED certificant is not in the cohort")
chk(!"A5" %in% coh$certification_number, "T3 a sensitivity-tier link is not in the cohort")
chk(!"A6" %in% coh$certification_number, "T4 a blank NPI is not in the cohort")
chk(sum(coh$certification_number == "A7") == 1L,
    "T5 a certificant listed twice with the SAME NPI is counted once")
chk("A7" %in% coh$certification_number,
    "T6 a military (AE) address stays in the canonical cohort")
conflict <- rbind(linkage, data.frame(certification_number = "A1", status = "ACTIVE",
                                      linkage_tier = "primary_midwifery", npi = "1999999999",
                                      nppes_state = "WA"))
chk(cohort_refuses(canonical_active_primary(conflict)),
    "T7 one certificant with two different NPIs stops instead of keeping a row by file order")
chk(cohort_refuses(canonical_active_primary(linkage[, -5])), "T8 a missing nppes_state column stops")

cat("\n-- BOARD-VALIDATION SUBSET --\n")
bv <- board_validation_eligible(coh)
chk(setequal(bv$certification_number, "A1"), "T9 only WA/CO/TX members are board-eligible")
chk(!"A3" %in% bv$certification_number,
    "T10 FL is not board-covered: the 40-state list was a fabricated scrape, not coverage")
chk(all(bv$certification_number %in% coh$certification_number), "T11 board subset is inside the cohort")
chk(identical(GENUINE_BOARD_STATES, c("WA", "CO", "TX")),
    "T12 the genuinely queried boards are exactly WA, CO, TX (changing this needs a real harvest)")

cat("\n-- CMS DAC SUBSET --\n")
dac_npis <- c("1000000001", "1000000002", "1000000007", "1000000004")
cms <- cms_dac_observed(coh, dac_npis)
chk(setequal(cms$certification_number, c("A1", "A2", "A7")),
    "T13 canonical members whose NPI CMS lists, and only them")
chk("A2" %in% cms$certification_number,
    "T14 a NJ midwife CMS observes is in the CMS subset although no NJ board was queried")
chk(!"A4" %in% cms$certification_number,
    "T15 a DAC-listed NPI outside the cohort (RETIRED) is not pulled in")
chk(nrow(cms_dac_observed(coh, dac_npis)) >= nrow(cms_dac_observed(bv, dac_npis)),
    "T16 restricting to board states first can only lose CMS-observed midwives -- which is why the CMS subset is taken from the cohort")
chk(nrow(cms_dac_observed(coh, as.numeric(dac_npis))) == nrow(cms),
    "T17 numeric NPIs from a DAC read match the character cohort NPIs")

cat("\n-- FREEZE CHECK --\n")
tmp <- tempfile(fileext = ".csv"); writeLines("a,b\n1,2", tmp)
man <- tempfile(fileext = ".json")
jsonlite::write_json(list(artifact_sha256 = digest::digest(file = tmp, algo = "sha256"),
                          artifact_rows = 1L), man, auto_unbox = TRUE)
chk(!cohort_refuses(verify_linkage_freeze(tmp, man, allow_sha256 = "")), "T18 the manifest's own file passes")
writeLines("a,b\n1,3", tmp)
chk(cohort_refuses(verify_linkage_freeze(tmp, man, allow_sha256 = "")), "T19 any other file stops")
chk(!cohort_refuses(verify_linkage_freeze(tmp, man, allow_sha256 = digest::digest(file = tmp, algo = "sha256"))),
    "T20 ...unless it is named on purpose")

cat("\n-- TRANSITIONS BETWEEN FREEZES --\n")
old <- data.frame(
  certification_number = c("B1", "B2", "B3", "B4", "B5", "B6", "B7"),
  status       = c("ACTIVE", "ACTIVE", "LAPSED", "ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE"),
  linkage_tier = c("primary_midwifery", "primary_midwifery", "primary_midwifery", "unmatched",
                   "primary_midwifery", "primary_midwifery", "primary_midwifery"),
  npi = c("1", "2", "3", "", "5", "6", "7"), nppes_state = "WA", stringsAsFactors = FALSE)
new <- data.frame(
  certification_number = c("B1", "B2", "B3", "B4", "B5", "B6", "B8"),
  status       = c("ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "RETIRED", "ACTIVE", "ACTIVE"),
  linkage_tier = c("primary_midwifery", "primary_midwifery", "primary_midwifery", "primary_midwifery",
                   "primary_midwifery", "sensitivity_fuzzy", "primary_midwifery"),
  npi = c("1", "22", "3", "4", "5", "6", "8"), nppes_state = "WA", stringsAsFactors = FALSE)
tr <- cohort_transition_reasons(old, new)
r <- stats::setNames(tr$reason, tr$certification_number)
chk(r[["B1"]] == "in both, same NPI", "T21 unchanged")
chk(r[["B2"]] == "in both, NPI changed", "T22 same person, different NPI is flagged, not hidden")
chk(r[["B3"]] == "joined: status became ACTIVE", "T23 a renewal joins")
chk(r[["B4"]] == "joined: link became primary", "T24 a new NPI candidate joins")
chk(r[["B5"]] == "left: status no longer ACTIVE", "T25 a retirement leaves")
chk(r[["B6"]] == "left: link no longer primary", "T26 a demoted link leaves")
chk(r[["B7"]] == "left: gone from the AMCB roster", "T27 dropped from the directory")
chk(r[["B8"]] == "joined: new to the AMCB roster", "T28 new certificant")
chk(nrow(tr) == length(union(canonical_active_primary(old)$certification_number,
                             canonical_active_primary(new)$certification_number)) &&
      !anyNA(tr$reason),
    "T29 every certificant in either cohort gets exactly one reason")
chk(sum(tr$in_new) - sum(tr$in_old) ==
      sum(startsWith(tr$reason, "joined")) - sum(startsWith(tr$reason, "left")),
    "T30 joined minus left equals the change in cohort size")

cat(if (fails) sprintf("\nFAILURES (%d)\n", fails) else "\nPASS (0 failures)\n")
quit(status = if (fails) 1L else 0L)
