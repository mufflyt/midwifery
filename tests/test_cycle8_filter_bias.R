#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop -- CYCLE 8 (3 BVA / 4 semantic / 3 adversarial)
# =============================================================================
# This cycle audits the loop's OWN work. Cycle 7 fixed a real defect -- the
# "highest fertility" superlative was naming an ACS sampling artifact -- by
# adding GFR_MIN_WOMEN <- 5000, a floor on the denominator. A concurrent review
# measured that filter and found it removed 88.5% of REMOTE counties from the
# ranking (1,160 of 1,311) in a study about rural access.
#
# The filter was more biased than the noise it was correcting. A remote county
# could essentially never be named most fertile, which is a conclusion about
# rurality produced entirely by a threshold.
#
# The general lesson, and the reason T74 exists: A FILTER APPLIED BEFORE A
# RANKING IS PART OF THE ESTIMAND. Any exclusion must be checked for
# differential application along the study's own stratifier, because an
# exclusion that correlates with the exposure manufactures a finding. Nothing in
# this repo checked that, and the loop itself walked into it.
#
# The replacement is a VALIDITY constraint, not a reliability threshold:
# GFR_MAX_PLAUSIBLE <- 200, above the highest national fertility rate ever
# recorded. A county reporting 448.7 births per 1,000 women aged 15-44 is not an
# unusually fertile place; it is an estimate drawn from 156 women. Excluding an
# impossible value is not choosing between defensible readings. It removes 9
# counties rather than 1,583, and 0.7% of remote counties rather than 88.5%.
#
# Run: Rscript tests/test_cycle8_filter_bias.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
suppressPackageStartupMessages({library(dplyr); library(readr)})
source(file.path(root, "R", "lib", "table1_bands.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
SRC_ALL <- readLines(file.path(root, "R", "10-county-birth-profiles.R"), warn = FALSE)
SRC <- paste(SRC_ALL, collapse = "\n")
# CODE ONLY. T73b and T75a first failed by matching this cycle's own roxygen,
# which NAMES the rejected `GFR_MIN_WOMEN <- 5000` in order to explain why it
# was removed. A source-contract test that greps prose fails on its own
# changelog -- the assertion is about what the code DOES, so comment lines are
# stripped before matching.
SRC_CODE <- paste(grep("^\\s*#", SRC_ALL, value = TRUE, invert = TRUE), collapse = "\n")
CB <- suppressWarnings(read_csv(file.path(root, "data", "county_base.csv"),
                                show_col_types = FALSE, progress = FALSE)) %>%
  mutate(rurality = band_rurality(rucc_2023, RURALITY_LABELS_COHORT))
BOUND <- 200

cat("\n-- BVA --\n")

# T71 (BVA). The validity bound is inclusive at 200: a rate exactly at the
# highest recorded national figure is kept, one above it is not.
{
  keep <- function(x) !is.na(x) & x <= BOUND
  chk(keep(199.9) && keep(200) && !keep(200.1),
      "T71a the plausibility bound is inclusive at 200 and excludes just above")
  chk(!keep(NA_real_) && !keep(Inf),
      "T71b a missing or infinite rate is not rankable")
  chk(keep(0),
      "T71c a county with zero births is a valid observation, not an error")
}

# T72 (BVA). The bound removes exactly the demographically impossible values,
# and no more. If this count grows, the data changed, not the rule.
{
  excl <- sum(CB$general_fertility_rate > BOUND, na.rm = TRUE)
  chk(excl == 9L,
      sprintf("T72 the validity bound excludes exactly the 9 impossible counties [got %d]", excl))
}

# T73 (BVA). An excluded county keeps its row and its own rate. Exclusion is
# from the RANKING, not from the dataset -- the county still gets a profile.
{
  chk(grepl("rank_gfr_high\\s*=\\s*mm_rank\\(ifelse\\(gfr_plausible", SRC),
      "T73a only the ranking is filtered, via ifelse inside mm_rank")
  chk(!grepl("filter\\(gfr_plausible\\)|filter\\([^)]*general_fertility_rate <=", SRC_CODE),
      "T73b no county is dropped from the profile table by the bound")
}

cat("\n-- SEMANTIC --\n")

# T74 (semantic). THE CONTRACT THIS CYCLE EXISTS FOR. Any exclusion applied
# before a ranking must not fall differentially on the study's own stratifier.
# Rurality IS the exposure here; an exclusion correlated with it manufactures a
# conclusion about rurality out of a threshold.
{
  rate_by_rurality <- function(excl) {
    CB %>% mutate(ex = excl) %>% filter(!is.na(rurality)) %>%
      group_by(rurality) %>%
      summarise(pct = 100 * sum(ex, na.rm = TRUE) / n(), .groups = "drop")
  }
  now <- rate_by_rurality(!is.na(CB$general_fertility_rate) &
                            CB$general_fertility_rate > BOUND)
  spread_now <- max(now$pct) - min(now$pct)
  chk(spread_now < 5,
      sprintf("T74a the live exclusion is near-uniform across rurality [spread %.1f pp: %s]",
              spread_now, paste(sprintf("%s %.1f%%", substr(now$rurality, 1, 12), now$pct),
                                collapse = ", ")))

  # The rejected filter must FAIL this test, or the contract is decoration.
  old <- rate_by_rurality(is.na(CB$women_15_44) | CB$women_15_44 < 5000)
  chk((max(old$pct) - min(old$pct)) > 50,
      sprintf("T74b the rejected denominator floor is correctly detected as biased [spread %.1f pp]",
              max(old$pct) - min(old$pct)))
}

# T75 (semantic). Validity is not reliability, and the code must say which it
# is doing. A bound on what is possible is a fact; a floor on precision is a
# scientific choice this loop is not permitted to make alone.
{
  chk(grepl("GFR_MAX_PLAUSIBLE", SRC_CODE) && !grepl("GFR_MIN_WOMEN\\s*<-", SRC_CODE),
      "T75a the denominator floor is gone, replaced by a plausibility bound")
  chk(grepl("VALIDITY constraint", SRC) && grepl("RELIABILITY", SRC),
      "T75b the code distinguishes the validity constraint it applies from the reliability question it leaves open")
}

# T76 (semantic). The bound must be above every real fertility rate ever
# observed nationally, or it is a reliability threshold wearing a validity
# costume.
{
  chk(BOUND >= 150,
      "T76a the bound sits above the highest recorded national GFR (~150-200)")
  ranked <- CB$general_fertility_rate[!is.na(CB$general_fertility_rate) &
                                        CB$general_fertility_rate <= BOUND]
  chk(max(ranked) > 100,
      sprintf("T76b genuinely high-fertility counties remain rankable [max kept %.1f]",
              max(ranked)))
}

# T77 (semantic). The mitigating claim from the review -- that midwife-supply
# conclusions are barely affected -- must be asserted, not assumed. If a filter
# ever starts removing counties where midwives actually practise, the whole
# argument for tolerating it collapses.
{
  if (!"midwives_total" %in% names(CB) && !"n_midwives" %in% names(CB)) {
    cat("  skip T77 no midwife count column in county_base\n")
  } else {
    mc <- if ("midwives_total" %in% names(CB)) CB$midwives_total else CB$n_midwives
    ex <- !is.na(CB$general_fertility_rate) & CB$general_fertility_rate > BOUND
    lost <- sum(mc[ex], na.rm = TRUE); tot <- sum(mc, na.rm = TRUE)
    chk(tot > 0 && 100 * lost / tot < 1,
        sprintf("T77 excluded counties hold a negligible share of midwives [%d of %d, %.2f%%]",
                lost, tot, 100 * lost / max(tot, 1)))
  }
}

cat("\n-- ADVERSARIAL --\n")

# T78 (adversarial). The rejected filter must not creep back, in any spelling.
{
  files <- list.files(file.path(root, "R"), pattern = "\\.R$",
                      recursive = TRUE, full.names = TRUE)
  revived <- Filter(function(f)
    any(grepl("women_15_44\\s*(>=|<)\\s*[0-9]{3,}", readLines(f, warn = FALSE))), files)
  chk(length(revived) == 0L,
      sprintf("T78 no denominator-size floor on women_15_44 has returned [%s]",
              if (length(revived)) paste(basename(revived), collapse = ", ") else "none"))
}

# T79 (adversarial). Excluding a value from a ranking must not renumber the
# survivors' ranks in a way that invents a tie or drops a rank.
{
  x <- c(120, 110, 110, 448, 90)
  keep <- x <= BOUND
  r <- rank(-x[keep], ties.method = "min")
  chk(identical(as.integer(r), c(1L, 2L, 2L, 4L)),
      sprintf("T79 ties share a rank and the next rank skips accordingly [%s]",
              paste(r, collapse = ",")))
}

# T80 (adversarial). Row order must not change any rank. The profile table is
# rebuilt from several joins, so its row order is not stable across runs.
{
  d <- CB %>% filter(!is.na(general_fertility_rate)) %>%
    mutate(g = ifelse(general_fertility_rate <= BOUND, general_fertility_rate, NA_real_))
  r1 <- d %>% arrange(GEOID) %>% mutate(rk = rank(-g, na.last = "keep", ties.method = "min"))
  r2 <- d %>% arrange(desc(GEOID)) %>% mutate(rk = rank(-g, na.last = "keep", ties.method = "min")) %>%
    arrange(GEOID)
  chk(identical(r1$rk, r2$rk),
      "T80 ranks are invariant to the order the counties arrive in")
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
