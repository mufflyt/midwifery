#!/usr/bin/env Rscript
# =============================================================================
# Tests for build_midwife_birth_activity()
# =============================================================================
# The property that matters most: a midwife absent from every activity source
# must have missing activity status with observed_births = NA, UNLESS her
# state-year is declared adequately ascertained. If that ever collapses to a
# zero, the layer silently converts "we did not look" into "she attends no
# births" -- and every poorly-reporting state would appear to hold an inactive
# workforce.
#
# Fixtures are synthetic. No TAF or birth-certificate data exists locally yet.
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr)
  library(tidyr)
})
source("R/15-build-birth-activity.R")

FAILS <- character(0)
ok <- function(name, cond) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", name))
  else { FAILS <<- c(FAILS, name); cat(sprintf("  FAIL  %s\n", name)) }
}

td <- file.path(tempdir(), paste0("ba_", as.integer(Sys.time())))
dir.create(td, recursive = TRUE, showWarnings = FALSE)
YEAR <- 2023L

# CO is adequately ascertained; WY is NOT.
#   m1 CO  attends births, seen in both sources
#   m2 CO  no births anywhere -> a LEGITIMATE zero
#   m3 WY  no births anywhere -> must stay UNOBSERVED, not zero
#   m4 CO  high volume, two counties -> FTE cap and location shares
#   m5 CO  INACTIVE certificant -> excluded from the cohort entirely
#   m6 CO rural (08079) attends births -> ascertainable rural, active
#   m7 CO rural (08079) no births        -> ascertainable rural, zero
# Without at least one ascertainable midwife on BOTH sides of the rural split
# the validation cannot be computed -- which is the correct behaviour, and is
# why the first version of this fixture produced an empty result.
roster <- tibble(
  npi = c("1111111111","2222222222","3333333333","4444444444","5555555555",
          "6666666666","7777777777"),
  status = c("ACTIVE","ACTIVE","ACTIVE","ACTIVE","INACTIVE","ACTIVE","ACTIVE"),
  linkage_tier = rep("primary_midwifery", 7),
  state = c("CO","CO","WY","CO","CO","CO","CO"),
  county_fips = c("08031","08059","56021","08031","08031","08079","08079"))
write_csv(roster, file.path(td, "roster.csv"))

write_csv(tibble(
  npi = c("1111111111","4444444444","4444444444","6666666666"),
  year = YEAR, state = c("CO","CO","CO","CO"),
  county_fips = c("08031","08031","08059","08079"),
  birth_count = c(20, 90, 30, 40)), file.path(td, "taf.csv"))

write_csv(tibble(
  npi = c("1111111111"), year = YEAR, state = "CO",
  county_fips = "08031", birth_count = 25), file.path(td, "bc.csv"))

write_csv(tibble(
  state = c("CO","CO","WY"), year = YEAR,
  source = c("taf","birth_certificate","birth_certificate"),
  adequate_ascertainment = c(TRUE, TRUE, FALSE),
  npi_completeness = c(0.94, 0.97, 0.41)),
  file.path(td, "asc.csv"))

write_csv(tibble(
  GEOID = c("08031","08059","56021","08079"),
  rucc_2023 = c(1, 2, 7, 7)), file.path(td, "county.csv"))

res <- build_midwife_birth_activity(
  roster_path = file.path(td, "roster.csv"),
  taf_path = file.path(td, "taf.csv"),
  birth_cert_path = file.path(td, "bc.csv"),
  ascertainment_path = file.path(td, "asc.csv"),
  county_base_path = file.path(td, "county.csv"),
  activity_year = YEAR, save_dir = file.path(td, "out"),
  reference_births = 100)

pa <- res$provider_activity
g <- function(n) pa[pa$npi_activity == n, ]

cat("\n=== cohort membership ===\n")
ok("INACTIVE certificant excluded", !("5555555555" %in% pa$npi_activity))
ok("six ACTIVE midwives retained", nrow(pa) == 6L)

cat("\n=== ABSENCE IS NOT ZERO (the core property) ===\n")
ok("WY midwife with no records has missing activity status",
   is.na(g("3333333333")$birth_activity_state))
ok("...her observed_births is NA, not 0",
   is.na(g("3333333333")$observed_births))
ok("...her birth_active is NA, not FALSE",
   is.na(g("3333333333")$birth_active))
ok("...her birth_fte_weight is NA, not 0",
   is.na(g("3333333333")$birth_fte_weight))

cat("\n=== a zero is emitted ONLY where ascertainment is adequate ===\n")
ok("CO midwife with no records is no_observed_births",
   g("2222222222")$birth_activity_state == "no_observed_births")
ok("...observed_births is 0", g("2222222222")$observed_births == 0)
ok("...birth_active is FALSE", identical(g("2222222222")$birth_active, FALSE))
ok("...birth_fte_weight is 0", g("2222222222")$birth_fte_weight == 0)

cat("\n=== overlapping sources are not double counted ===\n")
# m1: TAF 20, birth certificate 25. Summing would give 45.
ok("observed_births is the max across sources, not the sum",
   g("1111111111")$observed_births == 25)
ok("both sources recorded", g("1111111111")$n_activity_sources == 2L)

cat("\n=== FTE weighting ===\n")
ok("120 births caps at 1.0 FTE", g("4444444444")$birth_fte_weight == 1)
ok("25 births at reference 100 gives 0.25",
   abs(g("1111111111")$birth_fte_weight - 0.25) < 1e-9)

cat("\n=== location shares ===\n")
lw <- res$provider_location_activity
m4 <- lw[lw$npi_activity == "4444444444", ]
ok("m4 split across two counties", nrow(m4) == 2L)
ok("location shares sum to 1", abs(sum(m4$birth_location_share) - 1) < 1e-9)
ok("shares are 90/30 -> 0.75/0.25",
   isTRUE(all.equal(sort(round(m4$birth_location_share, 4)), c(0.25, 0.75))))

cat("\n=== county effective supply ===\n")
cs <- res$county_effective_supply
ok("every county in the base is retained", nrow(cs) == 4L)
ok("county with no observed attendant reports 0 FTE",
   cs$effective_birth_fte[cs$GEOID == "56021"] == 0)
ok("08031 accumulates FTE from m1 and m4",
   cs$effective_birth_fte[cs$GEOID == "08031"] > 0)

cat("\n=== rural validation uses only ascertainable midwives ===\n")
v <- res$validation_statistics
ok("validation produced a row", nrow(v) == 1L)
ok("the unobserved WY midwife is excluded from the denominator",
   v$n_ascertainable == 5L)
ok("both rural and urban cells are populated",
   v$rural_n == 2L && v$urban_n == 3L)
# EXACT percentages, not just finiteness. The first version of this test
# checked is.finite() only, and so passed while the function reported 100%
# for 1-of-2 -- a shadowed column inside summarise().
# rural: m6 attends, m7 zero  -> 1/2 = 50%
# urban: m1 attends, m2 zero, m4 attends -> 1/3 = 33.3%
ok("rural zero-birth percentage is exactly 1 of 2 = 50%",
   abs(v$rural_zero_pct - 50) < 1e-9)
ok("urban zero-birth percentage is exactly 1 of 3 = 33.3%",
   abs(v$urban_zero_pct - 100/3) < 1e-9)
ok("counts and percentages agree",
   abs(v$rural_zero_pct - 100 * v$rural_zero_n / v$rural_n) < 1e-9 &&
   abs(v$urban_zero_pct - 100 * v$urban_zero_n / v$urban_n) < 1e-9)
ok("the difference is the rural minus urban percentage",
   abs(v$percentage_point_difference -
       (v$rural_zero_pct - v$urban_zero_pct)) < 1e-9)

cat("\n=== a missing ascertainment flag must not license a zero ===\n")
write_csv(tibble(state = "CO", year = YEAR, source = "taf",
                 adequate_ascertainment = NA, npi_completeness = 0.9),
          file.path(td, "asc_na.csv"))
res2 <- build_midwife_birth_activity(
  roster_path = file.path(td, "roster.csv"),
  taf_path = file.path(td, "taf.csv"),
  ascertainment_path = file.path(td, "asc_na.csv"),
  county_base_path = file.path(td, "county.csv"),
  activity_year = YEAR, save_dir = file.path(td, "out2"),
  reference_births = 100)
pa2 <- res2$provider_activity
ok("NA ascertainment leaves the CO no-record midwife with missing activity status",
   is.na(pa2$birth_activity_state[pa2$npi_activity == "2222222222"]))

cat("\n=== contract failures are loud ===\n")
dup <- bind_rows(roster, roster[1, ])
write_csv(dup, file.path(td, "roster_dup.csv"))
e <- tryCatch({ build_midwife_birth_activity(
  roster_path = file.path(td, "roster_dup.csv"),
  taf_path = file.path(td, "taf.csv"),
  ascertainment_path = file.path(td, "asc.csv"),
  county_base_path = file.path(td, "county.csv"),
  activity_year = YEAR, save_dir = file.path(td, "out3")); NA_character_ },
  error = function(e) conditionMessage(e))
ok("duplicate NPIs in the roster raise an error",
   !is.na(e) && grepl("duplicated NPIs", e))

e2 <- tryCatch({ build_midwife_birth_activity(
  roster_path = file.path(td, "roster.csv"),
  ascertainment_path = file.path(td, "asc.csv"),
  county_base_path = file.path(td, "county.csv"),
  activity_year = YEAR, save_dir = file.path(td, "out4")); NA_character_ },
  error = function(e) conditionMessage(e))
ok("supplying no activity source raises an error",
   !is.na(e2) && grepl("at least one activity source", e2))

cat("\n=== optional columns are genuinely optional ===\n")
write_csv(tibble(npi = "1111111111", year = YEAR, state = "CO",
                 county_fips = "08031"), file.path(td, "taf_nocount.csv"))
r3 <- read_delivery_activity(file.path(td, "taf_nocount.csv"), "taf", YEAR)
ok("a source without birth_count defaults to one birth per row",
   nrow(r3) == 1L && r3$birth_count == 1)

write_csv(tibble(state = "CO", year = YEAR, source = "taf",
                 adequate_ascertainment = TRUE),
          file.path(td, "asc_nocomp.csv"))
e3 <- tryCatch({ build_midwife_birth_activity(
  roster_path = file.path(td, "roster.csv"),
  taf_path = file.path(td, "taf.csv"),
  ascertainment_path = file.path(td, "asc_nocomp.csv"),
  county_base_path = file.path(td, "county.csv"),
  activity_year = YEAR, save_dir = file.path(td, "out5")); NA_character_ },
  error = function(e) conditionMessage(e))
ok("ascertainment without npi_completeness still runs", is.na(e3))

cat("\n")
if (length(FAILS)) {
  cat(sprintf("FAILED: %d\n", length(FAILS)))
  for (f in FAILS) cat("  - ", f, "\n")
  quit(status = 1)
}
cat("All birth-activity tests passed.\n")
