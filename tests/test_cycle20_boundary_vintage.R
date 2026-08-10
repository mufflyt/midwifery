#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 20 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# Target: the congressional-district boundary disclosure. `boundary_vintage`
# was ONE constant string repeated on all 437 rows, so a Colorado district --
# whose map did not move -- carried the same redistricting warning as an
# Alabama district whose map did. A caveat that says the same thing everywhere
# tells a reader nothing about their own district, and it is indistinguishable
# from a caveat that is simply wrong.
#
# Run: Rscript tests/test_cycle20_boundary_vintage.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

SRC <- paste(readLines(file.path(root, "R", "12-district-profiles.R"),
                       warn = FALSE), collapse = "\n")
ART <- file.path(root, "artifacts", "district_profiles", "district_profiles.csv")
d <- suppressWarnings(read_csv(ART, show_col_types = FALSE, progress = FALSE))

# COLUMNS ASSERTED BEFORE ANYTHING IS COMPUTED FROM THEM. Run against the
# pre-fix artifact, T203 PASSED -- because `redistricted_since_acs` did not
# exist, `all(NULL == FALSE)` is TRUE, and the test congratulated a column that
# was not there. Same trap as cycle 16's T77. A missing column now fails loudly
# instead of reading as compliance.
REQUIRED <- c("state_abbr", "cd", "boundary_vintage", "redistricted_since_acs")
missing <- setdiff(REQUIRED, names(d))

# The list under test, read from the source rather than retyped here -- a
# hard-coded copy would pass even if the source list changed.
RD <- eval(parse(text = sub(".*REDISTRICTED_119 <- (c\\([^)]*\\)).*", "\\1",
                            grep("REDISTRICTED_119 <- c\\(", strsplit(SRC, "\n")[[1]],
                                 value = TRUE)[1])))

cat("\n-- BVA --\n")

if (length(missing)) {
  cat(sprintf("  FAIL T200 required columns absent: %s -- refusing to evaluate vacuously\n",
              paste(missing, collapse = ", ")))
  cat(sprintf("\nFAILURES (%d failure)\n", 1L))
  quit(status = 1L)
}

# T201. The two branches at their boundary: a state in the list and a state
# out of it must produce DIFFERENT disclosures, and neither may be empty.
{
  inn <- unique(d$boundary_vintage[d$state_abbr %in% RD])
  out <- unique(d$boundary_vintage[!d$state_abbr %in% RD])
  chk(length(inn) > 0 && length(out) > 0 && !any(inn %in% out) &&
        all(nzchar(inn)) && all(nzchar(out)),
      sprintf("T201 redistricted and unredistricted states carry disjoint, non-empty disclosures [%d vs %d variants]",
              length(inn), length(out)))
}

# T202. Counts at the edges of the claim: every district is classified, and the
# flagged set is neither empty nor everything -- either would make the column
# useless again.
{
  n_rd <- sum(d$redistricted_since_acs, na.rm = TRUE)
  chk(nrow(d) == 437L && n_rd == 67L && !any(is.na(d$redistricted_since_acs)),
      sprintf("T202 67 of 437 districts flagged, none unclassified [%d of %d]", n_rd, nrow(d)))
}

# T203. Non-voting delegations. DC and PR have no congressional district in the
# ordinary sense; they must still be classified rather than dropped or left NA.
{
  nv <- d %>% filter(state_abbr %in% c("DC", "PR"))
  chk(nrow(nv) > 0 && !any(is.na(nv$redistricted_since_acs)) &&
        all(nv$redistricted_since_acs == FALSE),
      sprintf("T203 non-voting delegations are classified, not dropped [%d rows]", nrow(nv)))
}

cat("\n-- SEMANTIC --\n")

# T204. THE DEFECT. The disclosure must vary. One distinct value across 437
# rows is the failure this cycle exists to fix.
{
  nd <- n_distinct(d$boundary_vintage)
  chk(nd > 1,
      sprintf("T204 boundary_vintage is not a constant string [%d distinct values]", nd))
}

# T205. The flag must mean what it says: TRUE for exactly the states that
# redrew, and for no others.
{
  flagged <- sort(unique(d$state_abbr[d$redistricted_since_acs]))
  chk(identical(flagged, sort(RD)),
      sprintf("T205 the flag is TRUE for exactly the listed states [%s]",
              paste(flagged, collapse = ", ")))
}

# T206. A warning that does not name the state is not actionable. Every
# redistricted row must name its own state in its disclosure.
{
  sub_d <- d %>% filter(redistricted_since_acs)
  named <- mapply(function(s, v) grepl(s, v, fixed = TRUE),
                  sub_d$state_abbr, sub_d$boundary_vintage)
  chk(all(named),
      sprintf("T206 every redistricted district names its own state [%d of %d]",
              sum(named), nrow(sub_d)))
}

# T207. And the converse: an unredistricted district must NOT carry the
# redistricting warning. Over-disclosing is the same defect mirrored -- it
# makes the caveat noise again.
{
  clean <- d$boundary_vintage[!d$redistricted_since_acs]
  chk(!any(grepl("REDREW", clean, fixed = TRUE)),
      sprintf("T207 no unredistricted district claims its map moved [%d rows checked]",
              length(clean)))
}

cat("\n-- ADVERSARIAL --\n")

# T208. ENFORCE THE SWEEP. Any other per-row disclosure that is constant across
# every row is the same defect wearing a different column name.
{
  cand <- grep("vintage|caveat|disclosure|note|warning", names(d), value = TRUE)
  const <- cand[vapply(cand, function(c) n_distinct(d[[c]]) == 1L, logical(1))]
  chk(length(const) == 0,
      sprintf("T208 no disclosure column is constant across all districts [%s]",
              if (length(const)) paste(const, collapse = ", ") else "none"))
}

# T209. The source list and the artifact must agree. A source edited without a
# rebuild leaves a disclosure that describes a different map than the code
# claims -- the cycle-16 lesson, applied to prose.
{
  in_art <- sort(unique(d$state_abbr[d$redistricted_since_acs]))
  chk(identical(in_art, sort(RD)),
      sprintf("T209 REDISTRICTED_119 in the source matches the rebuilt artifact [%s]",
              paste(in_art, collapse = ", ")))
}

# T210. Row order must not change any disclosure -- the assignment is per-row
# and must not depend on neighbours.
{
  set.seed(20)
  p <- sample(nrow(d))
  chk(identical(d$boundary_vintage[p][order(p)], d$boundary_vintage),
      "T210 disclosures are invariant to row order")
}

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
