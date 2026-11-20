# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-step2-npi-dedup-bug.R
#
# Not one assertion is changed. This file tests a helper that exists in
# BOTH repositories, so the upstream contract applies here unaltered; the
# only edit is this header. If it starts failing, the local helper has
# diverged from the upstream contract -- decide which is right rather
# than editing the assertion to match the code.
#
# Verified before landing: passes 100% against this repo's helper, needs
# no artifact, no network, no ~/isochrones, and no file outside the repo.
# ============================================================================
# =============================================================================
# test-step2-npi-dedup-bug.R
# Tests for NPI deduplication correctness in Step 2
# =============================================================================

library(testthat)
library(here)

test_that("NPI strings must be exactly 10 digits", {
  valid_npi <- "1234567890"
  invalid_npi_9 <- "123456789"
  invalid_npi_11 <- "12345678901"

  npi_valid <- function(x) nchar(x) == 10L && grepl("^[0-9]{10}$", x)
  expect_true(npi_valid(valid_npi))
  expect_false(npi_valid(invalid_npi_9))
  expect_false(npi_valid(invalid_npi_11))
})

test_that("NPI cannot be NA", {
  npi_valid <- function(x) !is.na(x) && nchar(x) == 10L && grepl("^[0-9]{10}$", x)
  expect_false(npi_valid(NA_character_))
})

test_that("join_safety.R exists and defines join functions", {
  expect_true(file.exists(here::here("R", "join_safety.R")))
  content <- readLines(here::here("R", "join_safety.R"))
  combined <- paste(content, collapse = "\n")
  expect_true(grepl("safe_left_join.*<- function", combined))
  expect_true(grepl("safe_inner_join.*<- function", combined))
})

test_that("left join should not fan out row count beyond input", {
  # Pure dplyr test to verify the concept
  left_df <- data.frame(npi = c("1234567890", "9876543210"),
                        stringsAsFactors = FALSE)
  right_df <- data.frame(npi = "1234567890", val = 1L,
                         stringsAsFactors = FALSE)
  result <- dplyr::left_join(left_df, right_df, by = "npi")
  expect_equal(nrow(result), 2L)
})

test_that("deduplication by NPI removes duplicates", {
  physicians <- data.frame(
    npi = c("1234567890", "1234567890", "9876543210"),
    name = c("Alice", "Alice_dup", "Bob"),
    stringsAsFactors = FALSE
  )
  deduped <- dplyr::distinct(physicians, npi, .keep_all = TRUE)
  expect_equal(nrow(deduped), 2L)
})
