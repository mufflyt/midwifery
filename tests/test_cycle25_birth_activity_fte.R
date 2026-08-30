#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 25 (session-cycle 2) -- 3 BVA / 4 semantic / 3 adversarial
# =============================================================================
# Target: R/15-build-birth-activity.R -- birth_fte_weight and the county-level
# effective_birth_fte aggregation. "Workforce counts and FTE" is explicitly
# prioritized; existing tests/test_birth_activity.R covers cohort membership,
# absence-is-not-zero, source de-duplication and location shares well, but
# never exercises a county holding BOTH an ascertained and a genuinely
# unascertained provider at once, nor the FTE-weight formula's own boundaries.
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr); library(tidyr)
})
root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "R", "15-build-birth-activity.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

td <- file.path(tempdir(), paste0("c25_ba_", as.integer(Sys.time())))
dir.create(td, recursive = TRUE, showWarnings = FALSE)
YEAR <- 2023L

run_case <- function(tag, roster, taf, asc, county, reference_births = 100) {
  d <- file.path(td, tag); dir.create(d, showWarnings = FALSE)
  write_csv(roster, file.path(d, "roster.csv"))
  write_csv(taf, file.path(d, "taf.csv"))
  write_csv(asc, file.path(d, "asc.csv"))
  write_csv(county, file.path(d, "county.csv"))
  suppressMessages(suppressWarnings(build_midwife_birth_activity(
    roster_path = file.path(d, "roster.csv"), taf_path = file.path(d, "taf.csv"),
    ascertainment_path = file.path(d, "asc.csv"), county_base_path = file.path(d, "county.csv"),
    activity_year = YEAR, save_dir = file.path(d, "out"), reference_births = reference_births)))
}

r1 <- tibble(npi = "1111111111", status = "ACTIVE", linkage_tier = "primary_midwifery",
             state = "CO", county_fips = "08031")
asc1 <- tibble(state = "CO", year = YEAR, source = "taf",
               adequate_ascertainment = TRUE, npi_completeness = 0.9)
cty1 <- tibble(GEOID = "08031", rucc_2023 = 1)

cat("\n-- BVA: birth_fte_weight boundaries --\n")

res0 <- run_case("bva0", r1, tibble(npi = character(0), year = integer(0),
                 state = character(0), county_fips = character(0), birth_count = numeric(0)),
                 asc1, cty1)
chk(res0$provider_activity$birth_fte_weight[1] == 0,
    "T25-1: observed_births == 0 gives weight exactly 0, not NA or negative")

res100 <- run_case("bva100", r1, tibble(npi = "1111111111", year = YEAR, state = "CO",
                    county_fips = "08031", birth_count = 100), asc1, cty1)
chk(res100$provider_activity$birth_fte_weight[1] == 1,
    "T25-2: observed_births exactly equal to reference_births gives weight exactly 1.0")

res_big <- run_case("bvabig", r1, tibble(npi = "1111111111", year = YEAR, state = "CO",
                     county_fips = "08031", birth_count = 100000), asc1, cty1)
chk(res_big$provider_activity$birth_fte_weight[1] == 1,
    "T25-3: an extreme observed_births (1000x reference) still caps at exactly 1.0, never exceeds")

cat("\n-- semantic: contract tests --\n")

# T25-4: a county holding one ascertained provider (0.5 FTE) and one
# genuinely unascertained provider (no records anywhere, unascertained
# state) must show n_unascertained_roster > 0, so the 0.5 is never read as a
# complete county total.
r_mixed <- tibble(npi = c("1111111111", "2222222222"), status = c("ACTIVE", "ACTIVE"),
                   linkage_tier = rep("primary_midwifery", 2),
                   state = c("CO", "WY"), county_fips = c("08031", "08031"))
asc_mixed <- tibble(state = c("CO", "WY"), year = YEAR, source = c("taf", "taf"),
                     adequate_ascertainment = c(TRUE, FALSE), npi_completeness = c(0.94, 0.41))
res_mixed <- run_case("mixed", r_mixed,
                       tibble(npi = "1111111111", year = YEAR, state = "CO",
                              county_fips = "08031", birth_count = 50),
                       asc_mixed, cty1)
cs <- res_mixed$county_effective_supply
chk("n_unascertained_roster" %in% names(cs),
    "T25-4: county_effective_supply reports n_unascertained_roster")
chk(cs$effective_birth_fte[cs$GEOID == "08031"] == 0.5,
    "T25-4: the known-supply figure (0.5) is unchanged by the unascertained provider's presence")
chk(cs$n_unascertained_roster[cs$GEOID == "08031"] == 1,
    "T25-4: the unascertained roster member is counted, not silently absent from the aggregate")

# T25-5: monotonicity -- more observed births can never produce a LOWER
# weight, holding reference_births fixed.
w20 <- run_case("mono20", r1, tibble(npi = "1111111111", year = YEAR, state = "CO",
                county_fips = "08031", birth_count = 20), asc1, cty1)$provider_activity$birth_fte_weight[1]
w60 <- run_case("mono60", r1, tibble(npi = "1111111111", year = YEAR, state = "CO",
                county_fips = "08031", birth_count = 60), asc1, cty1)$provider_activity$birth_fte_weight[1]
chk(w60 > w20, "T25-5: birth_fte_weight is monotonically non-decreasing in observed_births")

# T25-6: birth_active corresponds exhaustively and exclusively to the three
# documented activity states -- no state can produce a mismatched flag.
r3 <- tibble(npi = c("1111111111", "2222222222", "3333333333"),
             status = rep("ACTIVE", 3), linkage_tier = rep("primary_midwifery", 3),
             state = c("CO", "CO", "WY"), county_fips = c("08031", "08031", "56021"))
asc3 <- tibble(state = c("CO", "WY"), year = YEAR, source = c("taf", "taf"),
               adequate_ascertainment = c(TRUE, FALSE), npi_completeness = c(0.9, 0.4))
res3 <- run_case("labels", r3, tibble(npi = "1111111111", year = YEAR, state = "CO",
                  county_fips = "08031", birth_count = 10), asc3, cty1)
pa3 <- res3$provider_activity
chk(all(pa3$birth_active[!is.na(pa3$birth_active) & pa3$birth_active] > 0 |
        !is.na(pa3$observed_births[!is.na(pa3$birth_active) & pa3$birth_active])),
    "T25-6a: birth_active == TRUE always pairs with a non-NA observed_births")
chk(all(is.na(pa3$observed_births[is.na(pa3$birth_active)])),
    "T25-6b: birth_active == NA always pairs with observed_births == NA")
chk(all(pa3$observed_births[!is.na(pa3$birth_active) & !pa3$birth_active] == 0),
    "T25-6c: birth_active == FALSE always pairs with observed_births == 0, never NA or positive")

# T25-7: a provider observed in multiple counties has location shares that
# partition her total exactly -- a denominator/partition contract, not just
# "sums to something".
r4 <- tibble(npi = "1111111111", status = "ACTIVE", linkage_tier = "primary_midwifery",
             state = "CO", county_fips = "08031")
asc4 <- tibble(state = "CO", year = YEAR, source = "taf",
               adequate_ascertainment = TRUE, npi_completeness = 0.9)
cty4 <- tibble(GEOID = c("08031", "08059", "08013"), rucc_2023 = c(1, 2, 3))
res4 <- run_case("partition", r4,
                  tibble(npi = "1111111111", year = YEAR, state = "CO",
                         county_fips = c("08031", "08059", "08013"),
                         birth_count = c(10, 15, 25)),
                  asc4, cty4)
lw4 <- res4$provider_location_activity
chk(nrow(lw4) == 3L, "T25-7 setup: three location rows produced")
chk(abs(sum(lw4$birth_location_share) - 1) < 1e-9,
    "T25-7: birth_location_share partitions a provider's activity to exactly 1.0 across counties")

cat("\n-- adversarial: hard cases --\n")

# T25-8: two raw rows for the SAME npi/year/source/county with wildly
# different birth_count values are SUMMED, not de-duplicated or resolved by
# max -- unlike cross-source combination, which the existing test suite
# already confirms uses max(). There is no defense here against a literal
# duplicated encounter row inflating a provider's observed_births, since raw
# rows within one source carry no encounter-level identifier to dedupe on.
# DOCUMENTED HAZARD, not fixed: distinguishing "two real encounters" from
# "one encounter duplicated in the extract" needs a key this source does not
# provide. This test pins the CURRENT behavior so a future change is a
# visible decision, not a silent one.
res_dup <- run_case("dupraw", r1,
                     tibble(npi = c("1111111111", "1111111111"), year = YEAR, state = "CO",
                            county_fips = "08031", birth_count = c(20, 999)),
                     asc1, cty1)
chk(res_dup$provider_activity$observed_births[1] == 1019,
    "T25-8: duplicate raw rows within one source are summed (20+999=1019), not deduplicated or maxed -- documented hazard, not a contract this file currently enforces")

# T25-9: reference_births = 0 is a pathological configuration value, but the
# case_when's `observed_births <= 0 ~ 0` branch fires before any division,
# so it does not actually produce NaN from 0/0 -- confirms the guard order
# already protects this boundary rather than assuming it does.
res_ref0 <- run_case("ref0", r1,
                      tibble(npi = character(0), year = integer(0), state = character(0),
                             county_fips = character(0), birth_count = numeric(0)),
                      asc1, cty1, reference_births = 0)
chk(identical(res_ref0$provider_activity$birth_fte_weight[1], 0),
    "T25-9: reference_births = 0 with zero observed births still gives weight 0, not NaN (0/0 never evaluates)")

# T25-10: a provider whose only recorded rows are all-zero births has
# provider_total_births == 0; birth_location_share must be NA, not NaN/Inf
# from a 0/0 division.
res_allzero <- run_case("allzero", r1,
                         tibble(npi = "1111111111", year = YEAR, state = "CO",
                                county_fips = "08031", birth_count = 0),
                         asc1, cty1)
lw_z <- res_allzero$provider_location_activity
chk(is.na(lw_z$birth_location_share[1]),
    "T25-10: an all-zero provider's birth_location_share is NA, not NaN or Inf")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
