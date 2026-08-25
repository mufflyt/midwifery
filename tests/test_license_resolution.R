#!/usr/bin/env Rscript
# =============================================================================
# Tests for resolve_amcb_by_state_license()
# =============================================================================
# The properties that matter:
#   1. a license key identifying exactly ONE NPI resolves;
#   2. anything ambiguous is QUARANTINED, never broken by a tiebreak;
#   3. license evidence OUTRANKS the existing name matcher and the override is
#      recorded, not silent.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr); library(tidyr)
})
source("R/resolve_amcb_by_state_license.R")

FAILS <- character(0)
ok <- function(name, cond) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", name))
  else { FAILS <<- c(FAILS, name); cat(sprintf("  FAIL  %s\n", name)) }
}

td <- file.path(tempdir(), paste0("lic_", as.integer(Sys.time())))
dir.create(td, recursive = TRUE, showWarnings = FALSE)

# A1 CO 12345  -> one NPI                      : resolves
# A2 CO 0007   -> NPPES has "7"                : resolves via zero-stripping
# A3 CO 55555  -> two NPIs share the key       : quarantined
# A4 CO 99999  -> absent from NPPES            : not found
# A5 CO/UT     -> two licenses, different NPIs : quarantined (conflict)
# A6/A7 share CO 31313 on the BOARD side       : quarantined before NPPES
# A8 CO 22222  -> name matcher says a DIFFERENT NPI: license must WIN
write_csv(tibble(certification_number = paste0("A", 1:8),
                 last_name = paste0("N", 1:8)), file.path(td, "amcb.csv"))

write_csv(tibble(
  certification_number = c("A1","A2","A3","A4","A5","A5","A6","A7","A8"),
  license_state = c("CO","Colorado","CO","CO","CO","UT","CO","CO","CO"),
  license_number = c("12345","0007","55555","99999","61616","71717",
                     "31313","31313","22222")),
  file.path(td, "lic.csv"))

nppes <- tibble(
  NPI = c("1000000001","1000000002","1000000003","1000000004",
          "1000000005","1000000006","1000000009"),
  `Provider License Number_1` = c("12345","7","55555","55555",
                                  "61616","71717","22222"),
  `Provider License Number State Code_1` = c("CO","CO","CO","CO","CO","UT","CO"),
  `Healthcare Provider Taxonomy Code_1` = rep("367A00000X", 7))
write_csv(nppes, file.path(td, "nppes.csv"))

# The name matcher put A8 on a different NPI, and A1 on the right one.
write_csv(tibble(certification_number = c("A1","A8"),
                 npi = c("1000000001","1000000077"),
                 linkage_tier = c("primary_midwifery","sensitivity_fuzzy")),
          file.path(td, "xwalk.csv"))

res <- resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes.csv"),
  existing_crosswalk_path = file.path(td, "xwalk.csv"),
  save_dir = file.path(td, "out"))

dm <- res$deterministic_matches
q  <- res$quarantine_records
cw <- res$updated_crosswalk
gx <- function(id) cw[cw$amcb_id_license == id, ]

cat("\n=== deterministic resolution ===\n")
ok("A1 resolves on an exact unique key",
   "A1" %in% dm$amcb_id_license &&
     dm$npi_license[dm$amcb_id_license == "A1"] == "1000000001")
ok("A2 resolves: board '0007' matches NPPES '7'",
   "A2" %in% dm$amcb_id_license &&
     dm$npi_license[dm$amcb_id_license == "A2"] == "1000000002")
ok("full state name 'Colorado' normalizes to CO", "A2" %in% dm$amcb_id_license)
ok("A8 resolves despite a conflicting name match",
   dm$npi_license[dm$amcb_id_license == "A8"] == "1000000009")

cat("\n=== ambiguity is quarantined, never tiebroken ===\n")
ok("A3 (one license, two NPIs) does NOT resolve", !("A3" %in% dm$amcb_id_license))
ok("...and is quarantined as license_maps_multiple_npi",
   any(q$amcb_id_license == "A3" &
         q$license_resolution_status == "quarantined_license_maps_multiple_npi"))
ok("A4 (absent from NPPES) does NOT resolve", !("A4" %in% dm$amcb_id_license))
ok("...and is recorded as license_not_found_in_nppes",
   any(q$amcb_id_license == "A4" &
         q$license_resolution_status == "license_not_found_in_nppes"))
ok("A5 (two licenses -> two different NPIs) does NOT resolve",
   !("A5" %in% dm$amcb_id_license))
ok("...and is quarantined as amcb_maps_multiple_npi",
   any(q$amcb_id_license == "A5" &
         q$license_resolution_status == "quarantined_amcb_maps_multiple_npi"))
ok("A6/A7 sharing a board key are quarantined BEFORE NPPES is consulted",
   all(c("A6","A7") %in%
         q$amcb_id_license[q$license_resolution_status ==
                             "quarantined_duplicate_state_board_key"]))
ok("neither A6 nor A7 resolves",
   !any(c("A6","A7") %in% dm$amcb_id_license))

cat("\n=== license evidence outranks the name matcher ===\n")
ok("A8's crosswalk NPI is the LICENSE one, not the name one",
   gx("A8")$npi == "1000000009")
ok("A8 is tiered deterministic_state_license",
   gx("A8")$linkage_tier == "deterministic_state_license")
ok("the override is recorded, not silent",
   isTRUE(gx("A8")$existing_match_overridden))
ok("A8 appears in the conflicts artifact",
   "A8" %in% res$crosswalk_conflicts$amcb_id_license)
ok("A1, where both agree, is NOT flagged as a conflict",
   !("A1" %in% res$crosswalk_conflicts$amcb_id_license))
ok("A1 is recorded as confirming the existing match",
   gx("A1")$deterministic_vs_existing == "deterministic_confirms_existing")

cat("\n=== unresolved stays unresolved ===\n")
ok("A3 has no NPI in the crosswalk", is.na(gx("A3")$npi))
ok("A3 source is 'unresolved'", gx("A3")$identity_resolution_source == "unresolved")

cat("\n=== normalizers ===\n")
ok("leading zeros stripped only for all-digit licenses",
   normalize_license_number("0007") == "7" &&
     normalize_license_number("A007") == "A007")
ok("punctuation and case removed",
   normalize_license_number(" rn-12 345 ") == "RN12345")
ok("placeholder values become NA",
   all(is.na(normalize_license_number(c("", "NONE", "UNKNOWN", NA)))))
ok("state names and abbreviations both normalize",
   identical(normalize_state(c("Colorado","co","CO","Narnia", NA)),
             c("CO","CO","CO",NA,NA)))
ok("normalize_state does not error (datasets::state.name, not base)",
   !is.na(normalize_state("Utah")))

cat("\n=== contract failures are loud ===\n")
write_csv(tibble(certification_number = c("A1","A1"), last_name = c("x","y")),
          file.path(td, "amcb_dup.csv"))
e <- tryCatch({ resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb_dup.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes.csv"),
  save_dir = file.path(td, "out2")); NA_character_ },
  error = function(e) conditionMessage(e))
ok("duplicate AMCB identifiers raise an error",
   !is.na(e) && grepl("not unique", e))

cat("\n=== optional columns are genuinely optional ===\n")
write_csv(tibble(certification_number = "A1", npi = "1000000001"),
          file.path(td, "xwalk_notier.csv"))
e2 <- tryCatch({ resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes.csv"),
  existing_crosswalk_path = file.path(td, "xwalk_notier.csv"),
  save_dir = file.path(td, "out3")); NA_character_ },
  error = function(e) conditionMessage(e))
ok("a crosswalk without linkage_tier still runs", is.na(e2))

cat("\n=== a roster that already carries `npi` does not lose it ===\n")
write_csv(tibble(certification_number = c("A1","A2"),
                 npi = c("9999999999","8888888888")),
          file.path(td, "amcb_withnpi.csv"))
r3 <- resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb_withnpi.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes.csv"),
  save_dir = file.path(td, "out4"))
ok("the roster's original npi is preserved under a distinct name",
   "npi_roster_original" %in% names(r3$updated_crosswalk) &&
     r3$updated_crosswalk$npi_roster_original[1] == "9999999999")
ok("and the emitted npi is the deterministic one",
   r3$updated_crosswalk$npi[r3$updated_crosswalk$amcb_id_license == "A1"] ==
     "1000000001")

cat("\n=== the study frame is a boundary, not a suggestion ===\n")
# REGRESSION. Before the fix this invocation reported "3 of 2 AMCB certificants
# (150.0%)": the A1-A8 license fixture stayed eligible for deterministic
# resolution while the roster held only A1 and A2, so A8 was resolved, counted,
# and written into the deterministic-match artifact for a study frame it was
# never part of. The percentage was the symptom; the escaped population was the
# defect.
roster3 <- c("A1", "A2")
ok("no deterministic match names anyone outside the roster",
   length(setdiff(r3$deterministic_matches$amcb_id_license, roster3)) == 0L)
ok("exactly 2 of 2 certificants resolve, not 3 of 2",
   nrow(r3$deterministic_matches) == 2L)
ok("every audit share lies within [0,100]",
   all(r3$audit_summary$pct_of_amcb >= 0 & r3$audit_summary$pct_of_amcb <= 100))
ok("distinct resolved ids never exceed distinct roster ids",
   dplyr::n_distinct(r3$deterministic_matches$amcb_id_license) <=
     dplyr::n_distinct(roster3))

# The out-of-frame resolution is EVIDENCE, not garbage. It is removed from the
# claim and kept as a labelled diagnostic, so nothing is discarded untraceably.
ok("A8 is retained as an explicit out-of-frame diagnostic",
   "A8" %in% r3$out_of_frame_matches$amcb_id_license)
ok("...and is labelled with why it is out of frame",
   all(r3$out_of_frame_matches$out_of_frame_reason ==
         "amcb_id_absent_from_supplied_roster"))

# The artifact on disk is what other code reads, so assert on the FILE.
dm_file <- read_csv(r3$saved_paths[["deterministic"]], show_col_types = FALSE)
ok("the WRITTEN artifact contains no out-of-frame id",
   length(setdiff(dm_file$amcb_id_license, roster3)) == 0L)
ok("quarantine rows are labelled in-frame or not",
   "in_study_frame" %in% names(r3$quarantine_records))

cat("\n=== shrinking the roster cannot retain people it removed ===\n")
# MONOTONICITY. Holding the external license/NPPES universe fixed, removing a
# person from the roster must remove them from the answer.
write_csv(tibble(certification_number = c("A1")), file.path(td, "amcb_a1.csv"))
r5 <- resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb_a1.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes.csv"),
  save_dir = file.path(td, "out6"))
ok("a one-person roster resolves at most one person",
   nrow(r5$deterministic_matches) <= 1L)
ok("and resolves nobody it was not asked about",
   all(r5$deterministic_matches$amcb_id_license == "A1"))
ok("A2, removed from the roster, is no longer resolved",
   !"A2" %in% r5$deterministic_matches$amcb_id_license)

cat("\n=== narrowing the frame must not WIDEN the answer ===\n")
# This is the test that decides WHERE the fix belongs, and it is the reason the
# roster restriction is applied to the claim rather than to the license file.
#
# A6 and A7 share board key CO 31313, so the key identifies no one and neither
# resolves. Give NPPES a row for that key and the only thing still preventing a
# resolution is the collision itself. Now ask about a roster of A6 alone: if the
# license universe were filtered to the roster BEFORE the collision check, A7's
# row would vanish, CO 31313 would look unique, and A6 would resolve -- certainty
# manufactured by deleting the evidence that contradicted it.
nppes_31313 <- read_csv(file.path(td, "nppes.csv"), show_col_types = FALSE,
                        col_types = readr::cols(.default = readr::col_character())) |>
  dplyr::bind_rows(tibble(
    NPI = "1000000031",
    `Provider License Number_1` = "31313",
    `Provider License Number State Code_1` = "CO",
    `Healthcare Provider Taxonomy Code_1` = "367A00000X"))
write_csv(nppes_31313, file.path(td, "nppes_31313.csv"))
write_csv(tibble(certification_number = "A6"), file.path(td, "amcb_a6.csv"))
r6 <- resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb_a6.csv"),
  state_license_path = file.path(td, "lic.csv"),
  nppes_path = file.path(td, "nppes_31313.csv"),
  save_dir = file.path(td, "out7"))
ok("A6 alone still does NOT resolve on a key it shares with A7",
   !"A6" %in% r6$deterministic_matches$amcb_id_license)
ok("...because the collision is still detected against the full universe",
   any(grepl("duplicate_state_board_key",
             r6$quarantine_records$license_resolution_status)))

cat("\n=== order invariance ===\n")
set.seed(7)
lic <- read_csv(file.path(td, "lic.csv"), show_col_types = FALSE)
write_csv(lic[sample(nrow(lic)), ], file.path(td, "lic_shuf.csv"))
npp <- read_csv(file.path(td, "nppes.csv"), show_col_types = FALSE)
write_csv(npp[sample(nrow(npp)), ], file.path(td, "nppes_shuf.csv"))
r4 <- resolve_amcb_by_state_license(
  amcb_path = file.path(td, "amcb.csv"),
  state_license_path = file.path(td, "lic_shuf.csv"),
  nppes_path = file.path(td, "nppes_shuf.csv"),
  existing_crosswalk_path = file.path(td, "xwalk.csv"),
  save_dir = file.path(td, "out5"))
ok("shuffling both inputs leaves the deterministic matches identical",
   identical(dplyr::arrange(dm, .data$amcb_id_license),
             dplyr::arrange(r4$deterministic_matches, .data$amcb_id_license)))

cat("\n")
if (length(FAILS)) {
  cat(sprintf("FAILED: %d\n", length(FAILS)))
  for (f in FAILS) cat("  - ", f, "\n")
  quit(status = 1)
}
cat("All license-resolution tests passed.\n")
