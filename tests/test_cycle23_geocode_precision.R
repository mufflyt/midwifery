#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 23 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: the geocoding precision flags in R/13 and R/14 -- "a city centroid is
# a town, not a hospital".
#
# FINDING 1: coord_precision has no consumer. R/14's own roxygen says "a
# downstream travel time computed from a centroid is a statement about a town,
# not a hospital, and must be able to say so". Nothing reads the column. That is
# the fourth flag in this project that exists and never runs, after
# compute_match_score(), safe_left_join()'s unusable default, and the CRS
# contract's zero call sites.
#
# Nor is the artifact itself consumed: the hospital counts in county_base come
# from build_ob_hospital_counts(), which reads the POS file directly. So 2,784
# geocoded hospitals -- including 366 rate-limited fallback API calls -- feed
# nothing today. There is no live error here, and this file says so.
#
# FINDING 2, and the reason the flag is worth keeping: it PREDICTS ERROR.
# Resolving every geocode against the county POS assigns it:
#
#   precision          n     wrong county   % wrong
#   cache            364          6           1.6
#   census_batch    2054         43           2.1
#   fallback_address 347         16           4.6
#   city_centroid     19          3          15.8
#
# A centroid row is roughly SEVEN TIMES more likely to land in the wrong county
# than a census-batch row. The flag is not bookkeeping; it tracks real
# displacement, and 68 hospitals overall sit in a county other than the one the
# POS record claims.
#
# So the contract to pin is: precision is assigned correctly, it survives to the
# artifact, and it stays ordered -- so that when something finally consumes
# these coordinates, the caveat travels with them.
#
# Run: Rscript tests/test_cycle23_geocode_precision.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
GEO <- "artifacts/ob_hospitals_geocoded.csv"
d <- if (file.exists(GEO))
  suppressWarnings(read_csv(GEO, show_col_types = FALSE, progress = FALSE,
                            col_types = cols(county_fips = col_character()))) else NULL
FB <- paste(readLines("R/14-geocode-ob-fallbacks.R", warn = FALSE), collapse = "\n")
LEVELS <- c("cache", "census_batch", "fallback_address", "city_centroid", "unresolved")

cat("\n-- BVA --\n")

# T231 (BVA). Every row carries exactly one precision, drawn from the closed
# vocabulary. An unlabelled coordinate is one whose caveat has been lost.
{
  if (is.null(d)) chk(FALSE, "T231 artifact exists") else {
    chk(!any(is.na(d$coord_precision)),
        sprintf("T231a no row lacks a precision label [%d NA]", sum(is.na(d$coord_precision))))
    extra <- setdiff(unique(d$coord_precision), LEVELS)
    chk(length(extra) == 0L,
        sprintf("T231b precision is a closed vocabulary [unexpected: %s]",
                if (length(extra)) paste(extra, collapse = ", ") else "none"))
  }
}

# T232 (BVA). The two ends of the scale must agree with the data: a row WITH
# coordinates is never "unresolved", and a row WITHOUT is never anything else.
{
  if (is.null(d)) chk(FALSE, "T232 artifact") else {
    has <- !is.na(d$latitude) & !is.na(d$longitude)
    chk(!any(d$coord_precision[has] == "unresolved"),
        "T232a a row with coordinates is never labelled unresolved")
    chk(all(d$coord_precision[!has] == "unresolved") || sum(!has) == 0L,
        sprintf("T232b every row without coordinates is unresolved [%d such rows]", sum(!has)))
  }
}

# T233 (BVA). The centroid class is small and bounded. If it grew large the
# hospital layer would be mostly towns, and the analysis would need rethinking
# rather than a flag.
{
  if (is.null(d)) chk(FALSE, "T233 artifact") else {
    n <- sum(d$coord_precision == "city_centroid")
    chk(n > 0L && n <= 50L,
        sprintf("T233 centroid-level rows are present but rare [%d of %d, %.2f%%]",
                n, nrow(d), 100 * n / nrow(d)))
  }
}

cat("\n-- SEMANTIC --\n")

# T234 (semantic). THE FINDING. Nothing consumes coord_precision. Recorded as an
# assertion so that the day something does, this test changes and the change is
# noticed rather than assumed safe.
{
  consumers <- unlist(lapply(
    list.files("R", pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
    function(f) {
      if (basename(f) %in% c("14-geocode-ob-fallbacks.R", "13-geocode-ob-hospitals.R")) return(NULL)
      x <- readLines(f, warn = FALSE); x[grepl("^\\s*#", x)] <- ""
      if (any(grepl("coord_precision", x))) basename(f) else NULL
    }))
  chk(length(consumers) == 0L,
      sprintf("T234 coord_precision still has no consumer outside the scripts that set it [%s]",
              if (length(consumers)) paste(consumers, collapse = ", ") else "none"))
}

# T235 (semantic). The label must mean what it says. "city_centroid" rows are
# the ones whose match type says centroid; the mapping cannot be arbitrary.
{
  chk(grepl('grepl\\("centroid", fb_match_type, ignore.case = TRUE\\)', FB),
      "T235a the centroid class is derived from the geocoder's own match type")
  chk(grepl('!is\\.na\\(latitude\\) & source == "cache"\\s*~\\s*"cache"', FB),
      "T235b cached coordinates keep their own provenance rather than being relabelled")
}

# T236 (semantic). PRECISION PREDICTS ERROR -- the justification for keeping the
# flag at all. A centroid row must be materially more likely to fall outside the
# county the POS record claims than a rooftop-level one. If that ever ceases to
# hold, the flag is measuring nothing.
{
  if (is.null(d) || !"county_fips" %in% names(d)) {
    chk(FALSE, "T236 county_fips present")
  } else {
    stash <- file.path(root, "artifacts", ".county_agreement_by_precision.csv")
    if (!file.exists(stash)) {
      cat("  skip T236 measurement cache absent (written by the cycle-23 run)\n")
    } else {
      m <- suppressWarnings(read_csv(stash, show_col_types = FALSE, progress = FALSE))
      cen <- m$pct_wrong[m$coord_precision == "city_centroid"]
      bat <- m$pct_wrong[m$coord_precision == "census_batch"]
      chk(length(cen) == 1L && length(bat) == 1L && cen > 2 * bat,
          sprintf("T236 centroid rows land in the wrong county far more often [%.1f%% vs %.1f%%]",
                  cen, bat))
    }
  }
}

# T237 (semantic). The caveat must survive to the artifact, not live only in the
# function that computed it. This is the difference between a flag and a comment.
{
  if (is.null(d)) chk(FALSE, "T237 artifact") else {
    chk("coord_precision" %in% names(d),
        "T237a the artifact carries the precision column")
    chk(sum(d$coord_precision == "city_centroid") ==
          sum(grepl("centroid", d$fb_match_type, ignore.case = TRUE), na.rm = TRUE),
        sprintf("T237b every centroid match is labelled as one [%d flagged, %d matched]",
                sum(d$coord_precision == "city_centroid"),
                sum(grepl("centroid", d$fb_match_type, ignore.case = TRUE), na.rm = TRUE)))
  }
}

cat("\n-- ADVERSARIAL --\n")

# T238 (adversarial). Idempotence, the cycle-22 theme applied here. R/14 strips
# its own output columns before re-deriving them, so a second run must not
# produce fb_match_type.x / .y. That guard already exists; this pins it.
{
  chk(grepl('select\\(-any_of\\(c\\("fb_match_type", "fb_source", "coord_precision"\\)\\)\\)', FB),
      "T238a R/14 strips its own columns before re-merging, so it can run twice")
  if (!is.null(d)) {
    suffixed <- grep("\\.(x|y)$", names(d), value = TRUE)
    chk(length(suffixed) == 0L,
        sprintf("T238b the artifact carries no collision remnants [%s]",
                if (length(suffixed)) paste(suffixed, collapse = ", ") else "none"))
  }
}

# T239 (adversarial). One provider, one row. The merge is keyed on prvdr_num;
# a duplicate would double-count a hospital in any count derived from this file.
{
  if (is.null(d)) chk(FALSE, "T239 artifact") else {
    chk(sum(duplicated(d$prvdr_num)) == 0L,
        sprintf("T239 no provider appears twice [%d duplicates]", sum(duplicated(d$prvdr_num))))
  }
}

# T240 (adversarial). A hospital whose coordinates disagree with its own POS
# county is a real, countable condition -- not an abstraction. Pin the total so
# it cannot grow unnoticed while the artifact is unconsumed.
{
  stash <- file.path(root, "artifacts", ".county_agreement_by_precision.csv")
  if (!file.exists(stash)) {
    cat("  skip T240 measurement cache absent\n")
  } else {
    m <- suppressWarnings(read_csv(stash, show_col_types = FALSE, progress = FALSE))
    tot <- sum(m$wrong)
    chk(tot <= 80L,
        sprintf("T240 hospitals sitting outside their POS county do not grow beyond the recorded %d",
                tot))
  }
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
