#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 39 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: match_open_payments_to_facility.R -- unexplored across 8+ prior
# cycles' resuming notes, zero prior test coverage. Investigating one
# order-dependence defect led to a second instance of the identical defect
# class in the same file (matching cycle 36's precedent: keep looking within
# a file once one instance of a defect shape turns up).
#
# TWO REAL DEFECTS found and fixed, both the same shape: distinct(x,
# .keep_all = TRUE) silently keeps whichever row happens to sort first among
# rows sharing a key, INCLUDING rows that genuinely CONFLICT (disagree on a
# column that matters), rather than treating a real conflict as an error.
#
#   1. The OB hospital master deduplicated on (addr_norm, zip) via
#      distinct(.keep_all = TRUE). Two hospitals CAN legitimately share one
#      physical address (a rename or re-licensing keeps the building, changes
#      the CCN and name) -- which CCN/name every midwife at that address gets
#      attributed to depended on this CSV's row order, silently, and would
#      flip on a re-export with no code change.
#   2. The cohort's own dedup on certification_number, from artifacts/
#      amcb_npi_linkage_FROZEN.csv, used the same pattern. A certification_
#      number appearing twice with two DIFFERENT npi values is an identity
#      conflict, not a harmless repeat -- silently picking one NPI by row
#      order decides who a midwife's entire Open Payments / facility match is
#      attributed to.
#
# Both fixed by replacing distinct(.keep_all = TRUE) with
# assert_unique_keys(dedupe = TRUE) (R/join_safety.R, already used elsewhere
# in this repo for exactly this purpose): identical duplicate rows still
# collapse for free, but a genuine conflict now stops the run and names the
# disagreeing column(s) instead of silently choosing.
#
# This file is a flat, unguarded top-to-bottom script needing gitignored
# artifacts and a live DuckDB connection, so it cannot be sourced end-to-end;
# its logic is replicated literally, matching this session's established
# pattern. assert_unique_keys() itself IS sourced directly from R/join_
# safety.R, since that function is pure and needs no artifact.
#
# Run: Rscript tests/test_cycle39_open_payments_facility.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(checkmate) })
source("R/join_safety.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replica of the recency-resolution pipeline (lines ~96-102).
build_recent <- function(raw) {
  raw %>%
    filter(!is.na(addr_norm)) %>%
    group_by(npi) %>% filter(yr == max(yr)) %>%
    count(npi, yr, addr, addr_norm, city, st, zip, name = "times_reported") %>%
    arrange(npi, desc(times_reported), addr_norm) %>%
    slice(1) %>% ungroup()
}

cat("\n-- BVA --\n")

# T39-1. The minimum non-trivial case: a single address reported exactly once
# in the latest year resolves trivially, with times_reported = 1.
{
  raw <- tibble(npi = "1", yr = 2023, addr = "100 MAIN ST",
               addr_norm = "100 MAIN ST", city = "X", st = "CO", zip = "80001")
  r <- build_recent(raw)
  chk(nrow(r) == 1L && r$times_reported == 1L,
      "T39-1 a single latest-year address resolves with times_reported = 1")
}

# T39-2. The tie-break's minimum case: exactly 2 addresses tied on
# times_reported within the latest year -- must resolve to the
# lexicographically first addr_norm, identically regardless of input row
# order (the file's own documented contract: "ties break lexicographically").
{
  raw_a <- tibble(npi = c("1", "1"), yr = c(2023, 2023),
                  addr = c("ZEBRA ST", "ALPHA ST"),
                  addr_norm = c("ZEBRA ST", "ALPHA ST"),
                  city = "X", st = "CO", zip = c("80001", "80002"))
  raw_b <- raw_a[c(2, 1), ]
  ra <- build_recent(raw_a); rb <- build_recent(raw_b)
  chk(nrow(ra) == 1L && ra$addr_norm == "ALPHA ST" && identical(ra, rb),
      sprintf("T39-2 a 2-way tie on times_reported resolves lexicographically ('ALPHA ST'), identically regardless of row order (got '%s')",
              ra$addr_norm))
}

# T39-3. assert_unique_keys(dedupe=TRUE)'s minimum duplicate case: exactly 2
# IDENTICAL rows collapse to exactly 1, not 0 and not left at 2.
{
  d <- tibble(addr_norm = c("100 MAIN ST", "100 MAIN ST"), zip = c("80001", "80001"),
             cms_ccn = c("111111", "111111"), hospital_name = "SAME HOSPITAL")
  out <- assert_unique_keys(d, c("addr_norm", "zip"), label = "test", dedupe = TRUE)
  chk(nrow(out) == 1L,
      sprintf("T39-3 exactly 2 identical duplicate rows collapse to exactly 1 (got %d)", nrow(out)))
}

# T39-4. Zero-row input: an empty hospital master (or an empty cohort) must
# not error inside assert_unique_keys()'s own count()/filter() machinery --
# a 0-row table has, trivially, no duplicates to find or conflicts to raise.
{
  d0 <- tibble(addr_norm = character(0), zip = character(0),
              cms_ccn = character(0), hospital_name = character(0))
  out <- assert_unique_keys(d0, c("addr_norm", "zip"), label = "test", dedupe = TRUE)
  chk(is.data.frame(out) && nrow(out) == 0L,
      "T39-4 a 0-row table passes through assert_unique_keys() as a 0-row result, not an error")
}

cat("\n-- SEMANTIC --\n")

# T39-5. THE FIX (hospital master). Two hospitals genuinely disagreeing at
# the same (addr_norm, zip) -- a rename/re-licensing at one building -- must
# now stop the run and name the offending columns, not silently keep
# whichever sorted first.
{
  hosp_a <- tibble(cms_ccn = c("111111", "222222"),
                   hospital_name = c("OLD NAME HOSPITAL", "NEW NAME HOSPITAL"),
                   addr_norm = c("100 MAIN ST", "100 MAIN ST"), zip = c("80001", "80001"))
  hosp_b <- hosp_a[c(2, 1), ]
  err_a <- tryCatch({
    assert_unique_keys(hosp_a, c("addr_norm", "zip"), label = "OB hospital master (addr_norm + zip)", dedupe = TRUE)
    NA_character_
  }, error = function(e) conditionMessage(e))
  err_b <- tryCatch({
    assert_unique_keys(hosp_b, c("addr_norm", "zip"), label = "OB hospital master (addr_norm + zip)", dedupe = TRUE)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err_a) && grepl("DISAGREE", err_a) && identical(err_a, err_b),
      "T39-5 two hospitals disagreeing at one address error identically regardless of row order, naming the disagreement")
  # ANTI-CEREMONY: the retired distinct() rule, applied to the same two
  # orderings, actually returns two DIFFERENT hospitals -- proving the defect.
  retired_a <- hosp_a %>% distinct(addr_norm, zip, .keep_all = TRUE)
  retired_b <- hosp_b %>% distinct(addr_norm, zip, .keep_all = TRUE)
  chk(!identical(retired_a$hospital_name, retired_b$hospital_name),
      sprintf("T39-5b the retired distinct() rule picks a DIFFERENT hospital depending on row order ('%s' vs '%s')",
              retired_a$hospital_name, retired_b$hospital_name))
}

# T39-6. THE FIX (cohort linkage). The same conflict-vs-identical distinction
# for certification_number: two DIFFERENT npi values for one certification_
# number is a real identity conflict and must error; two IDENTICAL rows must
# still collapse for free.
{
  coh_conflict <- tibble(certification_number = c("C1", "C1"),
                         status = "ACTIVE", linkage_tier = "primary_midwifery",
                         npi = c("1111111111", "2222222222"))
  err <- tryCatch({
    coh_conflict %>% filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
      assert_unique_keys("certification_number", label = "AMCB-NPI linkage (ACTIVE primary_midwifery)", dedupe = TRUE)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("npi", err),
      sprintf("T39-6a two different NPIs for one certification_number error, naming npi as the disagreement (got: %s)",
              if (is.na(err)) "no error" else err))

  coh_dup <- tibble(certification_number = c("C1", "C1"),
                    status = "ACTIVE", linkage_tier = "primary_midwifery",
                    npi = c("1111111111", "1111111111"))
  out <- coh_dup %>% filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    assert_unique_keys("certification_number", label = "test", dedupe = TRUE)
  chk(nrow(out) == 1L,
      "T39-6b two identical rows for one certification_number still collapse to 1, not an error")
}

# T39-7. THE FRAGILE-BUT-CORRECT INVARIANT this entire pipeline depends on:
# count() called on data already grouped by npi PRESERVES that grouping
# (minus the counted variables), so the subsequent slice(1) operates PER
# npi -- returning one row for EACH midwife -- rather than globally, which
# would silently keep only a single row across the ENTIRE dataset. Pinned as
# a regression guard: a dplyr behavior change or a careless edit removing
# the upstream group_by(npi) would corrupt this pipeline catastrophically
# and silently (no error, just far too few output rows).
{
  raw <- tibble(npi = c("1", "1", "2", "2"), yr = c(2023, 2023, 2024, 2024),
               addr = c("A ST", "A ST", "B AVE", "B AVE"),
               addr_norm = c("A ST", "A ST", "B AVE", "B AVE"),
               city = "X", st = "CO", zip = c("80001", "80001", "80002", "80002"))
  r <- build_recent(raw)
  chk(nrow(r) == 2L && setequal(r$npi, c("1", "2")),
      sprintf("T39-7 slice(1) after count() on npi-grouped data returns one row PER npi (%d rows, npis: %s), not one row globally",
              nrow(r), paste(sort(r$npi), collapse = ", ")))
}

cat("\n-- ADVERSARIAL --\n")

# T39-8. "Most recent year wins" is a genuine SELECTION, not a merge: a
# midwife with addresses reported in an earlier AND a later year must have
# only the later year's address survive -- the earlier year's data must not
# be blended, averaged, or otherwise leak into the result.
{
  raw <- tibble(npi = c("1", "1"), yr = c(2021, 2024),
               addr = c("OLD ADDRESS ST", "NEW ADDRESS AVE"),
               addr_norm = c("OLD ADDRESS ST", "NEW ADDRESS AVE"),
               city = c("OLDCITY", "NEWCITY"), st = "CO", zip = c("80001", "80009"))
  r <- build_recent(raw)
  chk(nrow(r) == 1L && r$yr == 2024 && r$addr_norm == "NEW ADDRESS AVE",
      sprintf("T39-8 only the later year's address survives; the earlier year leaves no trace (got yr=%s, addr=%s)",
              r$yr, r$addr_norm))
}

# T39-9. Malformed/adversarial input: a genuinely empty addr_norm (after
# normalization strips a garbage address down to nothing) must be filtered
# out by filter(!is.na(addr_norm)) rather than surviving as a spurious
# "resolved" address with no real content -- addr_norm becoming NA is the
# documented contract for an unusable address (see R/lib/address_keys.R).
{
  raw <- tibble(npi = "1", yr = 2023, addr = "###", addr_norm = NA_character_,
               city = "X", st = "CO", zip = "80001")
  r <- build_recent(raw)
  chk(nrow(r) == 0L,
      sprintf("T39-9 a row with NA addr_norm (an unusable garbage address) is filtered out entirely, not resolved with a blank address (got %d rows)",
              nrow(r)))
}

# T39-10. Three-way genuine conflict (not just two): assert_unique_keys()
# must still detect and refuse a conflict when MORE than two rows share a
# key with more than one distinct value among them, not just the pairwise
# case.
{
  d <- tibble(addr_norm = rep("100 MAIN ST", 3), zip = rep("80001", 3),
             cms_ccn = c("111111", "111111", "222222"),
             hospital_name = c("HOSP A", "HOSP A", "HOSP B"))
  err <- tryCatch({
    assert_unique_keys(d, c("addr_norm", "zip"), label = "test", dedupe = TRUE)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err),
      sprintf("T39-10 a 3-row group (2 agreeing, 1 conflicting) is still refused, not resolved by majority or row order (got: %s)",
              if (is.na(err)) "no error" else err))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
