# =============================================================================
# The ported invariants, applied to this repository
# =============================================================================
# tests/helper-invariants.R came from ~/isochrones. This file is what makes it
# earn its place here: the assertions pointed at midwifery's own artifacts and
# identifiers.
#
# TWO CLASSES OF TEST LIVE HERE, and the difference matters for reading a green
# tick:
#
#   HERMETIC   the NPI check-digit tests. Pure arithmetic on constructed input,
#              so they run everywhere including CI, and a failure is always a
#              real regression.
#
#   DATA-BOUND everything reading an artifact. The person-level files that
#              carry NPIs and certification dates are gitignored, so on a
#              runner these SKIP. They run for real only on a machine that has
#              the data. A skip is reported as a skip -- never as a pass.
#
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."

suppressPackageStartupMessages(library(testthat))
source(file.path(root, "tests", "helper-invariants.R"))

# -----------------------------------------------------------------------------
# HERMETIC: the NPI check digit
# -----------------------------------------------------------------------------
# Build a valid check digit independently of the function under test, so the
# test does not merely agree with the implementation's own arithmetic.
.mk_npi <- function(first9) {
  d <- rev(as.integer(strsplit(paste0("80840", first9), "")[[1]]))
  i <- seq_along(d)
  dbl <- d
  dbl[i %% 2 == 1] <- d[i %% 2 == 1] * 2
  dbl <- ifelse(dbl > 9, dbl - 9, dbl)
  paste0(first9, (10 - (sum(dbl) %% 10)) %% 10)
}

test_that("the CMS worked example validates", {
  # 1234567893 is the example in CMS's own NPI check-digit documentation.
  expect_true(npi_luhn_valid("1234567893"))
})

test_that("a well-shaped NPI with a wrong check digit is rejected", {
  # This is the whole point of porting with the Luhn check rather than without:
  # upstream's width-and-digits test accepts this string.
  expect_false(npi_luhn_valid("1234567890"))
})

test_that("every constructed NPI validates and every corruption is caught", {
  set.seed(1)
  pre <- sprintf("%09d", sample(1e8:(2e8 - 1), 200))
  good <- vapply(pre, .mk_npi, character(1), USE.NAMES = FALSE)
  expect_true(all(npi_luhn_valid(good)))

  # A single-digit error anywhere is what Luhn is FOR. Flip the check digit.
  bad <- paste0(substr(good, 1, 9), (as.integer(substr(good, 10, 10)) + 1L) %% 10L)
  expect_true(all(!npi_luhn_valid(bad)))
})

test_that("adjacent transpositions are caught except Luhn's known blind spot", {
  # Luhn detects every adjacent transposition EXCEPT 09 <-> 90. Asserting the
  # real property rather than a rounder one keeps the test honest: if a future
  # change made this 100%, the algorithm would no longer be Luhn.
  set.seed(2)
  pre <- sprintf("%09d", sample(1e8:(2e8 - 1), 200))
  good <- vapply(pre, .mk_npi, character(1), USE.NAMES = FALSE)
  a <- substr(good, 7, 7); b <- substr(good, 8, 8)
  differ <- a != b
  swapped <- paste0(substr(good, 1, 6), b, a, substr(good, 9, 10))[differ]
  blind <- (a == "0" & b == "9") | (a == "9" & b == "0")
  expect_true(sum(!npi_luhn_valid(swapped)) >= sum(differ) - sum(blind[differ]))
})

test_that("shape failures are rejected and missing stays missing", {
  expect_false(npi_luhn_valid("123"))
  expect_false(npi_luhn_valid("12345678a3"))
  expect_true(is.na(npi_luhn_valid(NA_character_)))
  expect_equal(length(npi_luhn_valid(c("1234567893", NA, "123"))), 3L)
})

# -----------------------------------------------------------------------------
# DATA-BOUND: county geography, tracked and therefore checkable in CI
# -----------------------------------------------------------------------------
county_path <- file.path(root, "artifacts", "county_profiles", "county_cnm_births.csv")

test_that("county GEOIDs are a unique, zero-padded, five-wide key", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, colClasses = "character", check.names = FALSE)

  expect_character_id_width(d$GEOID, width = 5L, label = "county GEOID")
  expect_id_numeric_chars(d$GEOID, label = "county GEOID")
  expect_unique_key(d, "GEOID", label = "county profile")
})

test_that("obstetric hospitals never outnumber the hospitals they are drawn from", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, check.names = FALSE)
  # A county cannot have more hospitals offering obstetric services than it has
  # hospitals. If this ever fires, the OB flag is being read from a different
  # vintage than the facility list -- which is how cycle 15 published 651
  # counties as having no obstetric care.
  expect_numerator_le_denominator(
    as.numeric(d$n_hosp_ob), as.numeric(d$n_hosp_active),
    label = "obstetric hospitals vs active hospitals")
})

test_that("a share of births is a share", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, check.names = FALSE)
  share <- suppressWarnings(as.numeric(d$cnm_share_of_births_pct))
  expect_numerator_le_denominator(share, rep(100, length(share)),
                                  label = "CNM share of births")
  expect_nonnegative(share, allow_na = TRUE, label = "CNM share of births")
})

# -----------------------------------------------------------------------------
# DATA-BOUND: provenance sidecars cannot have been written in the future
# -----------------------------------------------------------------------------
test_that("no artifact claims to have been written in the future", {
  side <- list.files(file.path(root, "artifacts"), pattern = "\\.provenance\\.json$",
                     recursive = TRUE, full.names = TRUE)
  skip_if(length(side) == 0, "no provenance sidecars present")

  stamps <- vapply(side, function(p) {
    v <- tryCatch(jsonlite::fromJSON(p)$written_utc, error = function(e) NULL)
    if (is.null(v) || !length(v)) NA_character_ else as.character(v)[1]
  }, character(1))
  stamps <- stamps[!is.na(stamps)]
  skip_if(length(stamps) == 0, "no readable timestamps")

  # A future timestamp means the machine's clock was wrong when the artifact was
  # written, which makes every staleness comparison against it meaningless.
  parsed <- as.POSIXct(sub(" UTC$", "", stamps), tz = "UTC")
  expect_no_future_dates(parsed, today = Sys.Date() + 1L,
                         label = "provenance written_utc")
})

# -----------------------------------------------------------------------------
# DATA-BOUND: the NPIs themselves. Gitignored, so this SKIPS on a runner.
# -----------------------------------------------------------------------------
test_that("every NPI in the linkage carries a valid check digit", {
  candidates <- c(
    file.path(root, "artifacts", "amcb_npi_linkage_FROZEN_2026-08-08.csv"),
    file.path(root, "midwives_with_nppes.csv")
  )
  present <- candidates[file.exists(candidates)]
  skip_if(length(present) == 0,
          "person-level linkage artifacts are gitignored; run locally to check NPIs")

  d <- utils::read.csv(present[1], colClasses = "character", check.names = FALSE,
                       nrows = 25000)
  npi_col <- intersect(c("npi", "final_npi", "NPI"), names(d))
  skip_if(length(npi_col) == 0, "no NPI column in the artifact")

  v <- d[[npi_col[1]]]
  v <- v[!is.na(v) & nzchar(trimws(v)) & trimws(v) != "NA"]
  skip_if(length(v) == 0, "no populated NPIs")

  ok <- npi_luhn_valid(v)
  bad <- unique(v[!is.na(ok) & !ok])
  expect_true(length(bad) == 0,
              label = sprintf("NPIs failing the Luhn check (%d of %d, e.g. %s)",
                              length(bad), length(v),
                              paste(utils::head(bad, 5), collapse = ", ")))
})
