# =============================================================================
# helper-data-generation.R -- synthetic fixtures, ported from ~/isochrones
# =============================================================================
# PORTED from ~/isochrones/tests/testthat/helper-data-generation.R.
#
# WHY IT EARNS ITS PLACE HERE, when the other ports only added assertions: the
# artifacts carrying NPIs, names and certification dates are gitignored, so the
# tests that check them SKIP on a runner. Synthetic fixtures let those code
# paths execute in CI against data that resembles the real thing and describes
# nobody.
#
# DIVERGENCE, and a bug to send back upstream:
#
#   gen_npi() built an NPI as a random first digit plus NINE more random
#   digits, and called `valid_rate` of them valid. They are shape-valid only.
#   Of 200 generated with valid_rate = 0.9, exactly 15 carried a correct Luhn
#   check digit -- about one in ten, which is chance. Any fixture built from
#   them is rejected by contract_npi_valid(), and upstream any matcher test
#   asserting "these NPIs are valid" was asserting the wrong thing.
#
#   gen_npi() now computes the check digit instead of rolling a tenth die, via
#   npi_check_digit() below. `valid_rate` finally means what it says, and the
#   INVALID slots gained a seventh type: a well-shaped NPI with a deliberately
#   wrong check digit, which is the failure mode that motivated the fix and the
#   one the old generator could not produce on purpose.
#
# The isochrones-specific generators (specialties, retirement, isochrones) are
# kept verbatim rather than deleted, so this file can be diffed against its
# origin and the fix carried back.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(stringr)
})

#' Generate realistic NPI values with controlled validity rate
#'
#' @param n Number of NPIs to generate
#' @param valid_rate Proportion that should be valid (0-1)
#' @param include_scientific Include scientific notation NPIs (Excel export
#'   issue)
#' @param include_short Include short/malformed NPIs
#' @param seed Random seed for reproducibility
#' @return Character vector of NPIs
#' Compute the Luhn check digit for the first nine digits of an NPI
#'
#' The payload is "80840" + those nine digits. Defined here rather than in
#' helper-invariants.R because that file VALIDATES and this one GENERATES, and
#' a generator that imports its own validator cannot catch a shared error.
#'
#' @param first9 [character(1)] nine digits.
#' @return [character(1)] the single check digit.
npi_check_digit <- function(first9) {
  d <- rev(as.integer(strsplit(paste0("80840", first9), "")[[1]]))
  i <- seq_along(d)
  dbl <- d
  dbl[i %% 2 == 1] <- d[i %% 2 == 1] * 2
  dbl <- ifelse(dbl > 9, dbl - 9, dbl)
  as.character((10 - (sum(dbl) %% 10)) %% 10)
}

#' A ten-digit NPI whose check digit is deliberately wrong
#'
#' @return [character(1)]
npi_wrong_check_digit <- function() {
  first9 <- paste0(c(sample(1:2, 1), sample(0:9, 8, replace = TRUE)), collapse = "")
  right <- as.integer(npi_check_digit(first9))
  paste0(first9, (right + sample(1:9, 1)) %% 10)
}

gen_npi <- function(n, valid_rate = 0.9, include_scientific = FALSE,
                   include_short = FALSE, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  npis <- character(n)

  # Generate genuinely valid NPIs: nine digits of payload plus the Luhn check
  # digit computed over "80840" + those nine. The original drew the tenth digit
  # at random, so ~90% of its "valid" NPIs were not.
  n_valid <- floor(n * valid_rate)
  if (n_valid > 0) {
    first9 <- replicate(n_valid, paste0(c(sample(1:2, 1), sample(0:9, 8, replace = TRUE)),
                                        collapse = ""))
    npis[1:n_valid] <- paste0(first9, vapply(first9, npi_check_digit, character(1),
                                             USE.NAMES = FALSE))
  }

  # Generate invalid NPIs for remaining slots
  if (n > n_valid) {
    remaining <- n - n_valid
    invalid_types <- if (include_scientific && include_short) {
      sample(1:6, remaining, replace = TRUE)
    } else if (include_scientific) {
      sample(c(1, 2, 5, 6), remaining, replace = TRUE)
    } else if (include_short) {
      sample(c(1, 3, 4, 5, 6), remaining, replace = TRUE)
    } else {
      sample(c(1, 5, 6, 7), remaining, replace = TRUE)
    }

    for (i in (n_valid + 1):n) {
      type <- invalid_types[i - n_valid]
      npis[i] <- switch(type,
        "1" = "12345678901",     # Too long (11 digits)
        "2" = "1.23e+09",        # Scientific notation
        "3" = "123",             # Too short
        "4" = "123456789",       # 9 digits (missing leading zero)
        "5" = "abc123def0",      # Contains letters
        "6" = "",                # Empty string
        # ADDED: right shape, wrong check digit. The old generator could not
        # produce this deliberately, which is exactly the case a validator that
        # checks only width and digits waves through.
        "7" = npi_wrong_check_digit()
      )
    }
  }

  # Shuffle to randomize order
  sample(npis)
}











# (informational cat() calls removed — they polluted test output on every source)
# =============================================================================
# midwifery-specific fixtures (added here, not present upstream)
# =============================================================================

#' Build a synthetic AMCB-to-NPI linkage
#'
#' Shaped like artifacts/amcb_npi_linkage_FROZEN_*.csv -- certification number,
#' name, MM/YYYY dates, and an NPI for the linked share -- so the contracts that
#' skip in CI for want of the real (gitignored) artifact can run against
#' something that describes nobody.
#'
#' @param n [integer(1)] rows.
#' @param linked_rate [numeric(1)] share carrying an NPI; the rest are
#'   unmatched, which is the real artifact's shape (65.7% primary linkage).
#' @param seed [integer(1)|NULL]
#' @param corrupt [character(1)] plant a defect: "none", "duplicate_npi",
#'   "invalid_npi", "reversed_dates", "blank_zip".
#' @return [data.frame]
create_test_amcb_linkage <- function(n = 200, linked_rate = 0.657, seed = NULL,
                                     corrupt = c("none", "duplicate_npi", "invalid_npi",
                                                 "reversed_dates", "blank_zip")) {
  corrupt <- match.arg(corrupt)
  if (!is.null(seed)) set.seed(seed)

  n_linked <- floor(n * linked_rate)
  npi <- c(gen_npi(n_linked, valid_rate = 1), rep(NA_character_, n - n_linked))

  cert_year <- sample(1980:2024, n, replace = TRUE)
  cert_month <- sprintf("%02d", sample(1:12, n, replace = TRUE))
  exp_year <- cert_year + sample(5:40, n, replace = TRUE)

  d <- data.frame(
    certification_number = sprintf("%06d", seq_len(n)),
    last_name  = paste0("SURNAME", seq_len(n)),
    first_name = paste0("GIVEN", seq_len(n)),
    npi = npi,
    certification_date = paste0(cert_month, "/", cert_year),
    expiration_date    = paste0("12/", exp_year),
    practice_zip = sprintf("%05d", sample(1000:99999, n, replace = TRUE)),
    stringsAsFactors = FALSE
  )

  # Planted defects, so a test can prove the guard fires rather than only that
  # clean data passes. A guard never seen to fail is not known to work.
  switch(corrupt,
    duplicate_npi  = { d$npi[2] <- d$npi[1] },
    invalid_npi    = { d$npi[1] <- npi_wrong_check_digit() },
    reversed_dates = { d$expiration_date[1] <- "01/1900" },
    blank_zip      = { d$practice_zip[1:3] <- c("", "  ", "NA") },
    none = NULL)
  d
}
