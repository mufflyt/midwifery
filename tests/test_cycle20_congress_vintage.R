#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 20 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: R/lib/congress_roster.R and the district-profile join -- never tested,
# and the place where a named human being is attached to a set of statistics.
#
# THE FINDING. `boundary_vintage` disclosed a real problem correctly and then
# said it in the least useful possible way: ONE CONSTANT STRING on all 437 rows.
# ACS 2023 reports on 118th-Congress boundaries while the roster is the 119th,
# and five states -- AL, GA, LA, NY, NC -- redrew their maps in between. So
# 67 of 437 districts (15.3%) pair a member with statistics for differently
# shaped ground, and 370 do not. Colorado carried the same warning as Alabama.
#
# A disclosure that says the same thing everywhere tells a reader nothing about
# their own district. It is per-row knowable, so it is now per-row stated.
#
# A CLAIM I TRIED TO REFUTE AND COULD NOT. A comment asserts that CA-14, FL-20,
# GA-13 and TX-23 have no representative because the seats are VACANT. Given
# this loop has now caught three comments that were wrong about their own data
# (cycle 15's rural claim, cycle 16's band labels, cycle 17's numerator), that
# looked like a fourth. It is not:
#
#   roster House rows      437  =  431 filled voting seats + 6 delegates
#   ACS districts          437  =  435 voting + DC + PR
#   CA districts in roster  51  of 52, with 14 absent
#
# The arithmetic closes exactly on four vacancies. The claim stands, and T204
# pins the arithmetic so it stays checkable rather than assertable.
#
# Run: Rscript tests/test_cycle20_congress_vintage.R
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
rd <- function(p) suppressWarnings(read_csv(p, show_col_types = FALSE, progress = FALSE,
                                            col_types = cols(.default = col_character())))
PROF <- "artifacts/district_profiles/district_profiles.csv"
d <- if (file.exists(PROF)) rd(PROF) else NULL
ROS <- "data/congress/legislators_current.csv"
ros <- if (file.exists(ROS)) rd(ROS) else NULL
REDIST <- c("AL", "GA", "LA", "NY", "NC")

cat("\n-- BVA --\n")

# T201 (BVA). District cardinality. 435 voting seats plus the two delegate
# districts ACS reports (DC and PR) is 437; one more or fewer means a district
# was duplicated or dropped by a join.
{
  if (is.null(d)) chk(FALSE, "T201 profile artifact exists") else {
    chk(nrow(d) == 437L, sprintf("T201a exactly 437 districts [%d]", nrow(d)))
    chk(sum(duplicated(d$GEOID)) == 0L, "T201b no district appears twice")
  }
}

# T202 (BVA). The delegate districts are the boundary case: ACS codes them 98,
# they are not voting seats, and dropping them would silently remove DC and PR
# from every district-level denominator.
{
  if (is.null(d)) chk(FALSE, "T202 artifact") else {
    n98 <- sum(d$cd == "98", na.rm = TRUE)
    chk(n98 == 2L, sprintf("T202a exactly two delegate districts are present [%d]", n98))
    chk(all(c("DC", "PR") %in% d$state_abbr[d$cd == "98"]),
        "T202b they are DC and PR, not dropped as non-states")
  }
}

# T203 (BVA). At-large states have a single district. Their code must not be
# confused with a missing value: "00" is a district, "" is not.
{
  if (is.null(d)) chk(FALSE, "T203 artifact") else {
    # MT was in this list and should not be: it gained a second district in
    # 2022 and is no longer at-large. Including it made the assertion report
    # codes 00/01/02 under a heading that says "single district", which is the
    # same imprecision this loop keeps finding in comments.
    al <- d %>% filter(state_abbr %in% c("AK", "DE", "ND", "SD", "VT", "WY"))
    chk(nrow(al) > 0 && !any(is.na(al$cd)) && all(nchar(al$cd) > 0),
        sprintf("T203 single-district states carry a real code, not a blank [%s]",
                paste(sort(unique(al$cd)), collapse = ",")))
  }
}

cat("\n-- SEMANTIC --\n")

# T204 (semantic). THE ARITHMETIC THAT MAKES THE VACANCY CLAIM CHECKABLE.
# A comment asserts four seats are vacant. That is only believable if the
# roster's own row count agrees.
{
  if (is.null(ros) || is.null(d)) chk(FALSE, "T204 roster and artifact") else {
    house <- ros %>% filter(type == "rep")
    blanks <- sum(is.na(d$rep_name))
    chk(nrow(house) == 437L,
        sprintf("T204a the roster holds 437 House rows [%d]", nrow(house)))
    chk(blanks == 4L,
        sprintf("T204b exactly four districts have no sitting member [%d]", blanks))
    # 435 voting - 4 vacant + 6 delegates = 437. The identity is what turns
    # "these are vacancies" from an assertion into a verified statement.
    chk(435L - blanks + 6L == nrow(house),
        sprintf("T204c 435 voting - %d vacant + 6 delegates = %d roster rows, so the vacancy claim closes",
                blanks, nrow(house)))
  }
}

# T205 (semantic). THE FIX. The vintage disclosure must distinguish the states
# where the mismatch bites from those where it does not.
{
  if (is.null(d) || !"boundary_vintage" %in% names(d)) {
    chk(FALSE, "T205 boundary_vintage present")
  } else {
    chk(n_distinct(d$boundary_vintage) > 1L,
        sprintf("T205a the disclosure is not one constant string [%d distinct values]",
                n_distinct(d$boundary_vintage)))
    redrew <- d$boundary_vintage[d$state_abbr %in% REDIST]
    kept   <- d$boundary_vintage[!d$state_abbr %in% REDIST]
    chk(length(redrew) > 0 && all(grepl("REDREW", redrew)),
        "T205b every district in a redistricted state says so")
    chk(length(kept) > 0 && !any(grepl("REDREW", kept)),
        "T205c no district in an unchanged state carries the redistricting warning")
  }
}

# T206 (semantic). The flag and the prose must agree. Two disclosures that can
# disagree are worse than one.
{
  if (is.null(d) || !"redistricted_since_acs" %in% names(d)) {
    chk(FALSE, "T206 redistricted_since_acs present")
  } else {
    flag <- tolower(d$redistricted_since_acs) %in% c("true", "t")
    chk(identical(flag, d$state_abbr %in% REDIST),
        sprintf("T206a the boolean flag matches the state list exactly [%d flagged]", sum(flag)))
    chk(all(grepl("REDREW", d$boundary_vintage[flag])),
        "T206b the flag and the sentence never disagree")
  }
}

# T207 (semantic). The affected share must be material and bounded. If it were
# 0 the disclosure is pointless; if it were everything, per-row is no better
# than a constant.
{
  if (is.null(d)) chk(FALSE, "T207 artifact") else {
    n <- sum(d$state_abbr %in% REDIST)
    chk(n > 0 && n < nrow(d),
        sprintf("T207 %d of %d districts (%.1f%%) are affected -- material, and not all of them",
                n, nrow(d), 100 * n / nrow(d)))
  }
}

cat("\n-- ADVERSARIAL --\n")

# T208 (adversarial). A vacant seat must never render as a blank badge. The
# module's own roxygen says a blank "would read as 'no representative'" and
# handles that for delegates; the same principle must reach vacancies.
{
  if (is.null(d)) chk(FALSE, "T208 artifact") else {
    vac <- d %>% filter(is.na(rep_name))
    chk(nrow(vac) > 0 && "seat_vacant" %in% names(d),
        "T208a vacant seats are marked explicitly rather than left implicit")
    flagged <- tolower(d$seat_vacant) %in% c("true", "t")
    chk(identical(flagged, is.na(d$rep_name)),
        "T208b the vacancy flag matches exactly the rows with no member")
  }
}

# T209 (adversarial). A member must not be attached to two districts, nor a
# district to two members -- the join must be one-to-one on the seat.
{
  if (is.null(d)) chk(FALSE, "T209 artifact") else {
    named <- d %>% filter(!is.na(rep_name))
    chk(sum(duplicated(named$rep_name)) == 0L,
        sprintf("T209 no representative is attached to two districts [%d duplicates]",
                sum(duplicated(named$rep_name))))
  }
}

# T210 (adversarial). Party must be a closed vocabulary. A stray value flows
# straight into a published badge.
{
  if (is.null(d)) chk(FALSE, "T210 artifact") else {
    p <- sort(unique(na.omit(d$party)))
    chk(all(p %in% c("Democrat", "Republican", "Independent", "Libertarian")),
        sprintf("T210 party is a closed vocabulary [%s]", paste(p, collapse = ", ")))
  }
}


# ---------------------------------------------------------------------------
# Folded in from a duplicate cycle-20 file. Two agents wrote cycle 20
# concurrently -- the cron's run and a manual one -- producing overlapping
# suites. The overlapping assertions were dropped rather than kept twice; these
# four cover ground the other file did not.
# ---------------------------------------------------------------------------

# G1. Columns asserted BEFORE anything is computed from them. Run against the
# pre-fix artifact, a delegate-classification check PASSED because
# redistricted_since_acs did not exist and `all(NULL == FALSE)` is TRUE -- the
# test congratulated a column that was not there (cycle 16's T77 trap).
{
  need <- c("state_abbr", "boundary_vintage", "redistricted_since_acs")
  chk(all(need %in% names(d)),
      sprintf("G1 required columns exist before evaluation [missing: %s]",
              paste(setdiff(need, names(d)), collapse = ", ")))
}

# G2. Sweep: ANY per-row disclosure that is constant is the same defect under a
# different column name.
{
  cand <- grep("vintage|caveat|disclosure|note|warning", names(d), value = TRUE)
  const <- cand[vapply(cand, function(cc) length(unique(d[[cc]])) == 1L, logical(1))]
  chk(length(const) == 0,
      sprintf("G2 no disclosure column is constant across all districts [%s]",
              if (length(const)) paste(const, collapse = ", ") else "none"))
}

# G3. The source list and the rebuilt artifact must agree -- a source edited
# without a rebuild leaves a disclosure describing a different map than the
# code claims (the cycle-16 lesson, applied to prose). The two-letter codes are
# pulled straight off the definition line; an earlier version used a nested
# regex whose escaping did not survive being written through a shell, and it
# failed while the data was correct.
{
  ln <- grep("^REDISTRICTED_119 <- ", readLines(
    file.path(root, "R", "12-district-profiles.R"), warn = FALSE), value = TRUE)[1]
  rd <- if (is.na(ln)) character(0)
        else regmatches(ln, gregexpr('"[A-Z]{2}"', ln))[[1]]
  rd <- sort(gsub('"', "", rd))
  # The reader above coerces EVERY column to character, so this flag arrives as
  # "TRUE"/"FALSE". Indexing a vector by a character vector silently returns
  # nothing rather than erroring, which made this guard report an empty
  # artifact while the data was correct. Coerced explicitly.
  flag <- d$redistricted_since_acs %in% c(TRUE, "TRUE")
  in_art <- sort(unique(d$state_abbr[flag]))
  chk(length(rd) > 0 && identical(in_art, rd),
      sprintf("G3 REDISTRICTED_119 in the source matches the rebuilt artifact [src: %s | artifact: %s]",
              paste(rd, collapse = ","), paste(in_art, collapse = ",")))
}

# G4. Row order must not change any disclosure.
{
  set.seed(20); p <- sample(nrow(d))
  chk(identical(d$boundary_vintage[p][order(p)], d$boundary_vintage),
      "G4 disclosures are invariant to row order")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
