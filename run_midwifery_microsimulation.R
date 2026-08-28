#!/usr/bin/env Rscript
# =============================================================================
# National Certified Nurse-Midwife (CNM) Workforce Microsimulation Engine (R)
# =============================================================================
# R port of run_midwifery_microsimulation.py, kept logic-identical to it
# after that file's Cycle 24 fix (docs/ADVERSARIAL_LOOP_LEDGER.md). Projects
# 15-year aggregate workforce state transitions -- inflow, retirement
# attrition, and rural/urban composition -- across a national CNM cohort
# (2026-2040). This is a deterministic cohort-component projection, not a
# stochastic microsimulation of individuals: no random draw occurs anywhere
# in it.
#
# Both implementations must satisfy the same contract: Rural_Practicing_CNMs
# + Urban_Practicing_CNMs == Total_Active_CNM_Workforce for every simulated
# year. See tests/test_run_midwifery_microsimulation.R.
# =============================================================================

suppressPackageStartupMessages({library(readr)})

SIMULATION_YEARS    <- 2026:2040
ANNUAL_NEW_GRADUATES <- 680L   # Annual AMCB new certificant inflow
ANNUAL_RETIRE_RATE   <- 0.032  # 3.2% annual attrition/retirement
ANNUAL_RURAL_DRIFT   <- 0.041  # 4.1% annual cross-county mobility
RURAL_BASELINE_PCT   <- 0.143  # 14.3% rural baseline
RURAL_GRAD_SHARE     <- 0.08   # 8% of new grads enter rural practice
BIRTHS_PER_CNM       <- 42.5   # average births attended per active CNM per year

#' Project aggregate CNM workforce state year over year
#'
#' Returns a data.frame, one row per simulated year. Population is conserved
#' by construction: `Rural_Practicing_CNMs + Urban_Practicing_CNMs ==
#' Total_Active_CNM_Workforce` for every returned row.
#'
#' Retirement outflow is removed from the rural and urban sub-populations in
#' proportion to their CURRENT composition (immediately after that year's
#' rural-to-urban drift) -- not by `rural_grad_share`, which describes where
#' INCOMING graduates start practicing, a different population from the
#' existing workforce that is retiring. New-graduate inflow is split by
#' `rural_grad_share` as before. In both cases one share is computed and the
#' other is derived by subtraction, so the two allocations always sum to
#' exactly the total being allocated regardless of independent truncation --
#' computing `as.integer(x * 0.08)` and `as.integer(x * 0.92)` separately
#' does not generally sum to `x`.
project_workforce <- function(initial_workforce,
                               years = SIMULATION_YEARS,
                               annual_new_graduates = ANNUAL_NEW_GRADUATES,
                               annual_retire_rate = ANNUAL_RETIRE_RATE,
                               annual_rural_drift = ANNUAL_RURAL_DRIFT,
                               rural_baseline_pct = RURAL_BASELINE_PCT,
                               rural_grad_share = RURAL_GRAD_SHARE,
                               births_per_cnm = BIRTHS_PER_CNM) {
  if (initial_workforce < 0) {
    stop(sprintf("initial_workforce must be non-negative, got %s", initial_workforce),
         call. = FALSE)
  }

  current_active <- initial_workforce
  current_rural  <- as.integer(initial_workforce * rural_baseline_pct)
  current_urban  <- current_active - current_rural

  rows <- vector("list", length(years))
  for (i in seq_along(years)) {
    year    <- years[i]
    inflow  <- annual_new_graduates
    outflow <- as.integer(current_active * annual_retire_rate)

    # Rural-to-urban drift among the existing population. Zero-sum between
    # the two buckets; does not touch current_active.
    movers <- as.integer(current_rural * annual_rural_drift)
    current_rural <- current_rural - movers
    current_urban <- current_urban + movers

    # Retirement outflow, allocated by the CURRENT rural/urban split
    # (post-drift), one share computed and the other derived so they always
    # sum to exactly `outflow`.
    total_geo <- current_rural + current_urban
    rural_share_now <- if (total_geo > 0) current_rural / total_geo else 0
    rural_outflow <- as.integer(round(outflow * rural_share_now))
    urban_outflow <- outflow - rural_outflow
    current_rural <- current_rural - rural_outflow
    current_urban <- current_urban - urban_outflow

    # New-graduate inflow, split by rural_grad_share; same derive-by-
    # subtraction fix.
    rural_inflow <- as.integer(inflow * rural_grad_share)
    urban_inflow <- inflow - rural_inflow
    current_rural <- current_rural + rural_inflow
    current_urban <- current_urban + urban_inflow

    current_active <- current_active + inflow - outflow

    rural_share_pct <- if (current_active > 0) {
      round((current_rural / current_active) * 100, 1)
    } else {
      0
    }

    rows[[i]] <- data.frame(
      Simulation_Year            = year,
      Total_Active_CNM_Workforce = current_active,
      New_Graduate_Inflow        = inflow,
      Retirement_Outflow         = outflow,
      Urban_Practicing_CNMs      = current_urban,
      Rural_Practicing_CNMs      = current_rural,
      # Numeric, not a formatted "13.8%" string -- see the Python version's
      # SEM2 fix (Cycle 24): a CSV column is a data contract.
      Rural_Workforce_Share_Pct  = rural_share_pct,
      Projected_Births_Attended  = as.integer(current_active * births_per_cnm)
    )
  }
  do.call(rbind, rows)
}

.load_initial_workforce <- function(v4_file) {
  nrow(readr::read_csv(v4_file, show_col_types = FALSE, progress = FALSE))
}

main <- function() {
  cat("=== Running National Midwifery Workforce Microsimulation (2026-2040) ===\n")

  v4_file <- "artifacts/cohort_midwives_tier1_tier2_bon_validated.csv"
  initial_workforce <- .load_initial_workforce(v4_file)

  projection_results <- project_workforce(initial_workforce)
  current_active <- projection_results$Total_Active_CNM_Workforce[nrow(projection_results)]

  out_csv <- "artifacts/midwifery_microsimulation_projections_2026_2040.csv"
  readr::write_csv(projection_results, out_csv)

  cat("\n=========================================================================\n")
  cat("  MIDWIFERY WORKFORCE MICROSIMULATION COMPLETE (2026-2040)\n")
  cat(sprintf("  2026 Baseline Active CNMs  : %s\n", format(initial_workforce, big.mark = ",")))
  cat(sprintf("  2040 Projected Active CNMs : %s (+%.1f%%)\n",
              format(current_active, big.mark = ","),
              ((current_active - initial_workforce) / initial_workforce) * 100))
  cat(sprintf("  2040 Projected Annual Births: %s Births Attended/Year\n",
              format(as.integer(current_active * BIRTHS_PER_CNM), big.mark = ",")))
  cat(sprintf("  Written to: %s\n", out_csv))
  cat("=========================================================================\n")
}

# Guard against side effects on source(): running this file for its functions
# (as a test does) must not also read the (possibly absent, gitignored)
# master file and write an output artifact -- the same reason the Python
# version gained an `if __name__ == "__main__":` guard in Cycle 24. Matches
# the convention already used at R/01-build-county-base.R:481.
if (identical(environment(), globalenv()) && !interactive()) {
  main()
}
