#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 33 (4 BVA / 3 semantic / 3 adversarial)
# =============================================================================
# Target: R/lib/clinical_setting.R (facility_setting_category(),
# is_facility_setting_category()), a NEW shared helper created this cycle to
# fix a defect discovered while investigating validate_address_recency_
# pipeline.R (a cycle-32-flagged validation/backtesting lead).
#
# THE DEFECT: two fields encode the same 1-6 practice-setting taxonomy at
# different pipeline stages -- final_facility_setting ("1. Hospital
# Privileges...") and refined_clinical_setting ("1a. Active Attending
# Hospital Staff...", "1b. Inactive/Consulting..."). At least 7 files
# independently reimplemented `str_detect(refined_clinical_setting, "1\\.")`
# (or "2\\.", "3\\.") to detect a category -- a pattern that matches the bare
# pre-refinement format but can NEVER match the lettered post-refinement
# format, because a digit followed by a letter never contains a "digit.dot"
# substring. Verified empirically (see cycle-33 ledger entry): this silently
# reported 0 hospital-privilege and 0 birth-center matches out of 6 rows that
# should have reported 2 and 2, and left build_complete_leaflet_map.R's
# marker color-coding permanently on its amber fallback branch.
#
# Fixed with ONE shared, tested helper matching both formats, and every
# affected call site updated to use it: build_tier1_tier2_bon_summary_
# report.R, analyze_tier1_complete_results.R, analyze_tier2_complete_
# results.R, analyze_20_state_bon_scrape.R, validate_scraped_20_state_bon_
# results.R, validate_address_recency_pipeline.R, build_complete_leaflet_
# map.R.
#
# Run: Rscript tests/test_cycle33_facility_setting_category.R
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(stringr) })
source("R/lib/clinical_setting.R")

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

REFINED <- c(
  "1a. Active Attending Hospital Staff (Verified Medicare Privilege + Delivery Claims)",
  "1b. Inactive/Consulting Hospital Privileges (CMS Privilege Only)",
  "2a. Active Hospital Campus Practice (Exact Campus Address + Delivery Claims)",
  "2b. Hospital Campus Clinic Practice (Exact Address, Non-Delivery)",
  "3a. Active Birth Center Attending Midwife (CABC Registry + Delivery Claims)",
  "3b. Birth Center Outpatient/Admin Staff (CABC Registry, Non-Delivery)",
  "4a. Active Municipal Delivery Attender (Single Hospital + Delivery Claims)",
  "4b. Municipal Outpatient Clinic Midwife (Single Hospital Area)",
  "5a. Active Metro Health Group Delivery Attender (Multi-Hospital Area + Claims)",
  "5b. Metro Outpatient GYN/Prenatal Practice (Multi-Hospital Area)",
  "6. Independent Outpatient / Community Clinic Practice")
BARE <- c(
  "1. Hospital Privileges (CMS Medicare Direct)",
  "2. Hospital Campus Practice (Exact Street Address)",
  "3. Freestanding Birth Center (AABC Accredited / Birth Center Practice)",
  "4. Municipal Health System (Single OB Hospital)",
  "5. Outpatient / Multi-Hospital System Group",
  "6. Independent Outpatient / Community Health Practice")

cat("\n-- BVA --\n")

# T33-1. Full category range, both encodings: every category 1-6 is
# correctly recovered from BOTH the lettered (refined) and bare (final)
# formats, at the 1 (minimum) and 6 (maximum, no-letter-variant) boundaries
# in particular.
{
  chk(identical(facility_setting_category(REFINED),
                c(1L,1L,2L,2L,3L,3L,4L,4L,5L,5L,6L)),
      "T33-1a every refined_clinical_setting label recovers its correct category 1-6")
  chk(identical(facility_setting_category(BARE), 1:6),
      "T33-1b every final_facility_setting label recovers its correct category 1-6")
}

# T33-2. Out-of-range digits (0, 7) just outside the valid 1-6 boundary must
# not be mistaken for a real category.
{
  chk(is.na(facility_setting_category("0. Nothing")) &&
        is.na(facility_setting_category("7. Nothing")),
      "T33-2 categories 0 and 7 (just outside the valid 1-6 range) are NA, not misread")
}

# T33-3. A two-digit prefix ("10.", "12.") must not be truncated to its first
# digit and misread as category 1. The regex is anchored so the character
# after the leading digit must be a lowercase letter or the literal period --
# a second digit satisfies neither, so the match fails cleanly.
{
  chk(is.na(facility_setting_category("10. Something")) &&
        is.na(facility_setting_category("12. Something")),
      "T33-3 a two-digit prefix (10., 12.) is not truncated into a false category-1 match")
}

# T33-4. Degenerate 0-length/whitespace-only input: empty string, NA, and a
# bare space all resolve to NA, not to a spurious category or an error.
{
  chk(is.na(facility_setting_category("")) &&
        is.na(facility_setting_category(NA_character_)) &&
        is.na(facility_setting_category(" ")),
      "T33-4 empty string, NA, and whitespace-only input all resolve to NA")
}

cat("\n-- SEMANTIC --\n")

# T33-5. THE FIX. The same real-world category must be recoverable
# regardless of which pipeline stage produced the label -- that is the whole
# point of a "category" concept spanning two field formats. Anti-ceremony:
# the retired str_detect(x, "N\\.") pattern correctly detects the bare format
# but returns FALSE for every one of the 10 lettered (non-category-6) rows,
# proving it was silently stage-dependent when the concept it claims to
# detect is not.
{
  chk(all(is_facility_setting_category(REFINED[1:2], 1)) &&
        all(is_facility_setting_category(BARE[1], 1)),
      "T33-5 category 1 is detected identically whether the label is lettered or bare")
  # ANTI-CEREMONY: the retired per-file pattern, applied directly.
  retired_on_lettered <- str_detect(REFINED[1:10], "1\\.|2\\.|3\\.|4\\.|5\\.")
  chk(!any(retired_on_lettered),
      sprintf("T33-5b the retired str_detect(x, 'N\\\\.') pattern matches 0 of 10 lettered rows (got %d) -- it was stage-dependent",
              sum(retired_on_lettered)))
}

# T33-6. is_facility_setting_category(x, n) must always agree with
# facility_setting_category(x) == n for every category 1-6 -- the boolean
# helper's label ("is category n") must correspond exactly to the numeric
# quantity the other function claims to expose, not drift from it.
{
  agree <- vapply(1:6, function(n)
    identical(is_facility_setting_category(REFINED, n),
              facility_setting_category(REFINED) == n), logical(1))
  chk(all(agree), "T33-6 is_facility_setting_category() agrees with facility_setting_category()==n for every category 1-6")
}

# T33-7. The leaflet map's actual production color logic (replicated
# verbatim from build_complete_leaflet_map.R) must assign each category to
# EXACTLY ONE of its four mutually-exclusive branches -- category 1 must
# never fall through to the "2/4/5" purple branch, and vice versa.
{
  marker_color <- case_when(
    is_facility_setting_category(REFINED, 1) ~ "blue",
    is_facility_setting_category(REFINED, 3) ~ "green",
    facility_setting_category(REFINED) %in% c(2, 4, 5) ~ "purple",
    TRUE ~ "amber")
  expected <- c("blue","blue","purple","purple","green","green",
               "purple","purple","purple","purple","amber")
  chk(identical(marker_color, expected),
      "T33-7 the map's production color logic assigns each of the 11 labels to exactly the right bucket")
}

cat("\n-- ADVERSARIAL --\n")

# T33-8. REPO-WIDE SWEEP. No committed R file may still apply the retired
# str_detect(<...clinical_setting...>, "N\\.")-style pattern -- that is
# precisely the defect this cycle fixed, and a future edit re-adding an 8th
# call site the same broken way must be caught here rather than silently
# shipping another zero-count field. Comment lines are stripped first (a
# lesson learned the hard way in cycles 26/27), and each candidate file is
# also checked to source clinical_setting.R.
{
  r_files <- list.files(".", pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
  r_files <- r_files[!grepl("^\\./(tests|@archive|R/lib/clinical_setting\\.R)", r_files)]
  offenders <- character(0)
  for (f in r_files) {
    lines <- readLines(f, warn = FALSE)
    code_only <- lines[!grepl("^\\s*#", lines)]
    hit <- grepl("(refined_clinical_setting|final_facility_setting)", code_only) &
      grepl('str_detect\\([^)]*"[0-9]\\\\\\\\\\."', code_only)
    if (any(hit)) offenders <- c(offenders, f)
  }
  chk(length(offenders) == 0L,
      sprintf("T33-8 no file still applies the retired str_detect(...clinical_setting..., 'N\\\\.') pattern (offenders: %s)",
              if (length(offenders)) paste(offenders, collapse = ", ") else "none"))
}

# T33-9. Malformed/garbled labels -- an uppercase sub-letter ("1A." instead
# of "1a.") and a leading space (" 1a. Hospital", plausible after an
# upstream str_trim() that ran before this field was populated, or after one
# that was skipped) -- must resolve to NA rather than silently matching
# category 1 via a looser-than-intended pattern, or silently matching the
# wrong category. This is a known, documented limitation, not a defect this
# cycle fixes: real data has never been observed to contain either form, and
# guessing a normalization would risk manufacturing a false match.
{
  chk(is.na(facility_setting_category("1A. Hospital Privileges")) &&
        is.na(facility_setting_category(" 1a. Active Attending Hospital Staff")),
      "T33-9 an uppercase sub-letter or a leading space resolves to NA, not a guessed category")
}

# T33-10. Mixed-vintage input: a single vector containing BOTH bare
# (final_facility_setting-style) and lettered (refined_clinical_setting-
# style) rows -- as would occur if two artifacts from different pipeline
# stages were ever concatenated by mistake -- must classify every row
# correctly regardless of which format each individual row happens to use.
# The function's entire purpose is being format-agnostic; a version that only
# worked when EVERY row shared one format would not actually fix the defect.
{
  mixed <- c(BARE[1], REFINED[3], BARE[5], REFINED[11])
  chk(identical(facility_setting_category(mixed), c(1L, 2L, 5L, 6L)),
      "T33-10 a vector mixing bare and lettered rows classifies each row correctly")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
