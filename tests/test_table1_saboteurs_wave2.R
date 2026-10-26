#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests, wave 2: Table 1's remaining dependencies
# (R/lib/training_institution.R, R/lib/artifact_provenance.R, fresh edge
# cases in R/lib/table1_bands.R and R/lib/field_quality.R,
# canonical_active_primary() NPI-length)
# =============================================================================
# tests/test_table1_saboteurs.R (wave 1) covered label_medicare_assignment(),
# band_practice_size(), band_practice_locations(), cohort_coverage()'s
# duplicate-key behavior, assert_not_constant(), assert_unique_keys(dedupe =
# TRUE), and the Table-1-vs-canonical_active_primary() blank-NPI divergence.
# This wave was scoped by reading the SIBLING /isochrones repo's own
# saboteur suite first (tests/testthat/test-table1-saboteur-fixes-2026-04-25.R
# and test-step2.5-cohort-exclusion-saboteurs-deepest.R) -- isochrones has
# already fought, and documented, real bugs in code of the exact same shape
# this project's Table 1 depends on. Three of the cases below (S1-S3) are
# transferred bug CLASSES from that history, re-verified against THIS
# repo's actual code rather than assumed to apply. The rest target real
# functions in this repo with no prior test coverage at all. Every
# assertion is grounded in the committed implementation; a gap is reported
# as a gap, not silently asserted closed.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})
source(file.path(root, "R", "lib", "table1_bands.R"))
source(file.path(root, "R", "lib", "field_quality.R"))
source(file.path(root, "R", "lib", "cohort_definitions.R"))
source(file.path(root, "R", "lib", "training_institution.R"))
source(file.path(root, "R", "lib", "artifact_provenance.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

# =============================================================================
# Transferred from /isochrones: tests/testthat/test-table1-saboteur-fixes-
# 2026-04-25.R documents formatC(npi, format = "d") silently overflowing
# (32-bit int) for ~78% of real 10-digit NPIs -- any NPI above 2^31-1
# (2,147,483,647), which is most of them, since NPIs start with 1 or 2.
# =============================================================================
cat("\n-- transferred from isochrones: NPI formatting precision --\n")

# S1. The DANGEROUS pattern, reproduced directly to confirm the failure mode
# is real and would still bite THIS codebase if it ever appeared here --
# not a hypothetical, a documented isochrones production bug.
high_npis <- c(1234567890, 9876543210, 9999999999)
dangerous <- suppressWarnings(formatC(high_npis, width = 10, flag = "0", format = "d"))
chk(any(grepl("NA", dangerous)),
    "S1 formatC(npi, format='d') overflows for high NPIs -- confirms the isochrones bug class is real, not theoretical")

# S2. The pattern this repo actually uses throughout (as.character() on a
# double, confirmed via grep across harvest_cms_national_provider_directory.py's
# R-side counterparts and every `mutate(npi = as.character(npi))` call in
# build_table1_midwives.R) does NOT share this flaw -- doubles have 53 bits of
# mantissa, comfortably more than the ~34 bits a 10-digit number needs.
safe <- as.character(high_npis)
chk(!any(grepl("NA", safe)) && all(nchar(safe) == 10L) &&
    identical(safe, c("1234567890", "9876543210", "9999999999")),
    "S2 as.character() on the same high NPIs -- this repo's actual pattern -- preserves all 10 digits")

# S3. GAP, NOT A CONFIRMATION (but a mitigated one). write_csv() on a
# character NPI column, read back with read_csv(show_col_types = FALSE) and
# NO explicit col_types, silently returns npi as NUMERIC, not character --
# readr's type-guesser sees plain digit text and infers <dbl>. The VALUE is
# not corrupted (doubles carry 53 bits, comfortably enough for 10 digits),
# but the TYPE changes silently, which can break a later join against a
# character key. This repo's actual convention -- `mutate(npi =
# as.character(npi))` immediately after every real read_csv() call, seen
# throughout build_table1_midwives.R, build_geography_by_amcb_status.R, and
# the exclusion-flow scripts -- is exactly the compensating habit that
# avoids this, which is why it has not bitten in practice. This saboteur
# exists so that habit stays deliberate, not accidental.
tmp_s3 <- tempfile(fileext = ".csv")
on.exit(unlink(tmp_s3), add = TRUE)
readr::write_csv(data.frame(npi = as.character(high_npis)), tmp_s3)
back <- readr::read_csv(tmp_s3, show_col_types = FALSE, progress = FALSE)$npi
gap_open_3 <- is.numeric(back) && identical(as.character(back), as.character(high_npis))
chk(gap_open_3,
    paste("S3 GAP (mitigated by convention, not by the tool): a plain read_csv() with no col_types",
          "silently returns a digit-string NPI column as numeric, not character. The VALUE round-trips",
          "exactly (confirmed); the TYPE does not, unless the caller re-coerces -- which this repo's",
          "scripts consistently do, but the tool itself does not guarantee it."))

# =============================================================================
# Transferred from isochrones (SAB-83/84: leading zeros, over-length
# strings): canonical_active_primary() checks PRESENCE of npi but not its
# SHAPE.
# =============================================================================
cat("\n-- transferred from isochrones: NPI shape, not just presence --\n")

# S4. GAP, NOT A CONFIRMATION. canonical_active_primary()'s membership test
# is `!is.na(npi) & nzchar(npi)` -- no length or digit-pattern check. An
# 11-digit garbage string (a real NPI with a stray trailing character, or
# two NPIs concatenated by a bad export) passes as "has an npi" exactly as
# readily as a genuine 10-digit one.
linkage_s4 <- data.frame(
  certification_number = "C10", status = "ACTIVE", linkage_tier = "primary_midwifery",
  npi = "100300183599", nppes_state = "CO", stringsAsFactors = FALSE)
gap_open_4 <- nrow(canonical_active_primary(linkage_s4)) == 1L
chk(gap_open_4,
    paste("S4 GAP (not fixed by this file): a 12-digit garbage npi string counts as analytic",
          "membership -- canonical_active_primary() never checks grepl('^[0-9]{10}$', npi)."))

# =============================================================================
# write_with_provenance(): transferred from isochrones' "NPPES cache written
# via temp+rename (atomic)" test -- this repo's OWN atomic-write helper
# (R/lib/resume_state.R::atomic_write_csv) exists for exactly this reason,
# so does the shared Table 1 provenance writer also follow it?
# =============================================================================
cat("\n-- write_with_provenance(): atomicity, checked not assumed --\n")

# S5. GAP, NOT A CONFIRMATION. write_with_provenance() calls
# readr::write_csv(x, path, ...) directly against the final path -- no
# temp-file-and-rename. A process killed mid-write leaves a torn CSV under
# the SAME filename a complete run would have produced, exactly the failure
# DEBT.md D1 and R/lib/resume_state.R's atomic_saveRDS()/atomic_write_csv()
# already exist to prevent for OTHER writers in this codebase. This one
# writer that every Table-1-adjacent script calls does not use them.
src_lines <- readLines(file.path(root, "R", "lib", "artifact_provenance.R"))
wp_body <- src_lines[grep("^write_with_provenance", src_lines):
                      (grep("^write_with_provenance", src_lines) + 5)]
gap_open_5 <- any(grepl("write_csv\\(x, path", wp_body)) &&
              !any(grepl("tmp|temp|\\.part|rename", wp_body, ignore.case = TRUE))
chk(gap_open_5,
    paste("S5 GAP (not fixed by this file): write_with_provenance() writes readr::write_csv()",
          "directly to the final path, with no temp-file-and-rename -- not atomic, unlike this",
          "codebase's own resume_state.R helpers for the same risk."))

# S6. What IS already correct: the sidecar is a SEPARATE write after the
# main artifact, so a reader checking for the sidecar's existence as a
# completeness signal is at least checking a file written strictly after
# (never before) the data it describes -- confirmed by inspection, not
# just assumed from the function's position in the file.
chk(grepl("write_csv", src_lines[grep("^write_with_provenance", src_lines)[1] + 1]) &&
    any(grepl("write_json", src_lines[grep("^write_with_provenance", src_lines)[1]:
                                       (grep("^write_with_provenance", src_lines)[1] + 15)])),
    "S6 the provenance sidecar is written strictly after the main artifact, in source order")

# =============================================================================
# training_norm_school(): real function, zero prior coverage
# =============================================================================
cat("\n-- training_norm_school(): adversarial institution-name strings --\n")

# S7. Unicode/escaped ampersand entities, all three forms the function
# claims to handle, must all normalize to the word AND. No spaces are
# expected around it here because none are present in the source text
# either (\U0026 sits directly between "A" and "M", same as a real
# "A&M" institution name would) -- verified directly via charToRaw() against
# the sourced function rather than assumed from reading the regex.
chk(identical(
      training_norm_school(c("Texas A\\U0026M", "Texas A\\u0026M", "Texas A&AMP;M")),
      rep("TEXAS AANDM", 3)),
    "S7 all three ampersand-entity forms normalize identically to AND")

# S8. A leading "THE " is stripped, but "THE" appearing elsewhere in the
# name is NOT -- the rule is anchored to the start, not a global removal.
chk(identical(training_norm_school("The Ohio State University"), "OHIO STATE UNIVERSITY") &&
    identical(training_norm_school("Better Than The Rest University"),
              "BETTER THAN THE REST UNIVERSITY"),
    "S8 a leading 'THE ' is stripped; 'THE' elsewhere in the name is untouched")

# S9. A string that is non-NA but becomes empty after stripping
# non-alphanumerics (e.g. "***" or "----") must return NA, not "" -- the
# function's own ifelse(is.na(x) | !nzchar(y), NA, y) exists for exactly
# this, confirmed directly rather than assumed from reading the line.
chk(is.na(training_norm_school("***")) && is.na(training_norm_school("   ")),
    "S9 a string that normalizes to nothing becomes NA, not an empty string")

# S10. NA input stays NA, not the literal string \"NA\" -- as.character(NA)
# is the string \"NA\" in general, so this depends on the is.na() check
# running BEFORE, not after, the toupper()/str_squish() chain.
chk(is.na(training_norm_school(NA)), "S10 NA input produces NA output, not the literal string 'NA'")

# =============================================================================
# training_source_dac(): real function, zero prior coverage. Tests the
# documented row-order-independence rule directly.
# =============================================================================
cat("\n-- training_source_dac(): OTHER-vs-real-school resolution --\n")

run_dac <- function(rows) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  write_csv(rows, tmp)
  training_source_dac(tmp)
}

# S11/S12. The SAME two rows for one NPI (one OTHER, one a real school), in
# BOTH orders, must resolve to the real school either way -- the rule is
# documented as NOT depending on file order, tested in both directions
# rather than trusting the one order a developer happens to write first.
rows_a <- data.frame(NPI = c("1000000020", "1000000020"),
                     med_sch_raw = c("OTHER", "UNIVERSITY OF COLORADO SCHOOL OF MEDICINE"))
rows_b <- rows_a[rev(seq_len(nrow(rows_a))), ]
res_a <- run_dac(rows_a); res_b <- run_dac(rows_b)
chk(identical(res_a$dac_school, res_b$dac_school) && !is.na(res_a$dac_school) &&
    toupper(res_a$dac_school) != "OTHER",
    "S11/S12 OTHER-then-real and real-then-OTHER resolve identically to the real school, not by row order")

# S13. A row whose ONLY value is "OTHER" (DAC could not code any school for
# this NPI) must resolve to NA, not the literal string "OTHER" -- a reader
# counting named institutions must not see "OTHER" as if it were one.
res_s13 <- run_dac(data.frame(NPI = "1000000021", med_sch_raw = "OTHER"))
chk(is.na(res_s13$dac_school), "S13 a lone 'OTHER' row resolves to NA, not the literal string 'OTHER'")

# S14. A missing file returns NULL (the documented degrade-gracefully
# contract), not an error -- callers (training_attach()) depend on being
# able to skip an absent source rather than crash the whole Table 1 build.
chk(is.null(training_source_dac("/nonexistent/path/does_not_exist.csv")),
    "S14 a missing DAC file returns NULL, not an error")

# =============================================================================
# Fresh edge cases in table1_bands.R not covered by tests/test_table1_bands.R
# =============================================================================
cat("\n-- table1_bands.R: fresh edge cases (parse_enum_year, band_cert_decade) --\n")

# S15. A string with NO digits at all must return NA cleanly, not error --
# neither the ISO branch nor the trailing-four-digit branch matches, and
# the function must not throw on a non-matching regex.
chk(is.na(parse_enum_year("not a date")), "S15 a string with no digits at all returns NA, not an error")

# S16. A bare empty string, as a blank CSV cell commonly becomes after
# read_csv(), returns NA -- confirmed directly rather than assumed to behave
# like NA_character_ input.
chk(is.na(parse_enum_year("")), "S16 an empty string (common blank-cell shape) returns NA")

# S17. band_cert_decade() on a plausible-FORMAT but implausible-RANGE date
# (year 1899, below the default min_year = 1950) returns NA, not a
# confidently wrong \"1890s\" -- the plausibility window is enforced on the
# PARSED year, not just the regex match.
chk(is.na(band_cert_decade("01/01/1899")),
    "S17 a well-formatted but implausible year (1899) bands to NA, not a wrong decade")

# S18. band_cert_decade() on zero-length input returns character(0), not
# logical(0) -- the docstring calls this out explicitly (\"Caught by T12a\")
# for band_cert_decade; confirmed here again as a direct regression guard
# since this exact type-instability class recurs across this file's
# functions (parse_enum_year feeding it is the shared risk).
chk(identical(band_cert_decade(character(0)), character(0)),
    "S18 zero-length input returns character(0), not logical(0) (type-unstable ifelse() trap)")

# =============================================================================
# field_quality.R: Inf is not a real value, but field_variability() does
# not know that
# =============================================================================
cat("\n-- field_quality.R: Inf is treated as a real distinct value --\n")

# S19. GAP, NOT A CONFIRMATION. field_variability() classifies by counting
# unique() non-NA values with no numeric sanity check -- c(1, Inf) reports
# VARIES (2 distinct values) as confidently as c(1, 2) would, even though
# Inf is a parse artefact in this codebase's own convention (table1_bands.R's
# banding functions all explicitly exclude it via !is.finite()). A column
# that is genuinely CONSTANT except for stray Inf parse failures would be
# misclassified as informative.
gap_open_19 <- field_variability(c(1, Inf, 1, 1))$verdict == "VARIES"
chk(gap_open_19,
    paste("S19 GAP (not fixed by this file): field_variability(c(1, Inf, 1, 1)) reports VARIES,",
          "treating a stray Inf parse artefact as a second real value rather than noise -- unlike",
          "every banding function in table1_bands.R, which explicitly excludes !is.finite() values."))

# =============================================================================
# build_rucc_lookup(): all-NA and zero-row inputs
# =============================================================================
cat("\n-- build_rucc_lookup(): all-NA and zero-row inputs --\n")

# S20. Every county NA for rucc (a vintage file with the column present but
# entirely blank) must not crash table()-based conflict detection -- NA
# codes are not conflicting with each other (table() drops NA by default),
# so this should return one row per county with rucc = NA, not stop().
res_s20 <- tryCatch(
  build_rucc_lookup(c("08001", "08003"), c(NA, NA)),
  error = function(e) conditionMessage(e))
chk(is.data.frame(res_s20) && nrow(res_s20) == 2L && all(is.na(res_s20$rucc)),
    "S20 an all-NA rucc column returns one row per county with NA rucc, not a crash")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
