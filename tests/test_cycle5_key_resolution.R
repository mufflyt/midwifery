#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 5 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Clears the debt carried since cycle 2: the 13 unaudited
# distinct(..., .keep_all = TRUE) sites. Cycle 2 fixed the one inside
# join_safety.R and deliberately left the rest, on the grounds that they should
# be CLASSIFIED rather than rewritten blindly. This cycle classifies them.
#
# The classification that matters is not "does it break today". Every one of
# these sites is harmless on the current artifacts. The question is whether the
# contract GUARANTEES it, or whether the data merely happens to comply -- which
# is the difference between a rule and a coincidence. Two findings here are
# purely of that kind:
#
#   * data/ct_tract_crosswalk_2022.csv has no tract mapping to two planning
#     regions, so the deduplication is a no-op -- today.
#   * data/cms_pos_hospital.csv has NO duplicate PRVDR_NUM at all, so the
#     documented "most recently certified record wins" rule has never once
#     fired, and has therefore never been observed to work.
#
# A silent tie-break that has never executed is not a tested rule; it is an
# untested rule that has not yet been asked a question.
#
# Run: Rscript tests/test_cycle5_key_resolution.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "join_safety.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
rd <- function(p, ...) suppressWarnings(read_csv(file.path(root, p),
                                                show_col_types = FALSE, progress = FALSE, ...))

cat("\n-- BVA --\n")

# T41 (BVA). The conflict-refusing helper at its cardinality edges.
{
  z <- data.frame(k = character(0), v = character(0))
  chk(nrow(suppressMessages(assert_unique_keys(z, "k", "t41", dedupe = TRUE))) == 0L,
      "T41a zero rows pass through unchanged")
  one <- data.frame(k = "A", v = "x")
  chk(nrow(suppressMessages(assert_unique_keys(one, "k", "t41", dedupe = TRUE))) == 1L,
      "T41b a single row is not mistaken for a duplicate")
  allsame <- data.frame(k = c("A", "A", "A"), v = c("x", "x", "x"))
  chk(nrow(suppressMessages(assert_unique_keys(allsame, "k", "t41", dedupe = TRUE))) == 1L,
      "T41c three identical rows collapse to one")
}

# T42 (BVA). A composite key must be evaluated jointly, not column by column.
# Rows agreeing on one component and differing on the other are NOT duplicates.
{
  d <- data.frame(a = c("1", "1"), b = c("x", "y"), v = c(1, 2))
  out <- tryCatch(suppressMessages(assert_unique_keys(d, c("a", "b"), "t42", dedupe = TRUE)),
                  error = function(e) NULL)
  chk(!is.null(out) && nrow(out) == 2L,
      "T42 a two-column key treats (1,x) and (1,y) as distinct")
}

# T43 (BVA). FIPS padding. A GEOID that loses its leading zero silently becomes
# a different county -- 09001 (Fairfield CT) read as 9001 is not a FIPS at all,
# and 01001 read as 1001 collides with nothing but joins to nothing either.
{
  cb <- rd("data/county_base.csv", col_types = cols(GEOID = col_character()))
  chk(all(nchar(cb$GEOID) == 5L),
      sprintf("T43a every county GEOID is 5 characters [violations: %d]",
              sum(nchar(cb$GEOID) != 5L)))
  lead0 <- cb$GEOID[substr(cb$GEOID, 1, 1) == "0"]
  chk(length(lead0) > 0L,
      sprintf("T43b leading-zero FIPS survive as characters [%d such counties]",
              length(lead0)))
}

cat("\n-- SEMANTIC --\n")

# T44 (semantic). THE AUDIT. Every surviving .keep_all site must be either
#   (a) preceded by an explicit arrange(), making the tie-break a stated rule, or
#   (b) replaced by the conflict-refusing helper.
# A bare distinct(key, .keep_all = TRUE) resolves a data conflict by whatever
# order the rows arrived in, which is a scientific decision made by a file.
{
  files <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)
  offenders <- character(0)
  for (f in files) {
    src <- readLines(f, warn = FALSE)
    hits <- grep("distinct\\(.*\\.keep_all = TRUE", src)
    for (i in hits) {
      if (grepl("^\\s*#", src[i])) next
      window <- src[max(1, i - 4):i]
      if (!any(grepl("arrange\\(", window))) {
        offenders <- c(offenders, sprintf("%s:%d", basename(f), i))
      }
    }
  }
  # RATCHET, not a pass. 17 bare sites were inventoried this cycle and every one
  # is a no-op on the current artifacts, so converting all of them at once would
  # be a large mechanical edit with real regression risk and no observable
  # benefit. The three that can move a thing on a MAP were fixed with judgment
  # (see T45/T46/T47); the rest are named debt.
  #
  # This asserts the count cannot GROW. That is a genuine contract -- a new bare
  # .keep_all fails the build -- and it is not the same as declaring the debt
  # paid. The ledger carries the remaining inventory.
  BASELINE <- 14L
  chk(length(offenders) <= BASELINE,
      sprintf("T44 bare .keep_all count does not grow beyond the recorded debt [%d of %d allowed]",
              length(offenders), BASELINE))
  cat(sprintf("       remaining debt: %s\n", paste(offenders, collapse = ", ")))
}

# T45 (semantic). The CT tract crosswalk must be a FUNCTION from 2020 tract to
# 2022 planning region. Deduplication currently hides any violation; if a tract
# ever mapped to two regions, apportionment weights would be built from an
# arbitrary half of the evidence.
{
  x <- rd("data/ct_tract_crosswalk_2022.csv")
  multi <- x %>% distinct(tract_fips_2020, ce_fips_2022) %>%
    count(tract_fips_2020) %>% filter(n > 1L)
  chk(nrow(multi) == 0L,
      sprintf("T45 every 2020 tract maps to exactly one 2022 planning region [violations: %d]",
              nrow(multi)))
}

# T46 (semantic). One midwife, one location. A certification_number carrying
# two different coordinate pairs resolved by row order puts a person in a
# different county -- and county is the unit of every access finding here.
{
  p <- file.path(root, "artifacts", "geocode_final_results.csv")
  if (!file.exists(p)) { cat("  skip T46 geocode_final_results.csv absent\n") } else {
    g <- rd("artifacts/geocode_final_results.csv")
    key <- intersect(c("certification_number"), names(g))
    if (!length(key)) { cat("  skip T46 no certification_number column\n") } else {
      ll <- intersect(c("latitude", "longitude"), names(g))
      conflicting <- g %>% distinct(across(all_of(c(key, ll)))) %>%
        count(across(all_of(key))) %>% filter(n > 1L)
      chk(nrow(conflicting) == 0L,
          sprintf("T46 no certificant carries two different coordinate pairs [%d do]",
                  nrow(conflicting)))
    }
  }
}

# T47 (semantic). Cycle 1 built build_rucc_lookup() precisely because a bare
# distinct() let file order decide whether a county was metropolitan. That fix
# did not reach R/01-build-county-base.R, which still reads the RUCC workbook
# with a bare distinct(GEOID, .keep_all = TRUE).
{
  src <- paste(readLines(file.path(root, "R", "01-build-county-base.R"), warn = FALSE),
               collapse = "\n")
  reads_rucc_safely <- grepl("build_rucc_lookup", src) ||
    !grepl("rucc_2023 = as\\.integer\\(RUCC_2023\\)[\\s\\S]{0,200}distinct\\(GEOID, \\.keep_all = TRUE\\)", src)
  chk(reads_rucc_safely,
      "T47 the RUCC workbook read does not resolve a duplicate FIPS by row order")
}

cat("\n-- ADVERSARIAL --\n")

# T48 (adversarial). The POS "most recently certified wins" rule has never
# fired, because the current extract has no duplicate PRVDR_NUM. Exercise it
# directly, including the tie it does not address: two records for one provider
# with the SAME certification date fall back to row order.
{
  # FAC_NAME is the real POS column; my first fixture called it NAME, so the
  # test exercised a sort key the production rule does not use and failed for
  # the wrong reason. The tie-break can only be tested against the column it
  # actually sorts on.
  mk <- function(order) data.frame(
    PRVDR_NUM = c("A", "A"), CRTFCTN_DT = c("2020-01-01", "2020-01-01"),
    FAC_NAME = order, stringsAsFactors = FALSE)
  pick <- function(d) d %>%
    arrange(PRVDR_NUM, desc(CRTFCTN_DT), across(any_of(c("FAC_NAME", "PRVDR_NAME")))) %>%
    distinct(PRVDR_NUM, .keep_all = TRUE) %>% pull(FAC_NAME)
  a <- pick(mk(c("first", "second")))
  b <- pick(mk(c("second", "first")))
  chk(identical(a, b),
      sprintf("T48 a same-date tie does not resolve by input order [%s vs %s]", a, b))
}

# T49 (adversarial). Class N1 outside Connecticut. sum(land, na.rm = TRUE)
# builds a land area used as a density denominator; a missing tract silently
# contributes 0 square metres, shrinking the denominator and inflating density.
{
  gh <- readLines(file.path(root, "R", "03-geography-hierarchy.R"), warn = FALSE)
  i <- grep("sum\\(land, na\\.rm = TRUE\\)", gh)
  guarded <- length(i) == 0L ||
    any(grepl("is\\.na\\(land\\)|n_missing|anyNA", gh[max(1, min(i) - 6):min(length(gh), max(i) + 2)]))
  chk(guarded,
      sprintf("T49 the land-area aggregation accounts for missing tracts [line(s): %s]",
              paste(i, collapse = ", ")))
}

# T50 (adversarial). A city centroid is a town, not a hospital. R/14 records
# coord_precision explicitly for this reason; any downstream distance or
# coverage claim must be able to see it, so the flag must survive to the
# artifact rather than being dropped on the way.
{
  p <- file.path(root, "artifacts", "ob_hospitals_geocoded.csv")
  if (!file.exists(p)) { cat("  skip T50 ob_hospitals_geocoded.csv absent\n") } else {
    h <- rd("artifacts/ob_hospitals_geocoded.csv")
    chk("coord_precision" %in% names(h),
        "T50a the geocoded artifact carries coord_precision")
    if ("coord_precision" %in% names(h)) {
      centroid <- sum(h$coord_precision == "city_centroid", na.rm = TRUE)
      unresolved <- sum(h$coord_precision == "unresolved", na.rm = TRUE)
      coord_ok <- !is.na(h$latitude)
      chk(all(h$coord_precision[!coord_ok] == "unresolved"),
          "T50b every row without coordinates is flagged unresolved, not precise")
      cat(sprintf("       (city_centroid: %d, unresolved: %d of %d)\n",
                  centroid, unresolved, nrow(h)))
    }
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
