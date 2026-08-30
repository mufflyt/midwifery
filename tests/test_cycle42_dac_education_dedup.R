#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 42 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: two more of build_table1_midwives.R's bare distinct(key, .keep_all
# = TRUE) sites (from cycle 40's widened T44 inventory), both reading
# artifacts/dac_cnm_education.csv keyed on npi. DAC (CMS's Doctors and
# Clinicians National File) is built from PECOS Medicare ENROLLMENT, which
# can span more than one organization/location per NPI -- num_org_mem and
# n_locations exist as columns precisely because that shape is expected and
# real, not an error. Two enrollment rows disagreeing on those counts is a
# genuine multi-enrollment fact; picking one by row order would silently
# choose which real enrollment a provider's Table 1 row describes.
#
# QUICK FOLLOW-UP FIRST (not a new fix, a status check): re-read R/07-cohort-
# composition.R and confirmed PR #135's relationship="many-to-one" fix
# targeted the missingness-ledger's OWN grp_sizes join (left_join(grp_sizes,
# by="group")) -- a different join from the one cycle 37's T37-8 actually
# left open (compose() itself has no internal duplicate-row guard on its
# input `d`, relying entirely on the joins that BUILD `d`, all of which
# already had relationship="many-to-one" declared before PR #135 landed).
# Cycle 37's decision stands exactly as documented: not a defect, a
# caller-provided assumption, unaffected by PR #135. No action taken.
#
# A REAL SUBTLETY FOUND WHILE FIXING THIS CYCLE'S TWO SITES: applying
# assert_unique_keys() to the FULL raw CSV row (before narrowing to the
# columns a given extraction actually uses) makes EVERY multi-enrollment NPI
# look like a conflict, even when the specific field being extracted agrees
# across enrollments -- because OTHER columns (num_org_mem, n_locations)
# legitimately vary per enrollment for reasons that have nothing to do with,
# say, the person's medical school. The fix is select() BEFORE the
# uniqueness check, narrowing to exactly the columns that matter for that
# extraction. Both sites were corrected to do this; this cycle's tests pin
# the distinction directly.
#
# Neither of these two DAC read sites nor R/07-cohort-composition.R can be
# sourced end-to-end (one is a flat script needing a real linkage CSV, the
# other needs gitignored FROZEN artifacts), so their logic is replicated
# literally; assert_unique_keys() itself is sourced directly.
#
# Run: Rscript tests/test_cycle42_dac_education_dedup.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(checkmate) })
source("R/join_safety.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

# Literal replicas of the two fixed sites (build_table1_midwives.R).
build_dacx <- function(raw) {
  raw %>%
    mutate(npi = as.character(NPI)) %>%
    select(npi, num_org_mem, n_locations, accepts_assignment) %>%
    assert_unique_keys("npi", label = "DAC CNM education (num_org_mem/n_locations)", dedupe = TRUE)
}
build_dac_sch <- function(raw) {
  raw %>%
    mutate(npi = as.character(NPI)) %>%
    select(npi, med_sch_clean) %>%
    assert_unique_keys("npi", label = "DAC CNM education (medical school)", dedupe = TRUE) %>%
    transmute(npi, dac_school = ifelse(!is.na(med_sch_clean) & med_sch_clean != "OTHER",
                                       med_sch_clean, NA_character_))
}

cat("\n-- BVA --\n")

# T42-1. The minimum single-enrollment case: one NPI, one row, passes
# through both builders unchanged.
{
  raw <- tibble(NPI = "1111111111", num_org_mem = 2L, n_locations = 2L,
               accepts_assignment = TRUE, med_sch_clean = "HARVARD")
  chk(nrow(build_dacx(raw)) == 1L && nrow(build_dac_sch(raw)) == 1L,
      "T42-1 a single enrollment row for one NPI passes through both builders unchanged")
}

# T42-2. Zero-row input (an empty DAC extract, e.g. a filtered slice with no
# CNM enrollments at all) passes through as 0 rows, not an error.
{
  raw0 <- tibble(NPI = character(0), num_org_mem = integer(0),
                n_locations = integer(0), accepts_assignment = logical(0),
                med_sch_clean = character(0))
  chk(nrow(build_dacx(raw0)) == 0L && nrow(build_dac_sch(raw0)) == 0L,
      "T42-2 an empty DAC extract passes through as 0 rows for both builders")
}

# T42-3. Exactly 2 identical enrollment rows (the minimum non-trivial
# collapse case) reduce to exactly 1 for both builders.
{
  raw_dup <- tibble(NPI = c("1111111111", "1111111111"),
                    num_org_mem = c(2L, 2L), n_locations = c(2L, 2L),
                    accepts_assignment = c(TRUE, TRUE), med_sch_clean = c("HARVARD", "HARVARD"))
  chk(nrow(build_dacx(raw_dup)) == 1L && nrow(build_dac_sch(raw_dup)) == 1L,
      "T42-3 two fully identical enrollment rows collapse to 1 for both builders")
}

# T42-4. The MAXIMUM plausible enrollment count for one NPI (5+ organization
# memberships, all agreeing on every field) still collapses to exactly 1 --
# the collapse is not accidentally bounded to only 2-row groups.
{
  raw_many <- tibble(NPI = rep("1111111111", 5), num_org_mem = rep(5L, 5),
                     n_locations = rep(5L, 5), accepts_assignment = rep(TRUE, 5),
                     med_sch_clean = rep("HARVARD", 5))
  chk(nrow(build_dacx(raw_many)) == 1L,
      sprintf("T42-4 five identical enrollment rows for one NPI still collapse to exactly 1 (got %d)",
              nrow(build_dacx(raw_many))))
}

cat("\n-- SEMANTIC --\n")

# T42-5. THE FIX (dacx). Two enrollment rows genuinely disagreeing on
# num_org_mem/n_locations -- the real, expected multi-enrollment shape this
# file's own header describes -- must stop and name the disagreement, not
# silently pick one enrollment's counts by row order.
{
  raw <- tibble(NPI = c("1111111111", "1111111111"),
               num_org_mem = c(2L, 5L), n_locations = c(2L, 5L),
               accepts_assignment = c(TRUE, TRUE))
  err <- tryCatch({ build_dacx(raw); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err) && grepl("num_org_mem", err),
      sprintf("T42-5 disagreeing num_org_mem/n_locations across enrollments errors, naming the columns (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T42-6. THE SUBTLETY THIS CYCLE FOUND. Two enrollment rows that genuinely
# disagree on num_org_mem (a real, expected difference) but agree on
# med_sch_clean must NOT cause the medical-school extraction to error --
# select()-ing to just the relevant columns before the uniqueness check
# means an unrelated column's legitimate variation cannot block an
# extraction that never looks at it.
{
  raw <- tibble(NPI = c("1111111111", "1111111111"),
               num_org_mem = c(2L, 5L), n_locations = c(2L, 5L),
               med_sch_clean = c("HARVARD", "HARVARD"))
  out <- build_dac_sch(raw)
  chk(nrow(out) == 1L && out$dac_school == "HARVARD",
      sprintf("T42-6 a legitimate num_org_mem difference does not block the unrelated school extraction (got nrow=%d, school=%s)",
              nrow(out), if (nrow(out)) out$dac_school else NA))
}

# T42-7. Anti-ceremony for T42-6: applying the uniqueness check WITHOUT
# narrowing columns first -- exactly what this cycle's first draft did,
# before the subtlety was found -- reproduces a false-positive error on the
# very same "agrees on school, differs only on enrollment count" fixture.
{
  raw <- tibble(NPI = c("1111111111", "1111111111"),
               num_org_mem = c(2L, 5L), n_locations = c(2L, 5L),
               med_sch_clean = c("HARVARD", "HARVARD"))
  err <- tryCatch({
    raw %>% mutate(npi = as.character(NPI)) %>%
      assert_unique_keys("npi", label = "test", dedupe = TRUE)
    NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("num_org_mem", err),
      sprintf("T42-7 checking uniqueness on the FULL raw row (the retired approach) false-positives on an unrelated column's legitimate variation (got: %s)",
              if (is.na(err)) "no error -- would have been correct by luck" else err))
}

cat("\n-- ADVERSARIAL --\n")

# T42-8. A 3-way conflict on the field that actually matters for dacx: two
# rows agree on num_org_mem, one disagrees -- must still be refused, not
# resolved by majority.
{
  raw3 <- tibble(NPI = rep("1111111111", 3), num_org_mem = c(2L, 2L, 5L),
                n_locations = c(2L, 2L, 5L), accepts_assignment = rep(TRUE, 3))
  err <- tryCatch({ build_dacx(raw3); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("DISAGREE", err),
      sprintf("T42-8 a 3-row group (2 agreeing, 1 conflicting) on num_org_mem is refused, not resolved by majority (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T42-9. NA vs. a real value for med_sch_clean across two enrollment rows is
# still a genuine disagreement (one enrollment record has education data,
# the other does not) -- not treated as "compatible" just because one side
# is missing rather than actively contradicting.
{
  raw <- tibble(NPI = c("1111111111", "1111111111"),
               med_sch_clean = c("HARVARD", NA_character_))
  err <- tryCatch({ build_dac_sch(raw); NA_character_ },
                  error = function(e) conditionMessage(e))
  chk(!is.na(err) && grepl("med_sch_clean", err),
      sprintf("T42-9 NA vs. a real school value for one NPI is treated as a genuine disagreement, not silently resolved toward the non-missing value (got: %s)",
              if (is.na(err)) "no error" else err))
}

# T42-10. The two builders are independent: a conflict detected by dacx's
# check must not be masked, cached, or otherwise carried over into a
# separate, unrelated call to the school builder on clean data -- each
# assert_unique_keys() call is scoped to its own input.
{
  raw_conflict <- tibble(NPI = c("1111111111", "1111111111"),
                         num_org_mem = c(2L, 5L), n_locations = c(2L, 5L),
                         accepts_assignment = c(TRUE, TRUE))
  raw_clean_school <- tibble(NPI = "2222222222", med_sch_clean = "YALE")
  err1 <- tryCatch({ build_dacx(raw_conflict); NA_character_ },
                   error = function(e) conditionMessage(e))
  school_result <- build_dac_sch(raw_clean_school)
  chk(!is.na(err1) && nrow(school_result) == 1L && school_result$dac_school == "YALE",
      "T42-10 a conflict in one builder's call does not affect an unrelated, clean call to the other builder")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
