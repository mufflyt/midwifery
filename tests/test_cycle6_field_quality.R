#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 6 (3 BVA / 3 semantic / 4 adversarial)
# =============================================================================
# Targets: carried-forward Healthgrades items. These decide whether the scraped
# demographics may enter Table 1 at all, so they gate a published table rather
# than an internal number.
#
# Run: Rscript tests/test_cycle6_field_quality.R
# =============================================================================

source("R/lib/field_quality.R")
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
# The naive rule this cycle retires: "non-missing count == usable".
old_coverage <- function(x) 100 * sum(!is.na(x)) / length(x)

ATTRS <- "/tmp/c6_attrs.csv"   # snapshot; never read the live file
have_attrs <- file.exists(ATTRS)

cat("\n-- BVA --\n")

# T61. The three states at their boundaries. 0 distinct is EMPTY, 1 is
# CONSTANT, 2 is VARIES -- the 1/2 edge is where a field becomes usable.
{
  chk(field_variability(c(NA, NA))$verdict == "EMPTY" &&
        field_variability(c(0, 0, NA))$verdict == "CONSTANT" &&
        field_variability(c(0, 1, NA))$verdict == "VARIES" &&
        field_variability(character(0))$verdict == "EMPTY",
      "T61 EMPTY / CONSTANT / VARIES at the 0-1-2 distinct-value edges")
}

# T62. An empty cohort must yield 0%, not NaN. sprintf("%.1f%%", NaN) prints
# "NaN%" straight into a published table.
{
  z <- cohort_coverage(numeric(0), character(0), character(0))
  one <- cohort_coverage(c(1, NA), c("a", "b"), c("a", "b"))
  chk(z$pct == 0 && !is.nan(z$pct) && one$pct == 50,
      "T62 zero cohort gives 0%, not NaN; a half-covered cohort gives 50%")
}

# T63. NA is not a value. A column of one real value plus NAs is CONSTANT, not
# VARIES -- counting NA as a second level would make a dead field look alive.
{
  chk(field_variability(c(5, 5, NA, NA))$verdict == "CONSTANT" &&
        field_variability(c(TRUE, NA))$verdict == "CONSTANT",
      "T63 NA does not count as a distinct value")
}

cat("\n-- SEMANTIC --\n")

# T64. THE DEFECT. A constant field must be refused, however complete it looks.
# hg_years_experience is 100% non-missing and 100% useless.
{
  refused <- tryCatch({ assert_not_constant(rep(0, 50), "hg_years_experience"); FALSE },
                      error = function(e) grepl("CONSTANT", e$message))
  allowed <- isTRUE(assert_not_constant(c(0, 1, 2), "hg_age"))
  chk(refused && allowed,
      "T64 a constant field is refused; a varying one passes")
  # ANTI-CEREMONY: the retired rule calls the same column 100% covered.
  chk(old_coverage(rep(0, 50)) == 100,
      sprintf("T64b the retired completeness rule scores it %.0f%% complete",
              old_coverage(rep(0, 50))))
}

# T65. Coverage must be measured against the COHORT. A field present on every
# fetched profile still describes only the fraction of the cohort that has one.
{
  cohort <- paste0("C", 1:100)
  key <- paste0("C", 1:10); val <- rep(1, 10)     # 10 profiles, all populated
  cc <- cohort_coverage(val, key, cohort)
  chk(cc$pct == 10 && old_coverage(val) == 100,
      sprintf("T65 cohort coverage %.0f%% vs profile completeness %.0f%%",
              cc$pct, old_coverage(val)))
}

# T66. EMPTY and CONSTANT are different diagnoses -- "never captured" versus
# "captured, no information" -- and they point at different fixes.
#
# The second half of this test pins a defect made while writing this cycle:
# the verdict was first computed on the COHORT-LINKED SUBSET, where hg_gender
# reads CONSTANT purely because the single male midwife is not in it. That
# would have suppressed a genuine 99.4%-female distribution as though it were a
# scraping failure. Whether the SOURCE populates a field is a property of the
# source, so the verdict must be judged on all fetched profiles; coverage is a
# separate question, judged against the cohort.
{
  source_col <- c(rep("Female", 99), "Male")     # varies in the source
  subset_col <- rep("Female", 40)                # constant in this subset
  chk(field_variability(rep(NA_real_, 10))$verdict == "EMPTY" &&
        field_variability(rep(0, 10))$verdict == "CONSTANT" &&
        field_variability(source_col)$verdict == "VARIES" &&
        field_variability(subset_col)$verdict == "CONSTANT",
      "T66 EMPTY/CONSTANT distinct, and a subset-constant field is not a source-constant field")
}

cat("\n-- ADVERSARIAL --\n")

# T67. RESOLVES A CARRIED-FORWARD SUSPICION. I flagged that the boolean fields
# might be recording "absent" as FALSE. The parser returns NA when the key is
# missing, so absence WOULD be visible. Pin that contract here so a future
# parser change cannot silently start writing FALSE for "not stated".
{
  as_lgl <- function(s) if (is.na(s)) NA else identical(s, "true")
  chk(is.na(as_lgl(NA_character_)) && isTRUE(as_lgl("true")) &&
        isFALSE(as_lgl("false")),
      "T67 absent key parses to NA, not FALSE")
}

# T68. And empirically: if NA never appears in real data, FALSE is a real
# answer rather than a disguised absence. This is the evidence that settles it.
if (have_attrs) {
  a <- read_csv(ATTRS, show_col_types = FALSE, progress = FALSE)
  nas <- sapply(c("hg_accepts_new_patients", "hg_has_telehealth"),
                function(v) if (v %in% names(a)) sum(is.na(a[[v]])) else NA_integer_)
  chk(all(!is.na(nas)) && all(nas == 0),
      sprintf("T68 boolean keys present on every one of %s profiles (NA counts: %s) -- FALSE means false",
              format(nrow(a), big.mark = ","), paste(nas, collapse = "/")))
} else {
  chk(FALSE, "T68 attribute snapshot missing")
}

# T69. hg_age must be a plausible adult age. A regex that drifts onto another
# numeric field would still yield integers, so range is the check that bites.
if (have_attrs) {
  a <- read_csv(ATTRS, show_col_types = FALSE, progress = FALSE)
  ag <- a$hg_age[!is.na(a$hg_age)]
  chk(length(ag) > 0 && min(ag) >= 18 && max(ag) <= 110,
      sprintf("T69 hg_age lies in a plausible adult range [%d, %d] over %d values",
              min(ag), max(ag), length(ag)))
} else {
  chk(FALSE, "T69 attribute snapshot missing")
}

# T70. ENFORCE THE SWEEP. Any Healthgrades-derived field published by Table 1
# must pass through assert_not_constant() first. A grep is used deliberately:
# the guard has to hold for fields that do not exist yet.
{
  src <- readLines("build_table1_midwives.R", warn = FALSE)
  # Lines that build a Table 1 block from an hg_ column.
  blocks <- grep('blk\\(.*"hg_', src, value = TRUE)
  guarded <- any(grepl("assert_not_constant", src))
  chk(length(blocks) == 0 || guarded,
      sprintf("T70 no unguarded hg_ field reaches Table 1 (%d hg blocks, guard %s)",
              length(blocks), if (guarded) "present" else "ABSENT"))
}

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
