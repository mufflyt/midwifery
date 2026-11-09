#!/usr/bin/env Rscript
# =============================================================================
# R/lib/truth_fusion_claims.R -- tests
# =============================================================================
# Run: Rscript tests/test_truth_fusion_claims.R  (exit 1 on fail)
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({ library(dplyr) })
source(file.path(root, "R", "lib", "truth_fusion_claims.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("-- merge_dac_pecos_sources() --\n")
dac <- data.frame(npi = c("1", "2", "3"), year = c(2024L, 2024L, 2024L), state = c("CO", "TX", "FL"))
pecos <- data.frame(npi = c("1", "2", "4"), year = c(2024L, 2024L, 2024L), state = c("CO", "NM", "WA"))
merged <- merge_dac_pecos_sources(dac, pecos)
chk(nrow(merged) == 3, "3 of 4 NPIs produce a combined claim (npi 2 conflicts, dropped)")
chk(merged$state[merged$npi == "1"] == "CO", "agreement -> combined state")
chk(!("2" %in% merged$npi), "disagreement -> NO combined claim, not an arbitrary pick")
chk(merged$state[merged$npi == "3"] == "FL", "DAC-only npi -> DAC's value carries through")
chk(merged$state[merged$npi == "4"] == "WA", "PECOS-only npi -> PECOS's value carries through")

cat("\n-- build_truth_fusion_claims() --\n")
nppes <- data.frame(npi = c("1", "1"), year = c(2023L, 2024L), state = c("CO", "TX"))
op <- data.frame(npi = c("1"), year = c(2024L), state = c("TX"))
claims <- build_truth_fusion_claims(list(nppes = nppes, open_payments = op))
chk(nrow(claims) == 3, "one row per source row, no collapsing")
chk(setequal(names(claims), c("entity_id", "attribute", "source_id", "claimed_value", "reference_year")),
    "returns exactly mysteryroster's expected claims columns")
chk(all(claims$attribute == "practice_state"), "attribute is always practice_state")
chk(sum(claims$source_id == "open_payments") == 1, "source_id correctly tags each source's rows")

filtered <- build_truth_fusion_claims(list(nppes = nppes), npi_filter = "9")
chk(nrow(filtered) == 0, "npi_filter excludes NPIs not in the filter set")

cat("\n-- expand_intervals_to_year_claims() --\n")
intervals <- data.frame(
  npi = c("1", "2", "2"),
  state = c("CO", "TX", "NM"),
  interval_start = as.Date(c("2018-01-01", "2020-03-01", "2020-08-01")),
  interval_end = as.Date(c("2021-06-30", "2020-07-31", "2021-12-31"))
)
yc <- expand_intervals_to_year_claims(intervals, 2018:2022)
chk(all(c(2018L, 2019L, 2020L, 2021L) %in% yc$year[yc$npi == "1"]) && !(2022L %in% yc$year[yc$npi == "1"]),
    "a single interval expands to every year it overlaps, and no further")
npi2_2020 <- yc[yc$npi == "2" & yc$year == 2020L, ]
chk(nrow(npi2_2020) == 2 && setequal(npi2_2020$state, c("TX", "NM")),
    "a real mid-year state switch -> TWO claim rows for that npi-year, not collapsed")
chk(nrow(expand_intervals_to_year_claims(intervals[0, ], 2018:2022)) == 0, "empty intervals -> empty claims, no error")

cat(sprintf("\n%s\n", if (fails == 0L) "ALL PASS" else sprintf("%d FAILED", fails)))
if (fails > 0L) quit(status = 1L, save = "no")
