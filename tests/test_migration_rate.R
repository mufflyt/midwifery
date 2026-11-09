#!/usr/bin/env Rscript
# =============================================================================
# R/lib/migration_rate.R -- tests
# =============================================================================
# Run: Rscript tests/test_migration_rate.R  (exit 1 on fail)
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({ library(dplyr); library(tibble) })
source(file.path(root, "R", "lib", "migration_rate.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("-- wilson_ci() --\n")
ci <- wilson_ci(x = 50, n = 100)
chk(ci$ci_low < 50 && ci$ci_high > 50, "50% proportion CI brackets the point estimate")
ci_narrow <- wilson_ci(x = 500, n = 1000)
chk((ci_narrow$ci_high - ci_narrow$ci_low) < (ci$ci_high - ci$ci_low), "larger n -> narrower CI, same proportion")

cat("\n-- compute_migration_rates() --\n")
# npi 1: CO,CO,TX across 2020:2022 -- moves once. npi 2: no 2021 row -- only
# the 2021->2022 transition should exclude it, not 2020->2021.
states <- tribble(
  ~npi, ~year, ~state,
  "1", 2020L, "CO",
  "1", 2021L, "CO",
  "1", 2022L, "TX",
  "2", 2020L, "NY",
  "2", 2022L, "NY"
)
rates <- compute_migration_rates(states, 2020:2022)
chk(nrow(rates) == 2, "2 transitions from 3 years")
r1 <- rates[rates$year_from == 2020, ]
chk(r1$n_pairs == 1 && r1$n_moved == 0, "2020->2021: npi 2 has no 2021 row, excluded -- only npi 1 counted, no move")
r2 <- rates[rates$year_from == 2021, ]
chk(r2$n_pairs == 1 && r2$n_moved == 1 && r2$pct_moved == 100,
    "2021->2022: only npi 1 has both years (npi 2 missing 2021) -- 1 pair, 1 move")

states_with_gap <- tribble(~npi, ~year, ~state, "1", 2020L, "CO")  # no 2021 row at all
empty_transition <- compute_migration_rates(states_with_gap, 2020:2021)
chk(nrow(empty_transition) == 0, "a transition with zero valid pairs is dropped, not reported as NA/0")

cat("\n-- compute_consecutive_rates() --\n")
# npi 1: CO at "2017-04", CO at "2017-12", TX at "2018-12" -- moves once,
# between the SECOND and THIRD vintage (not calendar-year spaced).
sub <- tribble(
  ~npi, ~vintage, ~state,
  "1", "2017-04", "CO",
  "1", "2017-12", "CO",
  "1", "2018-12", "TX",
  "2", "2017-04", "NY",
  "2", "2018-12", "NY"  # no "2017-12" row -- excluded from that specific pair only
)
sub_rates <- compute_consecutive_rates(sub, c("2017-04", "2017-12", "2018-12"))
chk(nrow(sub_rates) == 2, "2 transitions from 3 ordered labels")
s1 <- sub_rates[sub_rates$period_from == "2017-04", ]
chk(s1$n_pairs == 1 && s1$n_moved == 0, "2017-04->2017-12: npi 2 has no 2017-12 row, excluded -- only npi 1 counted, no move")
s2 <- sub_rates[sub_rates$period_from == "2017-12", ]
chk(s2$n_pairs == 1 && s2$n_moved == 1, "2017-12->2018-12: npi 2 missing the 2017-12 row, excluded -- only npi 1 counted")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
