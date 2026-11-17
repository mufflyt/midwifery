#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against the agreement arithmetic
# =============================================================================
# WHY THIS ONE. These three functions produce every published agreement
# percentage in the state-source audit: Table 5 and Figure 4 of the
# manuscript, Section 3 of the technical appendix, and the fitted trend that
# the paper reports as 0.25 points a year. Until now they lived inside
# build_state_source_audit.R, closed over the registry from the enclosing
# script, so nothing could call them without running the whole audit and
# nothing ever did.
#
# A2 is the one that found something. n_comparable counts ROWS. Open Payments
# 2025 holds 21,890 payment records for 4,324 midwives -- one midwife appears
# 127 times -- so the percentage is weighted by payment volume, not by
# person, and the appendix describes that source's coverage in NPI-years,
# which these numbers are not. The behaviour is now pinned and reported
# beside a distinct-identifier count, so the weighting is visible rather
# than implied.
# =============================================================================

.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path(root, "R", "lib", "state_agreement.R"))

SAB_PREFIX <- "A"

registry <- tibble(npi = c("1", "2", "3", "4"), year = rep(2025L, 4),
                   nppes_state = c("CO", "TX", "FL", NA))
# The current snapshot now carries its own year, because
# state_agreement_current_only() has to check the pairing rather than take
# the caller's word for it -- see tests/test_cross_vintage_pairing_saboteurs.R.
registry_now <- tibble(npi = c("1", "2", "3"),
                       nppes_state = c("CO", "TX", "FL"), year = 2026L)

sab(1, "the plain case: three midwives, one disagrees")
{
  src <- tibble(npi = c("1", "2", "3"), year = rep(2025L, 3),
                state = c("CO", "TX", "NM"))
  r <- state_agreement_same_year("fixture", src, registry)
  chk(r$n_comparable == 3L && r$n_agree == 2L,
      sprintf("2 of 3 agree [%d of %d]", r$n_agree, r$n_comparable))
  chk(identical(r$pct_agree, 66.7), sprintf("66.7%% [%s]", r$pct_agree))
}

sab(2, "THE WEIGHTING: one prolific midwife counts many times")
{
  # Open Payments gives one midwife up to 127 rows in a year. Each one
  # counts. A single busy disagreer can move the published percentage more
  # than a hundred quiet midwives who agree.
  src <- tibble(npi = c(rep("1", 9), "2"), year = rep(2025L, 10),
                state = c(rep("NM", 9), "TX"))
  r <- state_agreement_same_year("fixture", src, registry)
  chk(r$n_comparable == 10L,
      sprintf("ten ROWS are compared, not two midwives [%d]", r$n_comparable))
  chk(r$n_npis_comparable == 2L,
      sprintf("and the distinct-midwife count is reported beside it [%d]",
              r$n_npis_comparable))
  chk(identical(r$pct_agree, 10),
      sprintf("one midwife's nine rows drag agreement to %s%%", r$pct_agree))
}

sab(3, "a row the registry cannot match is dropped, not counted as disagreeing")
{
  # An inner join. A midwife absent from the registry for that year leaves
  # the comparison entirely; she must not inflate the denominator as though
  # she had been checked and failed.
  src <- tibble(npi = c("1", "2", "99"), year = rep(2025L, 3),
                state = c("CO", "TX", "CO"))
  r <- state_agreement_same_year("fixture", src, registry)
  chk(r$n_comparable == 2L,
      sprintf("the unmatched midwife is absent, not a failure [%d]",
              r$n_comparable))
  chk(identical(r$pct_agree, 100), "so agreement is 100%, not 66.7%")
}

sab(4, "a missing state on either side leaves the comparison")
{
  # npi 4 is in the registry with NA. Comparing against NA would make every
  # such row a silent disagreement.
  src <- tibble(npi = c("1", "4"), year = rep(2025L, 2),
                state = c("CO", "CO"))
  r <- state_agreement_same_year("fixture", src, registry)
  chk(r$n_comparable == 1L,
      sprintf("the NA-state row is excluded [%d comparable]", r$n_comparable))
  chk(identical(r$pct_agree, 100), "and does not count as a disagreement")

  src2 <- tibble(npi = c("1", "2"), year = rep(2025L, 2),
                 state = c("CO", NA))
  chk(state_agreement_same_year("fixture", src2, registry)$n_comparable == 1L,
      "the same holds when the SOURCE is the one missing a state")
}

sab(5, "years are matched, never pooled")
{
  # The whole point of same_year. A 2024 source row compared against a 2025
  # registry row would manufacture agreement or disagreement out of a
  # genuine move.
  src <- tibble(npi = c("1", "1"), year = c(2024L, 2025L),
                state = c("NM", "CO"))
  r <- state_agreement_same_year("fixture", src, registry)
  chk(nrow(r) == 1L && r$year == "2025",
      sprintf("only the year present in both is reported [%s]",
              paste(r$year, collapse = ",")))
  chk(r$n_comparable == 1L, "the 2024 row finds no 2025 partner and drops")
}

sab(6, "a duplicated registry row is refused, not silently doubled")
{
  # relationship = "many-to-one" is a contract. If the registry ever held
  # two rows for one midwife-year, every source row would match twice and
  # both counts would inflate with nothing failing.
  bad_registry <- bind_rows(registry,
                            tibble(npi = "1", year = 2025L, nppes_state = "NM"))
  src <- tibble(npi = "1", year = 2025L, state = "CO")
  erred <- tryCatch({ state_agreement_same_year("fixture", src, bad_registry); FALSE },
                    error = function(e) TRUE)
  chk(isTRUE(erred),
      "a duplicate registry row raises rather than double-counting")
}

sab(7, "INVERTED: perfect and total disagreement both report honestly")
{
  # A function that always returned a plausible middling number would pass a
  # careless suite. These two pin the ends of the scale.
  all_agree <- tibble(npi = c("1", "2"), year = rep(2025L, 2),
                      state = c("CO", "TX"))
  none_agree <- tibble(npi = c("1", "2"), year = rep(2025L, 2),
                       state = c("NM", "NM"))
  chk(identical(state_agreement_same_year("f", all_agree, registry)$pct_agree, 100),
      "total agreement is 100, not 99.9")
  chk(identical(state_agreement_same_year("f", none_agree, registry)$pct_agree, 0),
      "total disagreement is 0, not NA")
}

sab(8, "nothing comparable reports NA, not NaN and not zero")
{
  # 0/0 is NaN. Printed in a table it reads as a failed computation; worse,
  # a reader may take it for zero agreement. NA is the honest value.
  empty <- tibble(npi = character(0), state = character(0))
  r <- state_agreement_current_only("fixture", empty, registry_now, "2026", 2026L)
  chk(r$n_comparable == 0L, "no comparable rows")
  chk(is.na(r$pct_agree) && !is.nan(r$pct_agree),
      sprintf("the percentage is NA, not NaN [%s]", r$pct_agree))
}

sab(9, "the snapshot comparison matches on identifier alone")
{
  src <- tibble(npi = c("1", "2", "3"), state = c("CO", "NM", "FL"))
  r <- state_agreement_current_only("fixture", src, registry_now, "2026-11", 2026L)
  chk(r$n_comparable == 3L && r$n_agree == 2L,
      sprintf("2 of 3 [%d of %d]", r$n_agree, r$n_comparable))
  chk(identical(r$year, "2026-11"),
      "the label is carried through to the year column verbatim")
  chk(identical(r$comparison_basis, "current_only"),
      "and the basis says which comparison this was")
}

sab(10, "INVERTED: coverage counts rows and people separately")
{
  # add_coverage feeds Figure 1 and the coverage table. Collapsing its two
  # counts into one would hide exactly the multiplicity A2 is about.
  src <- tibble(npi = c("1", "1", "2"), year = rep(2025L, 3))
  r <- add_coverage("fixture", src)
  chk(r$n_rows == 3L, sprintf("three rows [%d]", r$n_rows))
  chk(r$n_npis == 2L, sprintf("two midwives [%d]", r$n_npis))
  chk(r$n_rows != r$n_npis,
      "and the two are genuinely different numbers, not one copied twice")
}

cat(sprintf("\n%s (%d failures across 10 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
