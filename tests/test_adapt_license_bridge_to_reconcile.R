#!/usr/bin/env Rscript
# =============================================================================
# License-bridge -> reconcile adapter -- tests
# =============================================================================
# Confirms the deterministic license outcome projects onto reconcile's
# vocabulary so that reconcile_linkage.R's state_of() buckets each row as
# intended: license_exact -> matched; surname-conflict / collision / prior-
# conflict -> ^ambiguous (quarantined); everything else -> unmatched. Matched
# rows carry npi + method; non-matched rows carry no npi.
#
# Run: Rscript tests/test_adapt_license_bridge_to_reconcile.R  (exit 1 on fail)
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}

suppressPackageStartupMessages({ library(dplyr); library(tibble) })
source(file.path(root, "adapt_license_bridge_to_reconcile.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# reconcile_linkage.R's classifier, reproduced so we test the contract it uses.
reconcile_state_of <- function(status) dplyr::case_when(
  status == "matched" ~ "matched",
  grepl("^ambiguous", status) ~ "quarantined",
  TRUE ~ "unmatched"
)

crosswalk <- tibble::tibble(
  certification_number = c("C1", "C2", "C3", "C4", "C5", "C6"),
  deterministic_npi = c("N1", NA, NA, "N4", NA, NA),
  linked_npi = c("N1", NA, NA, NA, "N5", NA),
  linkage_method = c(
    "license_exact",                     # C1 clean license match
    "unresolved",                        # C2 surname conflict (not accepted)
    "unresolved",                        # C3 collision (not accepted)
    "license_exact_conflicts_with_prior",# C4 license vs prior disagree
    "prior_match",                       # C5 retained prior link
    "unresolved"                         # C6 no license at all
  ),
  deterministic_status = c(
    "license_exact",
    "license_match_surname_conflict",
    "license_conflict",
    "license_exact",
    "no_license_available",
    "no_license_available"
  )
)

out <- adapt_license_bridge_to_reconcile(crosswalk)
st <- function(id) out$npi_match_status[out$certification_number == id]
npi <- function(id) out$npi[out$certification_number == id]
meth <- function(id) out$npi_match_method[out$certification_number == id]

cat("\n-- status projection --\n")
chk(st("C1") == "matched", "license_exact -> matched")
chk(st("C2") == "ambiguous_license_surname_conflict", "surname conflict -> ambiguous")
chk(st("C3") == "ambiguous_license_collision", "collision -> ambiguous")
chk(st("C4") == "ambiguous_license_prior_conflict", "prior disagreement -> ambiguous")
chk(st("C5") == "matched", "retained prior link -> matched")
chk(st("C6") == "unmatched", "no license -> unmatched")

cat("\n-- npi / method carried only when matched --\n")
chk(npi("C1") == "N1" && meth("C1") == "license_exact", "matched row carries npi + method")
chk(npi("C5") == "N5" && meth("C5") == "prior_match", "prior match carries npi + method")
chk(all(is.na(c(npi("C2"), npi("C3"), npi("C4"), npi("C6")))), "non-matched rows carry no npi")

cat("\n-- reconcile's state_of() buckets as intended --\n")
chk(reconcile_state_of(st("C1")) == "matched", "C1 -> matched")
chk(all(reconcile_state_of(c(st("C2"), st("C3"), st("C4"))) == "quarantined"),
    "the three ambiguous kinds -> quarantined")
chk(reconcile_state_of(st("C6")) == "unmatched", "C6 -> unmatched")

cat("\n-- structure + guard --\n")
chk(identical(sort(names(out)),
              sort(c("certification_number", "npi_match_status", "npi", "npi_match_method"))),
    "returns exactly the four merge columns")
chk(nrow(out) == nrow(crosswalk), "one row per certificant, none dropped")
err <- tryCatch({ adapt_license_bridge_to_reconcile(tibble::tibble(certification_number = "X")); FALSE },
                error = function(e) TRUE)
chk(err, "missing required columns raises a clear error")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
