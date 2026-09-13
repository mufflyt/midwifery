#!/usr/bin/env Rscript
# =============================================================================
# The tracked roster, rebuilt without the fields that were never observed
# =============================================================================
# artifacts/scraped_50_states_and_dc_midwives_master.csv was not a scrape of
# anything. Its first 52 columns are the AMCB roster and its NPPES linkage,
# copied from the 2026-08-10 freeze -- every one of them matches that freeze
# except the practice address of a single record. Everything after them was
# written by the scripts deleted in f5c2256 and 29be743:
#
#   scraped_license_num      "{ST}-RN-APRN-{certification_number}" for all
#                            11,355 rows, a re-encoding of the AMCB identifier
#   scraped_license_status   "Active Verified (Wave N BON Scrape)"
#   bon_verification_status, bon_ingestion_tier, bon_recency_year,
#   scraped_timestamp, *_scraping_batch, bon_direct_profile_url
#                            the same fiction, in more columns
#   cpt_delivery_claim_flag, has_cpt_delivery_claim, active_attending_status,
#   refined_clinical_setting "DAC primary specialty is CNM", relabelled as
#                            delivery attendance
#   attribution_tier ... open_payments_status
#                            enrichment carried through the same chain, with
#                            "Verified" labels no source supports and no way
#                            to re-derive here
#
# and one record's nppes_city/state/zip/practice_address had been overwritten
# by hand with an address from a different CMS file (a one-off script, deleted
# in f5c2256). Rows also repeated: 11,355 rows held 11,093 certificants.
#
# This rebuild keeps the 52 roster columns, takes their values from the
# freeze itself -- which restores the overwritten record and removes the
# duplicates in one step -- and adds board licensure only where a state board
# actually returned it: the three live_*_from_tracked_roster.csv files, each a
# real query of a state's public API (WA DOH, Colorado DORA, Texas BON),
# joined here by certification_number. Blank elsewhere. Blank is the truth for
# 47 states and DC, which were never queried.
#
# WHY THE FREEZE COMES FROM AN ENVIRONMENT VARIABLE. This script reads the
# 2026-08-10 freeze, pinned by hash, not the current one. It is not a
# dependent of the current freeze and must not be in rebuild_frozen_
# dependents.R's order: rerun against a newer freeze it would mix rosters.
# The hash check below refuses any other file.
#
# Inputs : the pre-remediation roster, read from git (ROSTER_COMMIT)
#          LEGACY_FROZEN_CSV   the 2026-08-10 freeze, sha256 dbcc76f4...
#          artifacts/live_{washington,colorado,texas}_bon_ingested_midwives_from_tracked_roster.csv
# Output : artifacts/tracked_roster_active_primary_linked.csv (person-level,
#          tracked under tests/ci_leak_reviewed_exceptions.txt)
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr) })
source(file.path("R", "lib", "artifact_provenance.R"))

ROSTER_COMMIT <- "9fc4d7d"
ROSTER_PATH   <- "artifacts/scraped_50_states_and_dc_midwives_master.csv"
LEGACY_SHA256 <- "dbcc76f420ac9be850efcc8aabc1523772cbcccea259783db88a5099d3a2209b"
LEGACY        <- Sys.getenv("LEGACY_FROZEN_CSV", "")
OUT           <- "artifacts/tracked_roster_active_primary_linked.csv"

BOARDS <- tibble::tribble(
  ~board_state, ~file, ~license_col, ~exp_col, ~board_source,
  "WA", "artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv",
        "live_bon_credential_num", "live_bon_exp_date",
        "data.wa.gov/resource/qxh8-f4bd (WA DOH, credentialtype like Midwife)",
  "CO", "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv",
        "live_bon_credential_num", "live_bon_exp_date",
        "data.colorado.gov/resource/7s5z-vewr (Colorado DORA, licensetype APN, subcategory CNM)",
  "TX", "artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv",
        "live_bon_license_number", NA_character_,
        "data.texas.gov/resource/jnzg-cr4w (Texas BON, apn_category NURSE MIDWIFE)")

if (!nzchar(LEGACY) || !file.exists(LEGACY))
  stop("Set LEGACY_FROZEN_CSV to the 2026-08-10 freeze (sha256 ",
       substr(LEGACY_SHA256, 1, 8), "...). Refusing to rebuild the roster ",
       "from anything else.", call. = FALSE)
if (!identical(sha256_of(LEGACY), LEGACY_SHA256))
  stop(LEGACY, " is not the 2026-08-10 freeze (sha256 mismatch).", call. = FALSE)

read_chr <- function(x) read_csv(x, col_types = cols(.default = col_character()),
                                 na = character(), progress = FALSE)

old <- read_chr(I(system2("git", c("show", paste0(ROSTER_COMMIT, ":", ROSTER_PATH)),
                          stdout = TRUE)))
roster_cols <- names(old)[seq_len(match("match_reason", names(old)))]
certs <- unique(old$certification_number)
cat(sprintf("pre-remediation roster: %s rows, %s certificants, %d roster columns\n",
            format(nrow(old), big.mark = ","), format(length(certs), big.mark = ","),
            length(roster_cols)))

frozen <- read_chr(LEGACY)
stopifnot(all(roster_cols %in% names(frozen)), !anyDuplicated(frozen$certification_number))
roster <- frozen %>%
  filter(certification_number %in% certs) %>%
  select(all_of(roster_cols))
stopifnot(nrow(roster) == length(certs),
          all(roster$status == "ACTIVE"), all(roster$linkage_tier == "primary_midwifery"))

# What the freeze changed relative to the tracked file, so the restore is
# visible rather than silent. "NA" in the tracked file and "" in the freeze
# are the same missing value written two ways.
na_blank <- function(x) ifelse(x == "NA", "", x)
cmp <- old %>% distinct(across(all_of(roster_cols))) %>%
  inner_join(roster, by = "certification_number", suffix = c(".old", ".frz"))
changed <- vapply(setdiff(roster_cols, "certification_number"), function(k)
  sum(na_blank(cmp[[paste0(k, ".old")]]) != na_blank(cmp[[paste0(k, ".frz")]])), integer(1))
changed <- changed[changed > 0]
cat(sprintf("restored from the freeze: %d row(s) differed, in %s\n",
            n_distinct(cmp$certification_number[Reduce(`|`, lapply(names(changed), function(k)
              na_blank(cmp[[paste0(k, ".old")]]) != na_blank(cmp[[paste0(k, ".frz")]])))]),
            if (length(changed)) paste(names(changed), collapse = ", ") else "no column"))

# --- genuine board evidence ----------------------------------------------------
board <- bind_rows(lapply(seq_len(nrow(BOARDS)), function(i) {
  b <- BOARDS[i, ]
  read_chr(b$file) %>%
    filter(live_bon_match_status == "VERIFIED_LIVE_BON") %>%
    transmute(certification_number,
              board_state = b$board_state,
              board_license_number = .data[[b$license_col]],
              board_license_status = live_bon_status,
              board_license_expiration = if (is.na(b$exp_col)) "" else .data[[b$exp_col]],
              board_source = b$board_source)
})) %>% distinct()
dup <- board$certification_number[duplicated(board$certification_number)]
if (length(dup))
  stop(sprintf("%d certificant(s) carry more than one board record; resolve before joining: %s",
               length(dup), paste(head(dup, 5), collapse = ", ")), call. = FALSE)

out <- roster %>% left_join(board, by = "certification_number")
cat("board licensure joined:\n")
print(table(out$board_state, useNA = "ifany"))

write_with_provenance(out, OUT, na = "",
                      inputs = c(LEGACY, BOARDS$file))
cat(sprintf("written: %s (%s rows)\n", OUT, format(nrow(out), big.mark = ",")))
