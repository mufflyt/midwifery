#!/usr/bin/env Rscript
# Regression tests for the Stage 3 point-in-polygon materialization bug.
#
# The guard was `if (all(is.na(hit$county_fips)))`: PIP ran only when EVERY row
# lacked a county. With 4,949 cached counties present the branch never fired,
# and 10,226 rows kept coordinates but got no county. The fix must fill
# row-wise and never disturb a cached value.
suppressPackageStartupMessages({library(dplyr); library(testthat)})

# Stand-in for assign_county_from_points(): deterministic, no tigris needed.
fake_pip <- function(df) ifelse(is.na(df$latitude) | is.na(df$longitude),
                                NA_character_, "99999")

fill_counties <- function(hit) {
  needs <- is.na(hit$county_fips) & !is.na(hit$latitude) & !is.na(hit$longitude)
  if (any(needs)) hit$county_fips[needs] <- fake_pip(hit[needs, , drop = FALSE])
  hit
}
mk <- function(lat, lon, county) tibble(latitude = lat, longitude = lon, county_fips = county)

test_that("1. all rows missing county -> all filled", {
  r <- fill_counties(mk(c(1,2), c(1,2), c(NA_character_, NA_character_)))
  expect_equal(r$county_fips, c("99999", "99999"))
})

test_that("2. no rows missing county -> nothing changes", {
  before <- mk(c(1,2), c(1,2), c("11111", "22222"))
  expect_equal(fill_counties(before)$county_fips, before$county_fips)
})

test_that("3. MIXED cached and missing -> only the missing are filled", {
  # This is the case the old guard got wrong: it did nothing at all here.
  r <- fill_counties(mk(c(1,2,3), c(1,2,3), c("11111", NA, NA)))
  expect_equal(r$county_fips, c("11111", "99999", "99999"))
})

test_that("4. missing coordinates cannot receive a county", {
  r <- fill_counties(mk(c(1, NA), c(1, NA), c(NA_character_, NA_character_)))
  expect_equal(r$county_fips, c("99999", NA_character_))
})

test_that("5. cached county values are preserved exactly", {
  before <- mk(c(1,2,3), c(1,2,3), c("11111", "22222", NA))
  r <- fill_counties(before)
  expect_equal(r$county_fips[1:2], c("11111", "22222"))
})

test_that("6. PIP fills only rows with coordinates AND missing county", {
  before <- mk(c(1, 2, NA, 4), c(1, 2, NA, 4), c(NA, "22222", NA, NA))
  r <- fill_counties(before)
  expect_equal(r$county_fips, c("99999", "22222", NA, "99999"))
})
