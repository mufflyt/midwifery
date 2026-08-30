#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 41 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Target: two of the 110 bare distinct(key, .keep_all = TRUE) sites cataloged
# by cycle 40's widened T44 sweep, triaged for actual fixes because both sit
# at genuinely high-consequence points: build_table1_midwives.R:55 defines
# the COHORT for the entire published Table 1 (N is the denominator every
# percentage in the table is taken against), and assign_hpsa_status.R:56
# dedupes the geocoded INPUT locations that determine a real, plausible
# per-person conflict -- a midwife with two practice addresses, one inside a
# shortage area and one outside it.
#
# Both replaced distinct(.keep_all = TRUE) with assert_unique_keys(dedupe =
# TRUE) (R/join_safety.R, this repo's established tool for exactly this
# problem, already applied in cycles 28 and 39): identical duplicate rows
# still collapse for free, but a genuine conflict now stops the run and
# names the disagreeing column(s) instead of silently choosing by row order.
#
# Both host files are flat, unguarded top-to-bottom scripts (build_table1_
# midwives.R needs a real linkage CSV; assign_hpsa_status.R needs sf and an
# external HRSA shapefile) and cannot be sourced end-to-end, so their logic
# is replicated literally; assert_unique_keys() itself is sourced directly,
# since it is pure and needs no artifact.
#
# Run: Rscript tests/test_cycle41_table1_hpsa_dedup.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(checkmate) })
source("R/join_safety.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replicas of the two fixed sites.
build_cohort <- function(link) {
  link %>%
    filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    assert_unique_keys("certification_number",
                       label = "Table 1 cohort linkage (ACTIVE primary_midwifery)", dedupe = TRUE)
}
build_hpsa_input <- function(geo) {
  geo %>%
    filter(!is.na(latitude), !is.na(longitude)) %>%
    assert_unique_keys("certification_number",
                       label = "geocoded midwife locations (HPSA input)", dedupe = TRUE)
}

cat("\n-- BVA --\n")

# T41-1. The minimum cohort case: a single ACTIVE, primary_midwifery record
# with no duplicates at all passes through both filter and dedup unchanged,
# contributing exactly 1 to N.
{
  link <- tibble(certification_number = "C1", status = "ACTIVE",
                linkage_tier = "primary_midwifery", npi = "1111111111")
  coh <- build_cohort(link)
  chk(nrow(coh) == 1L,
      "T41-1 a single non-duplicated ACTIVE record contributes exactly 1 to N")
}

# T41-2. Zero-row input (an empty roster slice, e.g. a filtered subgroup with
# no ACTIVE primary_midwifery members at all) must not error inside
# assert_unique_keys()'s own count()/filter() machinery -- N = 0 is a valid,
# if unusual, answer.
{
  link0 <- tibble(certification_number = character(0), status = character(0),
                  linkage_tier = character(0), npi = character(0))
  coh0 <- build_cohort(link0)
  chk(is.data.frame(coh0) && nrow(coh0) == 0L,
      "T41-2 an empty ACTIVE/primary_midwifery slice passes through as 0 rows, not an error")
}

# T41-3. Exactly 2 identical duplicate rows (the minimum non-trivial
# collapse case) reduce to exactly 1, for both fixed sites -- neither
# over-collapses to 0 nor leaves the duplicate uncollapsed.
{
  link_dup <- tibble(certification_number = c("C1", "C1"), status = "ACTIVE",
                     linkage_tier = "primary_midwifery", npi = c("1111111111", "1111111111"))
  chk(nrow(build_cohort(link_dup)) == 1L,
      "T41-3a two identical Table 1 linkage rows collapse to 1")
  geo_dup <- tibble(certification_number = c("C1", "C1"),
                    latitude = c(39.7, 39.7), longitude = c(-104.9, -104.9))
  chk(nrow(build_hpsa_input(geo_dup)) == 1L,
      "T41-3b two identical HPSA-input geocoded rows collapse to 1")
}

cat("\n-- SEMANTIC --\n")

# T41-4. THE FIX (Table 1 cohort). A certification_number appearing twice
# with two DIFFERENT npi values -- a genuine identity conflict in the exact
# file that defines Table 1's own N -- must stop the run and name npi as the
# disagreement, not silently decide who is IN the published cohort by row
# order.
{
  link_conflict <- tibble(certification_number = c("C1", "C1"), status = "ACTIVE",
                          linkage_tier = "primary_midwifery",
                          npi = c("1111111111", "2222222222"))
  err <- tryCatch({ build_cohort(link_conflict); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err) && grepl("npi", err),
      sprintf("T41-4 two different NPIs for one certification_number error, naming npi, instead of silently picking Table 1's cohort membership (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T41-5. THE FIX (HPSA input). A midwife geocoded at two genuinely different
# lat/lon pairs -- a plausible two-practice-location shape for this
# artifact -- must stop the run and name the disagreeing coordinate
# column(s), not silently test only one address against the shortage-area
# layer while the other, possibly-shortage-area address is never checked.
{
  geo_conflict <- tibble(certification_number = c("C1", "C1"),
                         latitude = c(39.7, 40.0), longitude = c(-104.9, -105.2))
  err <- tryCatch({ build_hpsa_input(geo_conflict); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err) &&
        (grepl("latitude", err) || grepl("longitude", err)),
      sprintf("T41-5 two different lat/lon pairs for one certification_number error, naming the coordinate column, instead of silently testing only one address (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T41-6. Anti-ceremony for both fixes at once: the retired distinct()-based
# rule, applied directly to the SAME two conflicting fixtures, silently
# resolves each to a DIFFERENT answer depending on row order -- proving both
# defects were real, not merely theoretical.
{
  link_a <- tibble(certification_number = c("C1", "C1"), status = "ACTIVE",
                   linkage_tier = "primary_midwifery", npi = c("1111111111", "2222222222"))
  link_b <- link_a[c(2, 1), ]
  retired_a <- link_a %>% filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number, .keep_all = TRUE)
  retired_b <- link_b %>% filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number, .keep_all = TRUE)
  chk(!identical(retired_a$npi, retired_b$npi),
      sprintf("T41-6 the retired distinct() rule assigns a DIFFERENT NPI to certification_number C1 depending on row order ('%s' vs '%s')",
              retired_a$npi, retired_b$npi))
}

cat("\n-- ADVERSARIAL --\n")

# T41-7. A 3-way conflict (not just pairwise): three rows for one
# certification_number, two agreeing and one disagreeing, must still be
# refused -- not resolved by majority vote, which this repository's own
# convention (see cycle 39's T39-10) has already established is not how a
# real conflict should be settled.
{
  link3 <- tibble(certification_number = rep("C1", 3), status = "ACTIVE",
                  linkage_tier = "primary_midwifery",
                  npi = c("1111111111", "1111111111", "2222222222"))
  err <- tryCatch({ build_cohort(link3); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err),
      sprintf("T41-7 a 3-row group (2 agreeing, 1 conflicting) is refused, not resolved by majority (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T41-8. Malformed/adversarial input: an NA certification_number must not be
# silently treated as a valid, mergeable key -- multiple NA-keyed rows would
# otherwise be grouped together as if NA were one legitimate identity,
# potentially masking real conflicts among genuinely different people who
# all happen to have a missing identifier.
{
  link_na <- tibble(certification_number = c(NA_character_, NA_character_),
                    status = "ACTIVE", linkage_tier = "primary_midwifery",
                    npi = c("1111111111", "2222222222"))
  err <- tryCatch({ build_cohort(link_na); "NO ERROR" },
                  error = function(e) conditionMessage(e))
  chk(!identical(err, "NO ERROR"),
      sprintf("T41-8 two NA-keyed rows with different NPIs are still refused as a conflict, not silently merged under a shared NA identity (got: %s)",
              err))
}

# T41-9. The two fixed sites are independent: a conflict in the Table 1
# cohort linkage must not be masked or altered by data passed to the HPSA
# input builder, and vice versa -- each assert_unique_keys() call operates
# only on its own data, confirming the fix at one site did not accidentally
# share state with the other (e.g. via a global option or cached environment
# assert_unique_keys() might use internally).
{
  link_conflict <- tibble(certification_number = c("C1", "C1"), status = "ACTIVE",
                          linkage_tier = "primary_midwifery",
                          npi = c("1111111111", "2222222222"))
  geo_clean <- tibble(certification_number = "C2", latitude = 39.7, longitude = -104.9)
  err1 <- tryCatch({ build_cohort(link_conflict); NA_character_ },
                   error = function(e) conditionMessage(e))
  hpsa_result <- build_hpsa_input(geo_clean)
  chk(!is.na(err1) && nrow(hpsa_result) == 1L,
      "T41-9 a conflict in the Table 1 cohort call does not affect an unrelated, clean HPSA-input call")
}

# T41-10. Unrelated columns disagreeing (not the identifying column) must
# still be named as the conflict, not just reported generically -- verifying
# assert_unique_keys()'s own disagreement-detection correctly identifies
# WHICH auxiliary column varies when there are several candidate columns,
# not just that "something" disagrees.
{
  link_multi <- tibble(certification_number = c("C1", "C1"), status = "ACTIVE",
                       linkage_tier = "primary_midwifery",
                       npi = c("1111111111", "1111111111"),
                       nppes_state = c("CO", "TX"))
  err <- tryCatch({ build_cohort(link_multi); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("nppes_state", err) && !grepl("\\bnpi\\b,", err),
      sprintf("T41-10 when only nppes_state disagrees (npi agrees), the error names nppes_state specifically, not npi (got: %s)",
              if (is.na(err)) "no error" else err))
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
