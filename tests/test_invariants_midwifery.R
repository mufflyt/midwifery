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

suppressPackageStartupMessages({
  library(testthat)
  library(stringr)          # zip5_key() and friends are built on it
})
source(file.path(root, "tests", "helper-invariants.R"))
# The canonical join keys, so the fixture tests below can assert against the
# real implementations rather than a copy of them.
source(file.path(root, "R", "lib", "common_helpers.R"))

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

# =============================================================================
# The ported contracts and schema validators
# =============================================================================
# helper-contracts.R came over verbatim; helper-schema-validation.R was
# translated from DBI/SQL to data frames, because upstream's version needs a
# DuckDB warehouse this repository does not have. See each file's header.
# =============================================================================

source(file.path(root, "tests", "helper-contracts.R"))
source(file.path(root, "tests", "helper-schema-validation.R"))

test_that("the county profile satisfies its column and domain contracts", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, check.names = FALSE)

  # The contract_* guards stop() rather than returning an expectation, which is
  # what makes them usable from pipeline code. Wrapped in expect_error(., NA)
  # so testthat records an assertion -- an unwrapped guard leaves an EMPTY test,
  # which reports as a pass and checks nothing (Hall of Shame #6).

  # Columns every downstream figure reads. A rename upstream is silent until a
  # map comes out empty; this makes it loud.
  expect_error(contract_require_cols(d, c("GEOID", "state", "n_midwives",
                                          "n_hosp_active", "n_hosp_ob",
                                          "suppressed", "wonder_county_reported")), NA)

  # RUCC is 1-9 and nothing else. A 0 or a 10 means the crosswalk changed
  # vintage without anyone saying so.
  expect_error(contract_domain(d$rucc_2023, allowed = as.character(1:9)), NA)

  # The suppression flags are logical, not the strings "TRUE"/"T"/"1" in three
  # different files -- which is how "suppressed" stops meaning suppressed.
  expect_error(contract_domain(as.character(d$suppressed),
                               allowed = c("TRUE", "FALSE", "NA", NA)), NA)
})

test_that("GEOID is a unique key by the ported cardinality validator", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, colClasses = "character", check.names = FALSE)
  expect_validation_ok(validate_cardinality(d, "GEOID", "unique"))
})

test_that("county domain invariants hold", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, check.names = FALSE)

  # The suppressed-is-not-zero rule, expressed as a predicate rather than as
  # bespoke code -- same invariant ci_artifact_contracts.R asserts, now stated
  # in the shared vocabulary so it reads the same in both places.
  expect_validation_ok(validate_domain_invariant(
    d,
    function(x) !(as.logical(x$suppressed) %in% TRUE &
                  !is.na(x$cnm_births_2016_2024) &
                  x$cnm_births_2016_2024 == 0),
    "a suppressed county never carries a zero"))

  expect_validation_ok(validate_domain_invariant(
    d,
    function(x) is.na(x$n_hosp_ob) | is.na(x$n_hosp_active) |
                x$n_hosp_ob <= x$n_hosp_active,
    "obstetric hospitals never exceed active hospitals"))
})

test_that("published rates stay inside their plausible range", {
  skip_if_not(file.exists(county_path), "county_cnm_births.csv not present")
  d <- utils::read.csv(county_path, check.names = FALSE)

  expect_validation_ok(validate_statistical_property(
    d$cnm_share_of_births_pct, 0, 100,
    "CNM share of births is a percentage"))

  # A general fertility rate is only interpretable where the denominator can
  # carry one. De Baca County NM has 145 women aged 15-44 and 70 births, which
  # is 483 per 1,000 -- noise, not a defect, and bounding the raw maximum would
  # have flagged it. That is cycle 7's lesson exactly ("a superlative that named
  # the noisiest county"), so the invariant is restricted to counties with a
  # denominator of at least 1,000. Among those the observed maximum is 386.
  big <- d[!is.na(d$women_15_44) & d$women_15_44 >= 1000, ]
  expect_validation_ok(validate_statistical_property(
    big$acs_births_per_1000_women_15_44, 0, 450,
    "ACS fertility rate is possible where the denominator supports one"))
})

test_that("certification never postdates expiration", {
  # DATA-BOUND: the roster is gitignored, so this skips on a runner.
  roster <- file.path(root, "midwives.csv")
  skip_if_not(file.exists(roster), "midwives.csv is gitignored; run locally")
  d <- utils::read.csv(roster, colClasses = "character", check.names = FALSE)
  skip_if_not(all(c("certification_date", "expiration_date") %in% names(d)),
              "roster lacks the date columns")

  # AMCB publishes MM/YYYY. Passing the format explicitly is deliberate: an
  # unparsed column would compare as all-NA and pass vacuously.
  expect_validation_ok(validate_temporal_consistency(
    d$certification_date, d$expiration_date,
    "certification precedes expiration", format = "%m/%Y"))
})

test_that("the linkage holds unique AND arithmetically valid NPIs", {
  # DATA-BOUND. Uniqueness and validity are different properties: a file can
  # hold 16,892 unique NPIs several of which are typos.
  frozen <- file.path(root, "artifacts", "amcb_npi_linkage_FROZEN_2026-08-08.csv")
  skip_if_not(file.exists(frozen), "frozen linkage is gitignored; run locally")
  d <- utils::read.csv(frozen, colClasses = "character", check.names = FALSE)
  skip_if_not("npi" %in% names(d), "no npi column")

  linked <- d[!is.na(d$npi) & nzchar(trimws(d$npi)) & trimws(d$npi) != "NA", ]
  skip_if(nrow(linked) == 0, "no linked NPIs")

  expect_error(contract_npi_unique(linked, "npi", context = "frozen linkage"), NA)
  expect_error(contract_npi_valid(linked, "npi", context = "frozen linkage"), NA)
})

# =============================================================================
# Synthetic fixtures: the same contracts, exercised where the real data cannot go
# =============================================================================
# The tests above that read person-level artifacts SKIP on a runner. These do
# not: they build a roster-shaped fixture that describes nobody, so the contract
# code paths execute in CI, and -- more usefully -- they plant defects and
# require the guards to catch them. A guard never seen to fail is not known to
# work.
# =============================================================================

source(file.path(root, "tests", "helper-data-generation.R"))

test_that("gen_npi produces NPIs that are actually valid, not merely shaped", {
  # The ported bug: upstream drew the check digit at random, so ~1 in 10 of its
  # "valid" NPIs validated. valid_rate must mean what it says or every fixture
  # built on it is quietly wrong.
  set.seed(101)
  v <- gen_npi(200, valid_rate = 1)
  expect_true(all(npi_luhn_valid(v)))

  set.seed(102)
  mixed <- gen_npi(200, valid_rate = 0.9)
  expect_gte(sum(npi_luhn_valid(mixed), na.rm = TRUE), 170L)
})

test_that("a clean synthetic linkage satisfies every contract", {
  d <- create_test_amcb_linkage(n = 300, seed = 7)
  linked <- d[!is.na(d$npi), ]

  expect_error(contract_require_cols(d, c("certification_number", "npi",
                                          "certification_date", "expiration_date")), NA)
  expect_error(contract_npi_unique(linked, "npi", context = "synthetic linkage"), NA)
  expect_error(contract_npi_valid(linked, "npi", context = "synthetic linkage"), NA)
  expect_validation_ok(validate_cardinality(d, "certification_number", "unique"))
  expect_validation_ok(validate_temporal_consistency(
    d$certification_date, d$expiration_date,
    "certification precedes expiration", format = "%m/%Y"))
})

test_that("every planted defect is caught by the guard that owns it", {
  # Each of these is a real failure this pipeline has had or could have.
  expect_error(
    contract_npi_unique(create_test_amcb_linkage(50, seed = 8, corrupt = "duplicate_npi"),
                        "npi", context = "planted duplicate"),
    "Duplicate NPIs")

  expect_error(
    contract_npi_valid(create_test_amcb_linkage(50, seed = 9, corrupt = "invalid_npi"),
                       "npi", context = "planted typo"),
    "check digit")

  rev <- create_test_amcb_linkage(50, seed = 10, corrupt = "reversed_dates")
  expect_false(validate_temporal_consistency(rev$certification_date, rev$expiration_date,
                                             "order", format = "%m/%Y")$ok)

  # The blank-ZIP case is the defect fixed in zip5_key(): "", "  " and "NA" must
  # not collapse to one joinable key.
  blank <- create_test_amcb_linkage(50, seed = 11, corrupt = "blank_zip")
  keys <- zip5_key(blank$practice_zip[1:3])
  expect_true(all(is.na(keys)))
})
