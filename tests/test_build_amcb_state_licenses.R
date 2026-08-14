#!/usr/bin/env Rscript
# =============================================================================
# Tests for build_amcb_state_licenses()
# =============================================================================
# The bridge this builds becomes IDENTITY EVIDENCE downstream, so the tests
# concentrate on the ways a wrong licence could enter it:
#   * a national-tier match writing the certificant's state instead of the
#     board's, fabricating a (state, licence) key that names someone else;
#   * two people sharing a key inside one board file being silently collapsed;
#   * ambiguity being resolved rather than deferred.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr)
})
source("R/build_amcb_state_licenses.R")

FAILS <- character(0)
ok <- function(name, cond) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", name))
  else { FAILS <<- c(FAILS, name); cat(sprintf("  FAIL  %s\n", name)) }
}

td <- file.path(tempdir(), paste0("bridge_", as.integer(Sys.time())))
bd <- file.path(td, "boards")
dir.create(bd, recursive = TRUE, showWarnings = FALSE)

# C1 exact first+middle+last+state, unique             -> tier 1
# C2 no middle name, unique in state                   -> tier 2
# C3 two same-name licensees in CO                     -> ambiguous, deferred
# C4 lives in CO, only licence is in TX, unique name   -> tier 3, CROSS-STATE
# C5 no licence anywhere                               -> unresolved
write_csv(tibble(
  certification_number = paste0("C", 1:5),
  first_name = c("ANNA","BETH","CARA","DELIA","EVE"),
  middle_name = c("MAE", NA, NA, NA, NA),
  last_name = c("ADAMS","BROOKS","COLE","DIAZ","EVANS"),
  state = c("CO","CO","CO","CO","CO")), file.path(td, "amcb.csv"))

write_csv(tibble(
  first_name = c("ANNA","BETH","CARA","CARA"),
  middle_name = c("MAE", NA, NA, NA),
  last_name = c("ADAMS","BROOKS","COLE","COLE"),
  license_number = c("111","222","333","444"),
  license_state = c("CO","CO","CO","CO"),
  license_status = "ACTIVE", license_type = "CNM"),
  file.path(bd, "CO.csv"))

write_csv(tibble(
  first_name = "DELIA", middle_name = NA, last_name = "DIAZ",
  license_number = "999", license_state = "TX",
  license_status = "ACTIVE", license_type = "CNM"),
  file.path(bd, "TX.csv"))

res <- build_amcb_state_licenses(amcb_path = file.path(td, "amcb.csv"),
                                 board_dir = bd, destination_dir = td)
b <- res$bridge
gb <- function(id) b[b$amcb_id == id, ]

cat("\n=== tiered acceptance ===\n")
ok("C1 accepted on first+middle+last+state",
   nrow(gb("C1")) == 1L && gb("C1")$match_tier == "exact_first_middle_last_state")
ok("C2 accepted on first+last+state",
   nrow(gb("C2")) == 1L && gb("C2")$match_tier == "exact_first_last_state")
ok("C1 carries the right licence number", gb("C1")$license_number == "111")

cat("\n=== ambiguity is deferred, not resolved ===\n")
ok("C3 (two CO licensees, same name) is NOT in the bridge", nrow(gb("C3")) == 0L)
ok("C3 appears in the ambiguous artifact",
   "C3" %in% res$resolution$ambiguous$amcb_id)
ok("C3 is reported unresolved", "C3" %in% res$resolution$unresolved$amcb_id)

cat("\n=== national tier records the BOARD's state, not the certificant's ===\n")
ok("C4 accepted via the national tier",
   nrow(gb("C4")) == 1L && gb("C4")$match_tier == "exact_first_last_national")
ok("license_state is TX (where the licence lives), NOT CO",
   gb("C4")$license_state == "TX")
ok("the certificant's own state is retained separately",
   gb("C4")$certificant_state == "CO")
ok("the disagreement is flagged", isFALSE(gb("C4")$state_agrees))
ok("the deterministic identifier is TX:999, not CO:999",
   gb("C4")$deterministic_identifier == "TX:999")
ok("agreeing rows are flagged TRUE", isTRUE(gb("C1")$state_agrees))

cat("\n=== unresolved stays unresolved ===\n")
ok("C5 is absent from the bridge", nrow(gb("C5")) == 0L)
ok("C5 is reported unresolved", "C5" %in% res$resolution$unresolved$amcb_id)

cat("\n=== national tier can be switched off ===\n")
res_off <- build_amcb_state_licenses(amcb_path = file.path(td, "amcb.csv"),
                                     board_dir = bd,
                                     destination_dir = file.path(td, "off"),
                                     allow_national_tier = FALSE)
ok("C4 is NOT accepted when the national tier is disabled",
   !("C4" %in% res_off$bridge$amcb_id))
ok("tiers 1 and 2 are unaffected",
   all(c("C1","C2") %in% res_off$bridge$amcb_id))

cat("\n=== two people sharing one key are dropped, not collapsed ===\n")
bd2 <- file.path(td, "boards_collide")
dir.create(bd2, showWarnings = FALSE)
write_csv(tibble(
  first_name = c("ANNA","ZOE"), middle_name = c("MAE", NA),
  last_name = c("ADAMS","ZHANG"),
  license_number = c("111","111"), license_state = c("CO","CO"),
  license_status = "ACTIVE", license_type = "CNM"),
  file.path(bd2, "CO.csv"))
res_col <- build_amcb_state_licenses(amcb_path = file.path(td, "amcb.csv"),
                                     board_dir = bd2,
                                     destination_dir = file.path(td, "col"),
                                     allow_national_tier = FALSE)
ok("a key shared by two different names yields no match at all",
   !("C1" %in% res_col$bridge$amcb_id))

cat("\n=== normalizers ===\n")
ok("normalize_state handles names, abbreviations and junk",
   identical(normalize_state(c("Colorado","co","CO","Narnia", NA)),
             c("CO","CO","CO",NA,NA)))
ok("normalize_state does not error (datasets, not base)",
   !is.na(normalize_state("Utah")))
ok("normalize_license strips punctuation and case",
   normalize_license(" rn-12 345 ") == "RN12345")
ok("normalize_name blanks become NA", is.na(normalize_name("   ")))
ok("a filename that is not a state code yields NA, not a bogus state",
   is.na(normalize_state(str_to_upper(str_extract("colorado", "[A-Za-z]{2}$")))))

cat("\n=== sourcing must not execute the pipeline ===\n")
ok("no object was created by sourcing", !exists("license_build", inherits = FALSE))

cat("\n=== duplicate AMCB identifiers fail loudly ===\n")
write_csv(tibble(certification_number = c("C1","C1"),
                 first_name = c("A","B"), last_name = c("X","Y"),
                 state = "CO"), file.path(td, "amcb_dup.csv"))
e <- tryCatch({ build_amcb_state_licenses(file.path(td, "amcb_dup.csv"), bd,
                                          file.path(td, "dup")); NA_character_ },
              error = function(e) conditionMessage(e))
ok("duplicate AMCB ids raise an error", !is.na(e) && grepl("not unique", e))

cat("\n")
if (length(FAILS)) {
  cat(sprintf("FAILED: %d\n", length(FAILS)))
  for (f in FAILS) cat("  - ", f, "\n")
  quit(status = 1)
}
cat("All license-bridge tests passed.\n")
