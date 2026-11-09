#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: Table 1's dependencies (R/lib/table1_bands.R,
# R/lib/field_quality.R, R/join_safety.R, and the cohort filter itself)
# =============================================================================
# tests/test_table1_bands.R already covers band_years_since_enum,
# band_years_observed, band_rurality, band_hg_age, band_panel_median_age,
# table1_median_iqr and build_rucc_lookup with BVA/SEMANTIC/ADVERSARIAL
# sections. This file does not repeat those. It targets three functions
# build_table1_midwives.R calls for the Medicare DAC blocks that have NO
# existing test coverage at all (label_medicare_assignment,
# band_practice_size, band_practice_locations), field_quality.R's duplicate-
# key behavior, assert_unique_keys(dedupe = TRUE) in the exact shape Table
# 1's own cohort construction uses it, and -- the one most directly tied to
# this project's own tracked #233 cohort-count drift -- whether Table 1's
# inline cohort filter and canonical_active_primary() actually agree on who
# counts as a member. Every assertion is grounded in the committed
# implementation; where a saboteur finds a real gap rather than confirming a
# guard, it says so rather than asserting the gap closed.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages(library(dplyr))  # join_safety.R uses %>% and assumes it is already in scope
source(file.path(root, "R", "lib", "table1_bands.R"))
source(file.path(root, "R", "lib", "field_quality.R"))
source(file.path(root, "R", "lib", "cohort_definitions.R"))
suppressPackageStartupMessages(source(file.path(root, "R", "join_safety.R")))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

# =============================================================================
# label_medicare_assignment(): UNTESTED until this file. The docstring's own
# warning -- "the codes are Y and M, NOT Y and N" -- is the exact trap to try.
# =============================================================================
cat("\n-- label_medicare_assignment(): the Y/M trap, not Y/N --\n")

# S1. 'M' (may accept, non-participating) must NOT be labelled as a refusal.
# A naive Y/N reading of this code would misstate every M-coded midwife as
# refusing Medicare assignment outright.
chk(identical(label_medicare_assignment("M"), "May accept assignment (non-participating)"),
    "S1 'M' is NOT labelled a refusal -- it means may-accept, non-participating")

# S2. Lowercase and whitespace-padded codes, as a CSV re-export is liable to
# produce, still resolve correctly (toupper() + trimws() in the real code).
chk(identical(label_medicare_assignment(c(" y ", "m", "Y")),
              c("Accepts Medicare assignment", "May accept assignment (non-participating)",
                "Accepts Medicare assignment")),
    "S2 lowercase and whitespace-padded codes still resolve correctly")

# S3. Any code that is neither Y nor M (a literal "N", a blank, a stray "0")
# must become NA, not silently fall into one of the two real labels.
chk(all(is.na(label_medicare_assignment(c("N", "", "0", "n/a")))),
    "S3 a code that is neither Y nor M becomes NA, not a guessed label")

# S4. NA input stays NA, not the string \"NA\" -- toupper(trimws(as.character(NA)))
# is the string \"NA\", which does not equal \"Y\" or \"M\" and must still fall
# through to the NA branch rather than erroring or matching by accident.
chk(is.na(label_medicare_assignment(NA)), "S4 NA input produces NA output, not an error or a false match")

# =============================================================================
# band_practice_size(): UNTESTED until this file. THREE STATES, per its own
# docstring -- not-in-DAC, solo (in DAC, no group), and group-sized.
# =============================================================================
cat("\n-- band_practice_size(): three states, not two --\n")

# S5. in_dac = FALSE must be NA regardless of what n says -- a stray non-NA n
# value for someone not in DAC at all must not leak a group-size label.
chk(is.na(band_practice_size(n = 5, in_dac = FALSE)),
    "S5 in_dac = FALSE is NA even if n happens to carry a value")

# S6. in_dac = TRUE with n = NA is 'solo practice', the real documented
# third state -- distinct from, and must not collapse into, in_dac = FALSE's
# NA.
chk(identical(band_practice_size(n = NA, in_dac = TRUE), "No group affiliation (solo)"),
    "S6 in_dac = TRUE with no num_org_mem is 'solo', not the same NA as not-in-DAC")

# S7. Boundary values exactly on the band edges (10, 50, 250, 1000) land in
# the band that STARTS at that value, per the real >= comparisons, not the
# band below it.
chk(identical(band_practice_size(c(9, 10, 49, 50, 249, 250, 999, 1000), rep(TRUE, 8)),
              c("2-9 clinicians", "10-49 clinicians", "10-49 clinicians", "50-249 clinicians",
                "50-249 clinicians", "250-999 clinicians", "250-999 clinicians", ">=1,000 clinicians")),
    "S7 every boundary value lands in the band it opens, not the one below it")

# S8. NA for in_dac itself (not just n) must not crash the present-ness check
# (`!is.na(in_dac) & in_dac`) and must resolve to NA output, same as FALSE.
chk(is.na(band_practice_size(n = 12, in_dac = NA)),
    "S8 in_dac itself being NA resolves to NA output, not an error")

# =============================================================================
# band_practice_locations(): UNTESTED until this file.
# =============================================================================
cat("\n-- band_practice_locations(): boundary and non-DAC handling --\n")

# S9. n = 0 (a genuinely odd DAC row: present but zero addresses) must NOT be
# silently absorbed into any band -- it is not 1, not 2, and the ">= 3 & <= 4"
# / ">= 5" branches both require n >= 3, so 0 correctly falls through to NA.
# Worth confirming rather than assuming, since a bare `cut()`-style rule
# elsewhere in this codebase has made exactly this kind of off-by-one error.
chk(is.na(band_practice_locations(0)),
    "S9 n = 0 is NA, not silently folded into the '1 location' band")

# S10. The 2/3 boundary and 4/5 boundary land correctly.
chk(identical(band_practice_locations(c(2, 3, 4, 5)),
              c("2 locations", "3-4 locations", "3-4 locations", ">=5 locations")),
    "S10 the 2|3 and 4|5 band boundaries land on the correct side")

# S11. Absence (NA, meaning not in DAC) is NA, never coerced to a band --
# there is no in_dac argument here, so NA is the only signal "not present"
# has, and a numeric NA must not become 0 via as.numeric() coercion first.
chk(is.na(band_practice_locations(NA)), "S11 NA input (not in DAC) stays NA, not coerced to 0 locations")

# =============================================================================
# field_quality.R: cohort_coverage() and assert_not_constant() duplicate-key
# and escape-hatch behavior
# =============================================================================
cat("\n-- cohort_coverage() / assert_not_constant(): duplicate-key and escape-hatch traps --\n")

# S12. A cohort member appearing TWICE in `key` with a non-NA value (e.g. two
# Healthgrades location rows for one certificant) must count as covered
# ONCE, not twice -- n_with_value is a count of DISTINCT covered people, not
# of rows.
cc_s12 <- cohort_coverage(value = c("a", "b"), key = c("C1", "C1"), cohort = c("C1", "C2"))
chk(cc_s12$n_with_value == 1L && cc_s12$n_cohort == 2L,
    "S12 a cohort member appearing twice with a value is counted as covered ONCE, not twice")

# S13. A `key` value that is NOT in `cohort` at all (a row describing
# someone outside the published cohort, e.g. an ineligible Healthgrades
# match) must not inflate n_with_value or n_cohort.
cc_s13 <- cohort_coverage(value = "a", key = "NOT_IN_COHORT", cohort = c("C1", "C2"))
chk(cc_s13$n_with_value == 0L && cc_s13$n_cohort == 2L,
    "S13 a value attributed to someone outside the cohort does not inflate coverage")

# S14. `cohort` itself carrying a duplicate id must not double-count the
# denominator -- n_cohort is length(unique(cohort)), confirmed directly
# rather than assumed.
cc_s14 <- cohort_coverage(value = "a", key = "C1", cohort = c("C1", "C1", "C2"))
chk(cc_s14$n_cohort == 2L, "S14 a duplicated id in `cohort` itself does not inflate the denominator")

# S15. EMPTY and CONSTANT are different verdicts and assert_not_constant()
# must reject BOTH, not just CONSTANT -- an all-NA column is not "constant
# at NA", it carries zero information, same failure mode by a different name.
chk(field_variability(c(NA, NA))$verdict == "EMPTY" &&
    field_variability(c(0, 0, 0))$verdict == "CONSTANT",
    "S15 an all-NA column is EMPTY, a same-non-NA-value column is CONSTANT -- two distinct verdicts")
s15b_ok <- tryCatch({ assert_not_constant(c(NA, NA), "x"); FALSE },
                    error = function(e) grepl("EMPTY", conditionMessage(e)))
chk(s15b_ok, "S15b assert_not_constant() rejects an EMPTY column too, not only CONSTANT")

# S16. The allow_constant = TRUE escape hatch must actually work -- a
# legitimately-constant-by-design field (e.g. a column that is always "CNM"
# in a CNM-only extract) can still be published when the caller says so
# deliberately.
chk(isTRUE(assert_not_constant(c("CNM", "CNM"), "x", allow_constant = TRUE)),
    "S16 allow_constant = TRUE lets a deliberately-constant field through")

# =============================================================================
# assert_unique_keys(dedupe = TRUE): the EXACT shape Table 1's own cohort
# construction uses it (key = certification_number)
# =============================================================================
cat("\n-- assert_unique_keys(dedupe = TRUE): Table 1's own cohort-build guard --\n")

# S17. Two rows, same certification_number, IDENTICAL on every other column
# -- a harmless duplicate (e.g. re-run appended the same row twice) -- must
# collapse silently to one row, not stop.
df_s17 <- data.frame(certification_number = c("C1", "C1"), status = c("ACTIVE", "ACTIVE"),
                     npi = c("1000000001", "1000000001"))
res_s17 <- tryCatch(assert_unique_keys(df_s17, "certification_number", dedupe = TRUE),
                    error = function(e) conditionMessage(e))
chk(is.data.frame(res_s17) && nrow(res_s17) == 1L,
    "S17 an identical duplicate row collapses silently to one, no error")

# S18. Two rows, same certification_number, DISAGREEING on npi -- a genuine
# identity conflict, exactly the shape that would let row order silently
# decide which NPI a certificant is published against. Must stop, not pick
# one by position.
df_s18 <- data.frame(certification_number = c("C2", "C2"), status = c("ACTIVE", "ACTIVE"),
                     npi = c("1000000002", "1000000003"))
s18_err <- tryCatch(assert_unique_keys(df_s18, "certification_number", dedupe = TRUE),
                    error = function(e) conditionMessage(e))
chk(is.character(s18_err) && grepl("DISAGREE", s18_err, fixed = TRUE),
    "S18 two rows sharing a certification_number but disagreeing on npi stops, naming the disagreement")

# =============================================================================
# The cohort filter itself: does Table 1's inline rule agree with
# canonical_active_primary() on who is a member?
# =============================================================================
cat("\n-- Table 1's inline cohort filter vs canonical_active_primary() --\n")

# S19. REAL GAP, NOT A CONFIRMATION. build_table1_midwives.R builds its
# cohort as `link %>% filter(status == "ACTIVE", linkage_tier ==
# "primary_midwifery") %>% assert_unique_keys(...)` -- quoted directly from
# the script -- with NO check that npi is present at all. canonical_active_primary()
# additionally requires `!is.na(npi) & nzchar(npi)`. A certificant who is
# ACTIVE, tier primary_midwifery, but has a blank/NA npi (a real reachable
# shape -- see the identical gap already confirmed in
# tests/test_exclusion_flow_saboteurs.R S20 for canonical_active_primary()
# itself) is counted into Table 1's N but excluded from
# canonical_active_primary()'s membership count. This is the same SHAPE of
# disagreement already tracked as a real, open drift between table1.n and
# canonical_active_primary() (#233, docs/table1_midwives.md's own 12,171 vs
# 12,170 note) -- demonstrated here at the single-row level rather than left
# as an aggregate count difference with no example.
linkage_s19 <- data.frame(
  certification_number = "C9", status = "ACTIVE", linkage_tier = "primary_midwifery",
  npi = NA_character_, nppes_state = "CO", stringsAsFactors = FALSE)
table1_inline_filter_n <- nrow(linkage_s19[linkage_s19$status == "ACTIVE" &
                                            linkage_s19$linkage_tier == "primary_midwifery", ])
membership_n_s19 <- nrow(canonical_active_primary(linkage_s19))
gap_open_19 <- table1_inline_filter_n == 1L && membership_n_s19 == 0L
chk(gap_open_19,
    paste("S19 GAP (not fixed by this file): a blank-npi ACTIVE primary_midwifery row is",
          "counted into Table 1's N (1) but excluded from canonical_active_primary() membership (0).",
          "Fix in build_table1_midwives.R: build `coh` via canonical_active_primary(link) instead of",
          "reimplementing the filter inline, so the two counts cannot drift apart on this row shape."))

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
