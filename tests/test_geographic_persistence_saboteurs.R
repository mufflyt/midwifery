#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against the geographic persistence statistics
# =============================================================================
# WHY THIS ONE. compute_geographic_persistence_stats() is the shared core
# behind every number in docs/RESULTS_geographic_persistence.md and the
# persistence manuscript: annual and career persistence, the rurality
# stratification, and the movers table. It is one function, it had no tests,
# and it could not be called at all without another file's constant.
#
# TWO DEFECTS THESE FOUND.
#
# G1: the function used RURALITY_LABELS_SHORT, which lives in
# table1_bands.R, and never sourced it. It worked only when the caller
# happened to have loaded that file first, and otherwise died inside
# factor() with an error naming neither the constant nor this function.
#
# G2: county persistence divided by the pairs it could judge; ZIP and state
# divided by ALL pairs. Because same_zip is FALSE when either side is
# missing, an unresolved ZIP was counted as a MOVE. On data where nobody
# moved, one missing ZIP in four pairs reported 75% ZIP persistence against
# 100% county persistence. The panel holds two blank ZIPs in 4.7 million
# rows, so this was near-harmless -- until the ZIP normalizer sweep started
# returning NA for the 28 "00000" and 143 sub-three-digit values that had
# been passing through as though they were real places.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path(root, "R", "lib", "geographic_persistence_stats.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
sab <- function(n, name) cat(sprintf("\nG%d %s\n", n, name))

METRO <- RURALITY_LABELS_SHORT[1]
RURAL <- RURALITY_LABELS_SHORT[length(RURALITY_LABELS_SHORT)]

#' Build a provider-year fixture; every argument is a vector of equal length.
mk <- function(npi, year, zip, state, county, rucc = METRO) {
  tibble(npi = npi, snapshot_year = year, practice_zip = zip,
         practice_state = state, county_fips = county,
         rucc_cat = rep_len(rucc, length(npi)))
}
annual_of <- function(r) r$rates[r$rates$horizon == "year_to_year", ]
career_of <- function(r) r$rates[r$rates$horizon == "first_vs_last", ]

sab(1, "the function stands on its own, without a caller's constants")
{
  # Sourcing this file alone must be enough. Before the fix, the constant
  # came from table1_bands.R and this test could not even have run.
  chk(exists("RURALITY_LABELS_SHORT"),
      "RURALITY_LABELS_SHORT is available from sourcing this library alone")
  chk(length(RURALITY_LABELS_SHORT) >= 2L,
      sprintf("and names at least two strata [%d]",
              length(RURALITY_LABELS_SHORT)))
}

sab(2, "THE DENOMINATOR: an unresolved value is unknown, not a move")
{
  # Four providers, two years each. Everyone with a ZIP stayed put; one
  # provider's ZIP is simply not recorded in the second year.
  py <- mk(rep(c("A","B","C","D"), each = 2), rep(c(2024L, 2025L), 4),
           c("80204","80204","80204","80204","80204","80204","80204", NA),
           rep("CO", 8),
           c("08031","08031","08031","08031","08031","08031","08031", NA))
  a <- annual_of(compute_geographic_persistence_stats(py))
  chk(identical(a$same_county_pct, 100),
      sprintf("county persistence is 100%% [%s]", a$same_county_pct))
  chk(identical(a$same_zip_pct, 100),
      sprintf("and so is ZIP: nobody moved [%s]", a$same_zip_pct))
}

sab(3, "a genuine move still registers as a move")
{
  # The inverse of G2. Correcting the denominator must not make the measure
  # blind to real movement.
  py <- mk(rep(c("A","B"), each = 2), rep(c(2024L, 2025L), 2),
           c("80204","80204","80204","10001"), rep("CO", 4),
           c("08031","08031","08031","36061"))
  a <- annual_of(compute_geographic_persistence_stats(py))
  chk(identical(a$same_zip_pct, 50), sprintf("one of two moved [%s]", a$same_zip_pct))
  chk(identical(a$same_county_pct, 50), sprintf("county agrees [%s]", a$same_county_pct))
}

sab(4, "a provider seen once contributes no year-to-year pair")
{
  py <- mk(c("A","A","B"), c(2024L, 2025L, 2024L),
           rep("80204", 3), rep("CO", 3), rep("08031", 3))
  r <- compute_geographic_persistence_stats(py)
  chk(r$panel$pairs_total == 1L,
      sprintf("one pair, not two or three [%d]", r$panel$pairs_total))
  chk(r$panel$observed == 2L, "though both providers are counted as observed")
}

sab(5, "a gap year still forms a pair of consecutive OBSERVATIONS")
{
  # Deliberate: a provider absent in 2025 and back in 2026 has one
  # transition, not none. Requiring literal y/y+1 would silently discard it.
  py <- mk(rep("A", 2), c(2024L, 2026L), rep("80204", 2), rep("CO", 2),
           rep("08031", 2))
  r <- compute_geographic_persistence_stats(py)
  chk(r$panel$pairs_total == 1L,
      sprintf("the 2024 to 2026 gap still forms one pair [%d]",
              r$panel$pairs_total))
}

sab(6, "career persistence compares first against last, not neighbours")
{
  # A provider who leaves and returns is in the same place at the ends and
  # must read as persistent over the career horizon even though she moved.
  py <- mk(rep("A", 3), c(2023L, 2024L, 2025L),
           c("80204","10001","80204"), rep("CO", 3),
           c("08031","36061","08031"))
  r <- compute_geographic_persistence_stats(py)
  chk(identical(career_of(r)$same_county_pct, 100),
      "first equals last, so career persistence is 100%")
  chk(identical(annual_of(r)$same_county_pct, 0),
      "while both year-to-year transitions were moves")
}

sab(7, "nothing comparable reports NA, not NaN")
{
  # Every county unresolved. 0/0 is NaN, which reads in a results table as a
  # failed computation or as zero persistence.
  py <- mk(rep("A", 2), c(2024L, 2025L), rep("80204", 2), rep("CO", 2),
           rep(NA_character_, 2))
  a <- annual_of(compute_geographic_persistence_stats(py))
  chk(is.na(a$same_county_pct) && !is.nan(a$same_county_pct),
      sprintf("county persistence is NA, not NaN [%s]", a$same_county_pct))
  chk(identical(a$same_zip_pct, 100),
      "while ZIP, which IS resolved, still reports normally")
}

sab(8, "INVERTED: the rurality strata keep their order, not alphabetical")
{
  # origin is a factor over RURALITY_LABELS_SHORT so Metro sorts before
  # Nonmetro. Dropping the factor would sort alphabetically and silently
  # transpose the rows of a published table.
  py <- mk(rep(c("A","B"), each = 2), rep(c(2024L, 2025L), 2),
           rep("80204", 4), rep("CO", 4), rep("08031", 4),
           rucc = c(RURAL, RURAL, METRO, METRO))
  r <- compute_geographic_persistence_stats(py)
  chk(is.factor(r$rurality$origin), "origin is a factor, not free text")
  chk(identical(levels(r$rurality$origin), RURALITY_LABELS_SHORT),
      "with the canonical stratum order as its levels")
}

sab(9, "INVERTED: the movers table is zero-filled, not sparse")
{
  # A stratum pair nobody moved between must appear as 0, not be absent.
  # A sparse table silently renumbers rows when joined or printed.
  py <- mk(rep(c("A"), each = 2), c(2024L, 2025L),
           c("80204","10001"), rep("CO", 2), c("08031","36061"),
           rucc = c(METRO, METRO))
  r <- compute_geographic_persistence_stats(py)
  chk(nrow(r$movers) == length(RURALITY_LABELS_SHORT)^2,
      sprintf("every origin-destination cell present [%d of %d]",
              nrow(r$movers), length(RURALITY_LABELS_SHORT)^2))
  chk(all(!is.na(r$movers$n)), "and none of them is NA")
}

sab(10, "INVERTED: the required columns are demanded, not assumed")
{
  py <- mk(rep("A", 2), c(2024L, 2025L), rep("80204", 2), rep("CO", 2),
           rep("08031", 2))
  # ERRORING IS NOT ENOUGH. Without the up-front check the function still
  # fails, but deep inside a grouped mutate, with a message naming a group
  # key and not the missing column. Mutation testing showed that asserting
  # merely "it errors" could not tell the two apart, so this asserts the
  # error is the contract one and names what is missing.
  msg <- tryCatch({
    compute_geographic_persistence_stats(py %>% select(-rucc_cat)); NA_character_
  }, error = function(e) conditionMessage(e))
  chk(!is.na(msg), "a missing required column stops the function")
  # "Mentions rucc_cat" does not discriminate: the dplyr failure mentions it
  # too, in "object 'rucc_cat' not found" from inside a grouped mutate.
  # What only the contract check produces is the function's own name.
  chk(!is.na(msg) &&
        grepl("compute_geographic_persistence_stats()", msg, fixed = TRUE),
      sprintf("the error is the contract one, naming this function [%s]",
              substr(gsub("[[:space:]]+", " ", msg), 1, 44)))
  chk(!is.na(msg) && grepl("rucc_cat", msg, fixed = TRUE),
      "and names the column that is missing")
  chk(tryCatch({ compute_geographic_persistence_stats(py); TRUE },
               error = function(e) FALSE),
      "while a complete frame runs")
}

cat(sprintf("\n%s (%d failures across 10 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
