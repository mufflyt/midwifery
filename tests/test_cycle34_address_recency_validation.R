#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 34 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: validate_address_recency_pipeline.R -- two real defects found and
# fixed here (carried forward from cycle 33's investigation of the same
# file), independent of cycle 33's own fix (which targeted a different line,
# the refined_clinical_setting regex, in this same file).
#
# DEFECT 1: a plain !is.na(nppes_state) filter -- "does this midwife have a
# known current NPPES practice state" -- was printed as "midwives with
# cross-state practice moves" / "relocated midwives". No prior-state field
# exists anywhere in this data model to compute an actual relocation count,
# so the label overstated what was computed. Fixed by correcting the printed
# text to describe the actual filter; the computed VALUE is unchanged (no
# estimand change), only the English claim about it.
#
# DEFECT 2: the case-study "Validation Result" line was an unconditional
# hardcoded literal ("CONFIRMED ACTIVE IN MONTANA...") printed regardless of
# what active_attending_status/has_cpt_delivery_claim actually held for the
# matched record -- if the underlying data changed, the script would keep
# printing a verdict contradicting the "CPT Delivery Claims" line directly
# above it. Fixed by deriving the verdict from has_cpt_delivery_claim, the
# canonical boolean the rest of the script already treats as authoritative.
#
# NOT fixed (flagged in the ledger, not silently resolved): the same case
# study also prints a hardcoded "Legacy NPPES City: SEATTLE, WA" with no
# corresponding "legacy"/prior-city field loaded anywhere in this script to
# derive it from, and the file's own val_summary pairs real counts against
# hardcoded, non-computed "PPV"/precision literals (carried forward from
# cycle 33). Both need a human-defined methodology, not an invented one.
#
# This file cannot run end-to-end (gitignored artifacts), so its logic is
# replicated literally here, matching this session's established pattern.
#
# Run: Rscript tests/test_cycle34_address_recency_validation.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(stringr) })

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replicas of the corrected production logic.
state_coverage_message <- function(v4) {
  state_shifts <- v4 %>% filter(!is.na(nppes_state))
  sprintf("1. NPPES State Coverage: %d midwives have a known current NPPES practice state (not a cross-state MOVE count -- no prior-state field exists to compare against).",
          nrow(state_shifts))
}
delivery_claims_message <- function(v4) {
  state_shifts <- v4 %>% filter(!is.na(nppes_state))
  cpt_relocated <- v4 %>% filter(npi %in% state_shifts$npi, has_cpt_delivery_claim == TRUE)
  sprintf("2. Delivery Claims Validation: %d of %d midwives with a known NPPES state (%.1f%%) are active CPT delivery attenders.",
          nrow(cpt_relocated), nrow(state_shifts),
          nrow(cpt_relocated) / max(1, nrow(state_shifts)) * 100)
}
verdict_for <- function(row) {
  if (isTRUE(row$has_cpt_delivery_claim[1]))
    sprintf("CONFIRMED ACTIVE IN %s (%s)", row$nppes_state[1], row$attributed_hospital_name[1])
  else
    sprintf("NOT CONFIRMED by CPT delivery claims -- has_cpt_delivery_claim = %s",
            row$has_cpt_delivery_claim[1])
}
retired_verdict <- function() "CONFIRMED ACTIVE IN MONTANA (NEMHS Trinity Hospital Staff Roster)"
retired_state_message <- function(n) sprintf("1. State Transition Audit: Identified %d midwives with cross-state practice moves.", n)

cat("\n-- BVA --\n")

# T34-1. Zero-row case study match: filtering for a surname that matches no
# one must not error indexing deanna$field[1] on a 0-row data frame -- the
# whole case-study block is guarded by nrow(deanna) > 0 and must be skipped
# cleanly, not attempt to print anything.
{
  v4 <- tibble::tibble(last_name = c("SMITH", "JONES"), first_name = c("A", "B"))
  deanna <- v4 %>% filter(str_detect(toupper(last_name), "DIULIO"))
  ran_block <- FALSE
  if (nrow(deanna) > 0) ran_block <- TRUE
  chk(nrow(deanna) == 0L && !ran_block,
      "T34-1 no DIULIO match yields a 0-row frame and the case-study block does not run")
}

# T34-2. The max(1, nrow(state_shifts)) denominator guard: when every
# nppes_state is NA, state_shifts is empty and the percentage calculation
# must return 0, not NaN or an error from dividing by zero.
{
  v4_empty <- tibble::tibble(nppes_state = c(NA_character_, NA_character_),
                            npi = c("1", "2"), has_cpt_delivery_claim = c(NA, NA))
  msg <- delivery_claims_message(v4_empty)
  chk(grepl("0 of 0 midwives", msg) && grepl("0\\.0%", msg) && !grepl("NaN", msg),
      sprintf("T34-2 an entirely-NA nppes_state column produces '0 of 0 (0.0%%)', not NaN (got: %s)", msg))
}

# T34-3. has_cpt_delivery_claim NA-handling consistency: the summary's
# sum(x == TRUE, na.rm = TRUE) and the filter-based cpt_relocated count must
# both treat NA as "not an active attender" -- neither silently counts nor
# silently errors on an NA delivery-claim flag.
{
  v4 <- tibble::tibble(nppes_state = c("CO", "TX", "WA"), npi = c("1", "2", "3"),
                       has_cpt_delivery_claim = c(TRUE, NA, FALSE))
  n_filter <- v4 %>% filter(has_cpt_delivery_claim == TRUE) %>% nrow()
  n_sum <- sum(v4$has_cpt_delivery_claim == TRUE, na.rm = TRUE)
  chk(n_filter == 1L && n_sum == 1L && n_filter == n_sum,
      sprintf("T34-3 filter() and sum(..., na.rm=TRUE) agree on NA treatment (both count 1, got filter=%d sum=%d)",
              n_filter, n_sum))
}

cat("\n-- SEMANTIC --\n")

# T34-4. THE FIX. The section-1 message must describe the quantity it
# actually computes (a coverage count) rather than a quantity it cannot
# compute (a relocation count) -- there is no prior-state field anywhere in
# this data model to detect an actual cross-state move.
{
  v4 <- tibble::tibble(nppes_state = c("CO", NA, "TX"))
  msg <- state_coverage_message(v4)
  chk(grepl("known current NPPES practice state", msg) && !grepl("cross-state practice move", msg),
      "T34-4 the coverage message no longer claims a cross-state MOVE count it cannot compute")
  # ANTI-CEREMONY: the retired message, applied to the identical count.
  chk(grepl("cross-state practice moves", retired_state_message(2L)),
      "T34-4b the retired message text claimed 'cross-state practice moves' for the same plain coverage count")
}

# T34-5. THE FIX. The case-study verdict must be conditional on the actual
# computed evidence (has_cpt_delivery_claim), not an unconditional literal
# independent of the data -- proven by flipping the input and observing the
# verdict change accordingly.
{
  active <- tibble::tibble(has_cpt_delivery_claim = TRUE, nppes_state = "MT",
                          attributed_hospital_name = "NEMHS Trinity Hospital")
  inactive <- tibble::tibble(has_cpt_delivery_claim = FALSE, nppes_state = "MT",
                            attributed_hospital_name = "NEMHS Trinity Hospital")
  chk(grepl("^CONFIRMED ACTIVE", verdict_for(active)) &&
        grepl("^NOT CONFIRMED", verdict_for(inactive)),
      "T34-5 the verdict flips from CONFIRMED to NOT CONFIRMED as has_cpt_delivery_claim flips")
  # ANTI-CEREMONY: the retired verdict never changes regardless of evidence.
  chk(identical(retired_verdict(), "CONFIRMED ACTIVE IN MONTANA (NEMHS Trinity Hospital Staff Roster)"),
      "T34-5b the retired verdict is a fixed literal, unconditional on any input")
}

# T34-6. Case-insensitive name matching: str_detect(toupper(x), "DIULIO")
# must match regardless of the source capitalization, since NPPES/AMCB
# records are not guaranteed consistent casing.
{
  variants <- c("DiUlio", "DIULIO", "diulio", "Diulio")
  chk(all(str_detect(toupper(variants), "DIULIO")),
      "T34-6 the case-study surname match is case-insensitive across all capitalization variants")
}

# T34-7. Internal consistency: after the fix, the section-1 message and
# val_summary's "NPPES Address Geocoded" row describe the SAME underlying
# filter (!is.na(nppes_state)) without contradicting each other -- this is
# exactly the internal inconsistency (one place said "cross-state moves",
# the other honestly said "Geocoded (N)") that originally exposed the defect.
{
  v4 <- tibble::tibble(nppes_state = c("CO", NA, "TX", "WA"))
  n_from_message <- as.integer(str_match(state_coverage_message(v4), "Coverage: (\\d+) midwives")[, 2])
  n_from_summary <- sum(!is.na(v4$nppes_state))
  chk(identical(n_from_message, n_from_summary),
      sprintf("T34-7 the coverage message's count (%d) matches val_summary's 'Geocoded (N)' count (%d)",
              n_from_message, n_from_summary))
}

cat("\n-- ADVERSARIAL --\n")

# T34-8. Multiple case-study matches: two records both containing "DIULIO"
# (e.g. a hyphenated surname "DIULIO-SMITH" alongside "DIULIO") -- the code
# takes deanna$field[1], the FIRST match only. This is documented,
# intentional single-record spot-check behavior for a named case study, not
# a defect to fix; pinned here so it is not silently changed to "first
# exact match" or similar without a test noticing.
{
  v4 <- tibble::tibble(last_name = c("DIULIO-SMITH", "DIULIO"),
                       first_name = c("Ann", "Deanna"),
                       has_cpt_delivery_claim = c(FALSE, TRUE))
  deanna <- v4 %>% filter(str_detect(toupper(last_name), "DIULIO"))
  chk(nrow(deanna) == 2L && deanna$first_name[1] == "Ann",
      "T34-8 two DIULIO-matching records both survive the filter; [1] silently selects whichever sorts first in the data, not necessarily 'Deanna'")
}

# T34-9. has_cpt_delivery_claim entirely NA (not just some rows) -- the
# adversarial "sparse/empty subset" case for the whole column, not a mix.
# sum(x == TRUE, na.rm = TRUE) must degrade to 0, not NA or an error.
{
  v4 <- tibble::tibble(nppes_state = c("CO", "TX"), npi = c("1", "2"),
                       has_cpt_delivery_claim = c(NA, NA))
  n_sum <- sum(v4$has_cpt_delivery_claim == TRUE, na.rm = TRUE)
  chk(identical(n_sum, 0L) || identical(n_sum, 0),
      sprintf("T34-9 an entirely-NA has_cpt_delivery_claim column sums to 0, not NA (got %s)", n_sum))
}

# T34-10. The fixed verdict is anchored to has_cpt_delivery_claim (the
# canonical boolean), not to the derived active_attending_status STRING --
# so even if the two fields were ever inconsistent (a stale string alongside
# an updated boolean), the verdict stays correct because it never reads the
# string at all.
{
  inconsistent <- tibble::tibble(
    has_cpt_delivery_claim = TRUE,
    active_attending_status = "Antepartum / Postpartum / Well-Woman GYN Clinic Practice (No Active Delivery Claims)",
    nppes_state = "MT", attributed_hospital_name = "NEMHS Trinity Hospital")
  chk(grepl("^CONFIRMED ACTIVE", verdict_for(inconsistent)),
      "T34-10 the verdict follows has_cpt_delivery_claim even when active_attending_status text disagrees")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
