#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 32 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: resolve_type2_bulk() / op_zip5() / op_norm_addr() in
# link_open_payments_type2_bulk.R. tests/test_open_payments_type2_bulk.R
# already covers order invariance, alias determinism, duplicate-id rejection,
# ZIP participation, and prefix-collision avoidance -- this cycle targets
# genuinely different edges that file does not touch: the 0-row boundaries on
# both sides of the join, the word-boundary safety of the whole street-type
# abbreviation dictionary (only STREET/ST equivalence was tested before), a
# large-N candidate cluster (the existing large fixture resolves to a UNIQUE
# match; nothing pins the "no limit" claim at scale for an AMBIGUOUS result),
# and two real defects found this cycle by direct empirical probing: a
# type-mismatched zip/addr column and an NA organization_name.
#
# Run: Rscript tests/test_cycle32_open_payments_type2_bulk.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(stringr); library(tibble) })
source("link_open_payments_type2_bulk.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- BVA --\n")

# T32-1. The 0-row boundary on the INPUT side: no addresses to resolve must
# return a typed, 0-row tibble with the full output schema -- not NULL, not
# an error, not a 1-row placeholder.
{
  empty_in <- tibble(id = character(0), addr = character(0), zip = character(0))
  org <- tibble(type2_npi = "1", organization_name = "X",
                addr = "1 MAIN ST", zip = "10001")
  r <- resolve_type2_bulk(empty_in, org)
  chk(is.data.frame(r) && nrow(r) == 0L &&
        all(c("id", "n_candidates", "status", "type2_npi",
              "organization_name") %in% names(r)),
      "T32-1 zero addresses to resolve returns a typed 0-row tibble, not NULL")
}

# T32-2. The 0-row boundary on the CANDIDATE side: an empty organization
# table must resolve every id to no_match, not error on the join or on
# n_distinct() over zero rows.
{
  org0 <- tibble(type2_npi = character(0), organization_name = character(0),
                addr = character(0), zip = character(0))
  r <- resolve_type2_bulk(tibble(id = "m", addr = "1 MAIN ST", zip = "10001"), org0)
  chk(nrow(r) == 1L && r$status == "no_match" && r$n_candidates == 0L &&
        is.na(r$organization_name),
      "T32-2 an empty candidate universe resolves to no_match, not an error")
}

# T32-3. ZIP+4 on the INPUT side against a ZIP5-only candidate table: op_zip5()
# must extract the first five digits and still match, since Open Payments
# addresses routinely carry the +4 extension while the bulk NPPES table does
# not.
{
  org <- tibble(type2_npi = "1000000097", organization_name = "ATL CLINIC",
                addr = "1 PEACHTREE ST", zip = "30301")
  r <- resolve_type2_bulk(tibble(id = "m", addr = "1 PEACHTREE ST", zip = "30301-1234"), org)
  chk(r$status == "unique_exact" && r$organization_name == "ATL CLINIC",
      "T32-3 a ZIP+4 input address matches a ZIP5-only candidate row")
}

cat("\n-- SEMANTIC --\n")

# T32-4. The street-type abbreviation dictionary must be word-boundary safe
# across ALL its entries, not just the STREET/ST pair the existing suite
# checks: a street name that CONTAINS a direction/type word as a substring
# (NORTHFIELD, COURTNEY, EASTMAN, WESTFIELD) must be left untouched, while the
# same words as STANDALONE tokens are abbreviated. A dictionary applied with
# unanchored regex would corrupt every one of these real street names.
{
  chk(op_norm_addr("5 NORTHFIELD RD") == "5 NORTHFIELD RD" &&
        op_norm_addr("5 COURTNEY LN") == "5 COURTNEY LN" &&
        op_norm_addr("5 EASTMAN AVE") == "5 EASTMAN AVE" &&
        op_norm_addr("5 WESTFIELD DR") == "5 WESTFIELD DR",
      "T32-4a substring collisions (NORTHFIELD/COURTNEY/EASTMAN/WESTFIELD) survive unchanged")
  chk(op_norm_addr("5 NORTH ST") == "5 N ST" &&
        op_norm_addr("5 COURT") == "5 CT" &&
        op_norm_addr("5 EAST AVE") == "5 E AVE" &&
        op_norm_addr("5 WEST DR") == "5 W DR",
      "T32-4b the same words as standalone tokens ARE abbreviated")
}

# T32-5. THE "NO LIMIT" CONTRACT AT SCALE. The file's own header claims the
# replaced API path truncated a dense ZIP to its alphabetical first 10; this
# implementation's entire reason to exist is evaluating the COMPLETE
# candidate universe. The existing large fixture (30 rows) resolves to a
# UNIQUE match because only one row shares the query address -- it does not
# pin the no-limit claim for an AMBIGUOUS result. This does, at 5x the scale
# of the largest existing ambiguous fixture (3 rows).
{
  big <- tibble(type2_npi = sprintf("2%09d", 1:50),
                organization_name = sprintf("ORG %02d", 1:50),
                addr = rep("9 SHARED AVE", 50), zip = rep("10002", 50))
  r <- resolve_type2_bulk(tibble(id = "m", addr = "9 SHARED AVE", zip = "10002"), big)
  chk(r$n_candidates == 50L && r$status == "multiple_plausible",
      sprintf("T32-5 50 organizations sharing one address report n_candidates = 50, not truncated (got %d)",
              r$n_candidates))
}

# T32-6. Duplicate identical candidate ROWS (same NPI, address, ZIP, and
# name, listed twice -- e.g. an organization appearing twice in the bulk
# extract) must not inflate n_candidates. n_candidates counts ENTITIES
# (distinct NPIs), not listings -- the same label/quantity contract this
# session's own Cycle 31 fixed in a completely different file
# (scrape_healthgrades_midwives.R's hg_payor_n), found independently here in
# the Open Payments linkage path.
{
  one <- tibble(type2_npi = "1000000097", organization_name = "ATL CLINIC",
               addr = "1 PEACHTREE ST", zip = "30301")
  dup_org <- bind_rows(one, one)
  r <- resolve_type2_bulk(tibble(id = "m", addr = "1 PEACHTREE ST", zip = "30301"), dup_org)
  chk(r$n_candidates == 1L && r$status == "unique_exact",
      sprintf("T32-6 an organization listed twice in the candidate table still counts as 1 (got %d)",
              r$n_candidates))
}

cat("\n-- ADVERSARIAL --\n")

# T32-7. THE DEFECT (fixed this cycle). A zip column read as numeric (a
# common real occurrence: an upstream reader guesses integer for a column
# whose sample happened to contain no leading-zero values) silently drops the
# leading zero of any New-England/NJ/PR ZIP code. Before the fix, op_zip5()
# on the numeric 2138 returned NA and the id resolved to "no_match" --
# indistinguishable on the page from a genuine non-match. The function must
# now refuse this input loudly instead.
{
  org <- tibble(type2_npi = "1000000098", organization_name = "BOSTON CLINIC",
               addr = "1 BEACON ST", zip = "02138")
  err <- tryCatch({
    resolve_type2_bulk(tibble(id = "m", addr = "1 BEACON ST", zip = 2138), org)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("must be character", err) && grepl("zip", err),
      "T32-7 a numeric zip column is rejected loudly, naming the offending column")
  # ANTI-CEREMONY: prove the retired (unguarded) path actually produced the
  # silent wrong answer this test exists to prevent.
  chk(is.na(op_zip5(2138)) && !is.na(op_zip5("02138")),
      "T32-7b the retired path: op_zip5() on the bare numeric silently returns NA, unlike the string form")
}

# T32-8. THE DEFECT (fixed this cycle). An organization with no name on file
# (NA, not an empty string -- a real NPPES gap) previously collapsed via
# sort(unique(NA)) -> character(0) -> paste(..., collapse=...) == "", so a
# status of "unique_exact" (a positive resolution) was paired with a BLANK
# name string. A blank string reads as "resolved, name intentionally empty",
# not "name unknown" -- worse than surfacing the gap as NA.
{
  org <- tibble(type2_npi = "1000000099", organization_name = NA_character_,
               addr = "5 GHOST LN", zip = "30301")
  r <- resolve_type2_bulk(tibble(id = "m", addr = "5 GHOST LN", zip = "30301"), org)
  chk(r$status == "unique_exact" && is.na(r$organization_name),
      "T32-8 a candidate with no organization_name on file reports NA, not an empty string")
  # ANTI-CEREMONY: the retired collapse rule, applied directly.
  retired <- paste(sort(unique(NA_character_)), collapse = " / ")
  chk(identical(retired, ""),
      "T32-8b the retired sort(unique())-based collapse silently produces \"\" for all-NA input")
}

# T32-9. The same type contract extends to `addr`, not only `zip` -- a
# non-character address column (e.g. a factor, which base R's
# stringsAsFactors-era CSV readers and some database drivers still produce)
# must be refused for the same reason: op_norm_addr() would silently coerce
# it via as.character() on the factor's LEVEL, not necessarily the intended
# text, and any resulting mismatch would again present as an ordinary
# no_match.
{
  org <- tibble(type2_npi = "1000000097", organization_name = "ATL CLINIC",
               addr = "1 PEACHTREE ST", zip = "30301")
  err <- tryCatch({
    resolve_type2_bulk(tibble(id = "m", addr = factor("1 PEACHTREE ST"), zip = "30301"), org)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("must be character", err) && grepl("addr", err),
      "T32-9 a non-character (factor) addr column is also rejected loudly")
}

# T32-10. Join-noise robustness: thousands of UNRELATED candidate rows (random
# addresses and ZIPs that share no key with the query) mixed in with the one
# real match must not change the answer versus running against the relevant
# row alone -- guards against a hash-join collision or an accidental
# many-to-many blowup silently altering n_candidates when the surrounding
# table is large rather than small.
{
  set.seed(3201)
  noise <- tibble(
    type2_npi = sprintf("9%09d", 1:4000),
    organization_name = sprintf("NOISE ORG %d", 1:4000),
    addr = paste(sample(100:9999, 4000, replace = TRUE), "NOISE AVE"),
    zip = sprintf("%05d", sample(20000:29999, 4000, replace = TRUE)))
  real <- tibble(type2_npi = "1000000097", organization_name = "ATL CLINIC",
                addr = "1 PEACHTREE ST", zip = "30301")
  r_alone <- resolve_type2_bulk(tibble(id = "m", addr = "1 PEACHTREE ST", zip = "30301"), real)
  r_noisy <- resolve_type2_bulk(tibble(id = "m", addr = "1 PEACHTREE ST", zip = "30301"),
                                bind_rows(noise, real))
  chk(identical(r_alone, r_noisy),
      "T32-10 4,000 unrelated candidate rows do not change the resolution of the one real match")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
