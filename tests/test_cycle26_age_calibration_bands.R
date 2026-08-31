#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 26 (session-cycle 3 of 24) -- 3 BVA / 3 semantic / 4 adversarial
# =============================================================================
# Target: calibrate_amcb_certification_ages.R -- the OLS age-imputation model
# that feeds Table 1's "Calibrated Age (100% Cohort Coverage)" block. Zero
# prior tests existed for this file's own logic (it is only mentioned, never
# exercised, by tests/ci_science_contracts.R). "Calibration" and "uncertainty
# propagation" are both explicitly prioritized for this loop.
#
# The file cannot be run end-to-end here -- its ground-truth inputs (WA voter
# ages, Healthgrades scrapes) are person-level and gitignored -- so these
# tests exercise its SOURCE CONTRACT (does it delegate to the shared, tested
# banding function rather than a private copy) and the INTERACTION between
# its own literal fallback constants (DEFAULT_ENTRY_AGE, the OLS extrapolation
# formula, the cert_year plausibility window) and that shared function -- a
# genuinely new contract. band_hg_age() itself is already exhaustively tested
# in tests/test_table1_bands.R and is not re-tested here.
root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "R", "lib", "table1_bands.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

src_path <- file.path(root, "calibrate_amcb_certification_ages.R")
src_lines <- readLines(src_path, warn = FALSE)
code_only <- src_lines[!grepl("^\\s*#", src_lines)]
code_txt  <- paste(code_only, collapse = "\n")

cat("\n-- semantic --\n")
chk(grepl("table1_bands\\.R", code_txt),
    "T26-1: calibrate_amcb_certification_ages.R sources the shared banding library")
chk(grepl("age_band\\s*=\\s*band_hg_age\\(", code_txt),
    "T26-2: age_band is assigned via band_hg_age(), not an inline rule")

default_entry_age <- as.numeric(sub(".*DEFAULT_ENTRY_AGE <- ([0-9.]+).*", "\\1",
                                     grep("DEFAULT_ENTRY_AGE <-", code_only, value = TRUE)[1]))
max_years_certified <- 2026L - 1950L  # structural bound from this file's own cert_year filter
steep_beta <- 1.3  # a plausible-but-steeper real OLS slope than the beta=1.0 fallback
steep_fitted_age_oldest <- default_entry_age + steep_beta * max_years_certified

chk(is.na(band_hg_age(steep_fitted_age_oldest)),
    sprintf("T26-7 (uncertainty propagation): a plausible-slope OLS extrapolation to the oldest structurally-possible certificant (years_certified=%d, fitted_age=%.1f) is now rejected as NA, not banded and published",
            max_years_certified, steep_fitted_age_oldest))

cat("\n-- BVA --\n")
chk(!is.na(default_entry_age),
    "T26-5: DEFAULT_ENTRY_AGE was found and parsed from the source (fallback constant is readable, not silently hardcoded elsewhere)")
chk(!is.na(band_hg_age(default_entry_age)),
    sprintf("T26-5b: the literature-prior fallback entry age (%.1f) is itself plausible, not silently unbandable", default_entry_age))

fallback_fitted_age_oldest <- default_entry_age + 1.0 * max_years_certified
chk(!is.na(band_hg_age(fallback_fitted_age_oldest)),
    sprintf("T26-6: under the literature-prior fallback (beta=1.0), the oldest structurally-possible certificant (years_certified=%d) still gets a plausible fitted age (%.1f) -- the new guard does not over-reject the ordinary case",
            max_years_certified, fallback_fitted_age_oldest))

old_inline_age_band <- function(final_age) {
  dplyr::case_when(
    final_age < 35 ~ "<35 years",
    final_age < 45 ~ "35-44 years",
    final_age < 55 ~ "45-54 years",
    final_age < 65 ~ "55-64 years",
    final_age >= 65 ~ ">=65 years",
    TRUE ~ NA_character_
  )
}
chk(old_inline_age_band(-10) == "<35 years",
    "T26-9: the RETIRED inline rule's FIRST branch (`< 35`) catches any value below 35, including impossible negative ones -- it has no LOWER bound either, the same 'out-of-range codes labelled, not rejected' shape cycle 1 found for RUCC codes")

cat("\n-- adversarial --\n")
# Fingerprint an actual DUPLICATE RULE (a case_when-style comparison chain
# using these breakpoints), not bare co-occurrence of the label strings --
# both build_table1_midwives.R and this file legitimately reference the same
# five label strings in a plain ordering vector (`lvls = c("<35 years", ...)`,
# `match(age_band, c("<35 years", ...))`) to sort an ALREADY-COMPUTED
# age_band column. That is not a second banding rule.
#
# Matched PER LINE, not on a collapsed multi-line blob: an earlier version of
# this test used `.*` across the whole file, and in base R's regex engine `.`
# matches newlines too, so it matched from an unrelated `~` (this file's own
# `lm(known_age ~ years_certified, ...)` model FORMULA syntax, nothing to do
# with case_when) all the way to an unrelated "35" elsewhere in the file. A
# real case_when branch (`final_age < 35 ~ "<35 years"`) has its comparison
# and its `~` on the SAME line, which is what this now requires.
rule_pattern <- "[<>]=?\\s*35\\b.*~"
chk(!any(grepl(rule_pattern, code_only)),
    "T26-3: no inline comparison-based age-banding RULE survives in this file's own code (ordering vectors referencing the label strings are fine; a case_when-style rule is not)")

r_files <- list.files(root, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
r_files <- r_files[!grepl("R/lib/table1_bands\\.R$|tests/test_table1_bands\\.R$|tests/test_cycle26|@archive/", r_files)]
inline_hits <- character(0)
for (f in r_files) {
  txt <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
  txt <- txt[!grepl("^\\s*#", txt)]
  if (any(grepl(rule_pattern, txt))) inline_hits <- c(inline_hits, f)
}
chk(length(inline_hits) == 0L,
    sprintf("T26-4: no OTHER file (beyond the shared library) carries an inline copy of the age-banding RULE (found: %s) -- cycle 1's own lesson was that a fix applied to n of m copies is a fix applied to none",
            if (length(inline_hits)) paste(inline_hits, collapse = ", ") else "none"))

chk(old_inline_age_band(steep_fitted_age_oldest) == ">=65 years",
    "T26-8 (anti-ceremony): the RETIRED inline rule banded T26-7's implausible extrapolated age as a real category ('>=65 years') instead of rejecting it -- confirms T26-7 discriminates rather than passing vacuously")

chk(!is.na(old_inline_age_band(200)),
    "T26-10: the retired rule bands an outright impossible age of 200 as '>=65 years' -- the concrete defect this cycle fixes, independent of any particular OLS slope")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
