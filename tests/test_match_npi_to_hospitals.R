#!/usr/bin/env Rscript
# =============================================================================
# Unit Tests for match_npi_to_hospitals()
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr)
})

source("R/lib/common_helpers.R")
source("R/lib/match_npi_to_hospitals.R")

cat("=== Running Unit Tests for match_npi_to_hospitals() ===\n\n")

# Test 1: Function returns valid tibble for empty input
cat("Test 1: Empty input handling...\n")
res_empty <- match_npi_to_hospitals(character(0))
stopifnot(is.data.frame(res_empty))
stopifnot(nrow(res_empty) == 0)
cat("  PASSED.\n\n")

# Test 2: Function preserves alphanumeric CCNs
cat("Test 2: Alphanumeric CCN padding...\n")
ccn_test <- pad_ccn("1T001")
stopifnot(ccn_test == "01T001")
cat("  PASSED (pad_ccn('1T001') -> '01T001').\n\n")

# Test 3: Match known NPI (Northwestern Memorial Hospital NPI 1841988748)
cat("Test 3: Match known NPI 1841988748...\n")
res_npi <- match_npi_to_hospitals("1841988748")
stopifnot(nrow(res_npi) == 1)

# UPDATED 2026-08-16. This asserted is_enrolled_dac == TRUE for an NPI whose
# only evidence is a facility affiliation -- which is precisely the defect
# docs/HANDOFF_is_enrolled_dac.md describes. The test encoded the bug: it
# treated "has a hospital privilege" as proof of Medicare enrollment.
#
# Without an enrollment register the flag is now NA, because "we did not look"
# and "we looked and they are not enrolled" are different claims.
stopifnot(is.na(res_npi$is_enrolled_dac[1]))

# Supply the register and it resolves. Affiliation is untouched either way --
# the two variables are independent, which is the whole point of the fix.
res_reg <- match_npi_to_hospitals("1841988748",
                                  dac_national_npis = c("1841988748"))
stopifnot(isTRUE(res_reg$is_enrolled_dac[1]))
res_out <- match_npi_to_hospitals("1841988748",
                                  dac_national_npis = c("9999999999"))
stopifnot(isFALSE(res_out$is_enrolled_dac[1]))

stopifnot(res_npi$has_hospital_privilege[1] == TRUE)
stopifnot(res_npi$cms_ccn[1] == "140281")
stopifnot(res_npi$hospital_name[1] == "NORTHWESTERN MEMORIAL HOSPITAL")
cat("  PASSED: 1841988748 -> NORTHWESTERN MEMORIAL HOSPITAL (CCN: 140281).\n\n")

# Test 4: Option include_unmatched = FALSE
cat("Test 4: Filtering include_unmatched = FALSE...\n")
fake_and_real <- c("1841988748", "9999999999")
res_filtered <- match_npi_to_hospitals(fake_and_real, include_unmatched = FALSE)
stopifnot(nrow(res_filtered) == 1)
stopifnot(res_filtered$npi[1] == "1841988748")
cat("  PASSED.\n\n")

cat("=== ALL UNIT TESTS PASSED SUCCESSFULLY! ===\n")
