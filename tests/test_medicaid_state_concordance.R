#!/usr/bin/env Rscript
# =============================================================================
# R/lib/medicaid_state_concordance.R: both six-category classifiers must
# land on exactly the category the spec defines for each named scenario,
# and must never silently mis-resolve the ambiguous or missing-evidence
# cases into a confident-looking answer.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path(root, "R", "lib", "medicaid_enrollment_intervals.R"))
source(file.path(root, "R", "lib", "medicaid_state_concordance.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- STATE CONCORDANCE: each of the six categories, one at a time --\n")
cls <- classify_state_concordance(
  nppes_state = c("CO", "CO", "CO", "CO", "CO", NA),
  medicaid_states = list("CO", "WY", c("CO", "WY"), c("WY", "UT"), character(0), "CO"))
chk(identical(cls[1], "Concordant"), "T1 single matching state -> Concordant")
chk(identical(cls[2], "Discordant"), "T2 single non-matching state -> Discordant")
chk(identical(cls[3], "Multistate concordant"),
    "T3 NPPES state matches one of several enrollment states -> Multistate concordant")
chk(identical(cls[4], "Multistate discordant"),
    "T4 multiple enrollment states, none matching -> Multistate discordant")
chk(identical(cls[5], "Not observed"), "T5 provider with no Medicaid record -> Not observed")
chk(identical(cls[6], "Indeterminate"), "T6 no resolvable NPPES state -> Indeterminate, not silently compared")

cat("\n-- STATE CONCORDANCE: indeterminate_reason always wins --\n")
cls2 <- classify_state_concordance(nppes_state = "CO", medicaid_states = list("CO"),
                                   indeterminate_reason = "duplicate_npi_year")
chk(identical(cls2, "Indeterminate"),
    "T7 an explicit indeterminate_reason overrides what would otherwise be Concordant")

cat("\n-- STRUCTURAL INVARIANT: multistate implies >=2 states behind it --\n")
multistate_rows <- which(cls %in% c("Multistate concordant", "Multistate discordant"))
medicaid_states_list <- list("CO", "WY", c("CO", "WY"), c("WY", "UT"), character(0), "CO")
chk(all(vapply(medicaid_states_list[multistate_rows], length, integer(1)) >= 2L),
    "T8 every Multistate classification is backed by >=2 distinct enrollment states (state-pair expansion will produce more pairs than persons for these rows, never fewer)")

cat("\n-- STATE CONCORDANCE: one classification per input row --\n")
n_in <- 6L
chk(length(cls) == n_in, "T9 output length equals input length (no row silently dropped)")

cat("\n-- TRANSITION SUPPORT: each of the six categories --\n")
tr <- classify_transition_support(
  destination_preexisting      = c(FALSE, FALSE, TRUE,  FALSE, FALSE, FALSE),
  destination_starts_in_window = c(TRUE,  TRUE,  FALSE, FALSE, FALSE, TRUE),
  origin_ends_in_window        = c(TRUE,  FALSE, FALSE, FALSE, FALSE, FALSE),
  origin_persists_in_window    = c(FALSE, FALSE, FALSE, TRUE,  FALSE, FALSE),
  destination_any_in_window    = c(TRUE,  TRUE,  TRUE,  FALSE, FALSE, TRUE),
  origin_any_in_window         = c(TRUE,  TRUE,  TRUE,  TRUE,  FALSE, TRUE),
  indeterminate_reason         = c(NA, NA, NA, NA, NA, "overlapping_segments"))
chk(identical(tr[1], "Strong administrative support"),
    "T10 new destination enrollment + origin termination, same window -> Strong")
chk(identical(tr[2], "Partial administrative support"),
    "T11 new destination enrollment WITHOUT an observed origin termination -> Partial")
chk(identical(tr[3], "Preexisting destination enrollment"),
    "T12 a mover whose destination-state enrollment PREDATES the move -> Preexisting, even though destination_starts_in_window is FALSE here")
chk(identical(tr[4], "Contradictory enrollment evidence"),
    "T13 a mover with persistent origin-state enrollment and no destination evidence -> Contradictory")
chk(identical(tr[5], "No informative enrollment evidence"),
    "T14 no usable enrollment evidence for either state -> No informative enrollment evidence")
chk(identical(tr[6], "Indeterminate"),
    "T15 overlapping/ambiguous segments force Indeterminate even when the booleans look like Strong support")

cat("\n-- TRANSITION SUPPORT: preexisting wins over a simultaneous new-start signal --\n")
tr2 <- classify_transition_support(
  destination_preexisting = TRUE, destination_starts_in_window = TRUE,
  origin_ends_in_window = TRUE, origin_persists_in_window = FALSE,
  destination_any_in_window = TRUE, origin_any_in_window = TRUE)
chk(identical(tr2, "Preexisting destination enrollment"),
    "T16 preexisting destination enrollment is never recoded as Strong support just because a second, new segment also started in-window")

cat("\n-- TRANSITION SUPPORT: NA booleans are absent evidence, not contrary evidence --\n")
tr3 <- classify_transition_support(
  destination_preexisting = NA, destination_starts_in_window = TRUE,
  origin_ends_in_window = NA, origin_persists_in_window = NA,
  destination_any_in_window = TRUE, origin_any_in_window = NA)
chk(identical(tr3, "Partial administrative support"),
    "T17 NA upstream booleans resolve as FALSE (absent evidence), landing on Partial rather than erroring or defaulting to Strong")

cat("\n-- window-evidence summariser: predates vs. starts-within, exactly one true --\n")
ivals <- tribble(
  ~npi, ~state, ~interval_start, ~interval_end,
  "M", "WY", as.Date("2019-01-01"), as.Date("2026-01-01"))  # predates any 2023-2024 window
ev <- summarize_state_window_evidence(ivals, "WY", as.Date("2023-01-01"), as.Date("2024-12-31"))
chk(isTRUE(ev$preexisting) && !isTRUE(ev$starts_in_window),
    "T18 an interval starting well before the window is 'preexisting', not 'starts_in_window'")
ivals2 <- tribble(
  ~npi, ~state, ~interval_start, ~interval_end,
  "N", "WY", as.Date("2023-06-01"), as.Date("2024-12-31"))
ev2 <- summarize_state_window_evidence(ivals2, "WY", as.Date("2023-01-01"), as.Date("2024-12-31"))
chk(isTRUE(ev2$starts_in_window) && !isTRUE(ev2$preexisting) && isTRUE(ev2$persists_at_window_end),
    "T19 an interval starting inside the window is 'starts_in_window', open at window end")
ivals3 <- tribble(
  ~npi, ~state, ~interval_start, ~interval_end,
  "P", "WY", as.Date("2010-01-01"), as.Date("2015-12-31"))  # no overlap with the window at all
ev3 <- summarize_state_window_evidence(ivals3, "WY", as.Date("2023-01-01"), as.Date("2024-12-31"))
chk(!isTRUE(ev3$any_in_window),
    "T20 an interval entirely before the window contributes no evidence to it at all")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
