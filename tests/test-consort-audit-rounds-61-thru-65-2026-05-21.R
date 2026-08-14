# PORTED VERBATIM from mufflyt/isochrones @ 1907a5c40
#   tests/testthat/test-consort-audit-rounds-61-thru-65-2026-05-21.R
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
# Rounds 61-65 — CONSORT-diagram audit, 2026-05-21.
#
# Round 61 — active_criteria construction silently dropped NA-n_excluded
#            rows via `filter(n_excluded > 0)`. Surface NAs before the
#            filter as a warning so corrupted JSONs don't silently
#            erase whole criteria from the published figure.
# Round 62 — display_name from case_match(.default = criterion_name)
#            could carry NA into the rendered line. The fmt() guard
#            catches n_excluded NAs but not display_name NAs. Stop
#            loud if any line would render literal "NA" text.
# Round 63 — safe_percent only guarded the denominator; Inf / NaN
#            numerator (from upstream divide-by-zero) propagated and
#            sprintf("%.1f%%", Inf) would publish "Inf%". Clamp
#            Inf/-Inf/NaN to default while preserving NA propagation.
# Round 64 — (no separate fix; covered by round 63 in the chain)
# Round 65 — iso_pct_covered footnote guard only tested is.na() not
#            is.finite(). Inf-valued coverage % would render as
#            "Inf%" in the published STROBE footnote.

library(testthat)
suppressPackageStartupMessages({
  library(dplyr)
})

# ----- Round 61: active_criteria NA detection ---------------------------

test_that("active_criteria filter warns on NA n_excluded before dropping", {
  phase2 <- tibble::tibble(
    criterion_id   = c("C01", "C02", "C03"),
    n_excluded     = c(100L, NA_integer_, 50L),
    criterion_name = c("a", "b", "c")
  )
  # The fix surfaces NAs before filter
  expect_warning(
    {
      .n_na <- sum(is.na(phase2$n_excluded))
      if (.n_na > 0L) {
        warning(sprintf("%d row(s) have NA n_excluded", .n_na),
                call. = FALSE)
      }
      out <- phase2 |> dplyr::filter(!is.na(n_excluded) & n_excluded > 0)
    },
    regexp = "NA n_excluded"
  )
  expect_equal(nrow(out), 2L)
})

# ----- Round 62: display_name NA refuses to render ---------------------

test_that("display_name NA refuses to publish literal 'NA' to figure", {
  ac <- tibble::tibble(
    criterion_id = c("C01", "C02"),
    display_name = c("Real Name", NA_character_),
    n_excluded   = c(100L, 50L),
    line         = c("  Real Name: 100", "  NA: 50")
  )
  .bad <- which(is.na(ac$display_name) | grepl("\\bNA\\b", ac$line))
  expect_error(
    if (length(.bad) > 0L) {
      stop("display_name NA / 'NA' text in line", call. = FALSE)
    },
    regexp = "display_name NA"
  )
})

# ----- Round 63: safe_percent clamps Inf/NaN but preserves NA -----------

test_that("safe_percent clamps Inf/NaN to default but preserves NA", {
  source(here::here("R", "safe_divide.R"), local = TRUE, chdir = TRUE)
  # Normal case
  expect_equal(safe_percent(50, 100), 50)
  # Zero denominator -> default = 0
  expect_equal(safe_percent(50, 0), 0)
  # Inf numerator (legacy upstream divide-by-zero) -> default
  expect_equal(safe_percent(Inf, 100), 0)
  # NaN numerator -> default
  expect_equal(safe_percent(NaN, 100), 0)
  # NA numerator: documented behavior is NA propagation
  expect_true(is.na(safe_percent(NA_real_, 100)))
})

# ----- Round 65: iso_pct_covered Inf guard ------------------------------

test_that("iso_pct_covered footnote skips non-finite values", {
  # Pin the guard predicate
  should_render <- function(x) !is.na(x) && is.finite(x)
  expect_true(should_render(45.3))
  expect_false(should_render(NA_real_))
  expect_false(should_render(Inf))
  expect_false(should_render(-Inf))
  expect_false(should_render(NaN))
})
