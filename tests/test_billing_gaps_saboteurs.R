#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against interior gap detection
# =============================================================================
# WHY THIS ONE. gap_episodes() is the single definition of what counts as a
# break in a midwife's billing history, shared by three audit scripts so that
# two analyses cannot come to disagree about how many gaps exist. Every
# intermittency figure those scripts publish -- episode counts, the one-year
# and three-or-more-year shares, the rate itself -- is a function of this
# one routine, and it had no tests.
#
# The subtlety it exists to protect is the SPAN rule. A year before a
# midwife's first observation is not a gap: it is indistinguishable from not
# having started. A year after her last is indistinguishable from having
# stopped. Counting either would turn entry and exit into intermittency and
# inflate every published rate, which is exactly the kind of error that
# produces a plausible number nobody can see is wrong. B2 and B3 pin that.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "billing_gaps.R"))

SAB_PREFIX <- "B"
yrs <- function(npi, year) data.frame(npi = npi, year = as.integer(year),
                                      stringsAsFactors = FALSE)

sab(1, "one interior gap is one episode, measured in missing years")
{
  ep <- gap_episodes(yrs("A", c(2015, 2017, 2018)))
  chk(nrow(ep) == 1L, sprintf("one episode [%d]", nrow(ep)))
  # INDEXED, NOT &&. Under a mutation that splits one episode into several,
  # ep has more than one row and `&&` on a length-2 logical aborts the whole
  # suite instead of reporting the failure it just found. The row count is
  # already asserted above, so reading row 1 is safe and the check degrades
  # to a clean FAIL rather than a crash.
  chk(identical(ep$gap_start[1], 2016L) && identical(ep$gap_end[1], 2016L),
      sprintf("spanning 2016 to 2016 [%d-%d]", ep$gap_start[1], ep$gap_end[1]))
  chk(identical(ep$gap_len[1], 1L),
      sprintf("gap_len counts the MISSING year, not the two boundaries [%d]",
              ep$gap_len[1]))
}

sab(2, "THE SPAN RULE: a year before the first observation is not a gap")
{
  # 2013 and 2014 precede this midwife entirely. Counting them would make
  # every late entrant look intermittent and inflate the published rate.
  ep <- gap_episodes(yrs("A", c(2015, 2016, 2017)))
  chk(nrow(ep) == 0L,
      sprintf("a contiguous run has no gaps, however late it starts [%d]",
              nrow(ep)))
}

sab(3, "THE SPAN RULE: a year after the last observation is not a gap")
{
  # Two midwives, same years observed, but the span is each midwife's own.
  # If the span were taken across the cohort, B's absence after 2016 would
  # read as a gap when it is an exit.
  ep <- gap_episodes(rbind(yrs("A", c(2015, 2016, 2017, 2018)),
                           yrs("B", c(2015, 2016))))
  chk(nrow(ep) == 0L,
      sprintf("neither midwife has an interior gap [%d episodes]", nrow(ep)))
}

sab(4, "two separate breaks are two episodes, not one long one")
{
  ep <- gap_episodes(yrs("A", c(2015, 2017, 2019)))
  chk(nrow(ep) == 2L, sprintf("two episodes [%d]", nrow(ep)))
  chk(all(ep$gap_len == 1L), "each one year long")
  chk(identical(sort(ep$gap_start), c(2016L, 2018L)),
      "starting in 2016 and 2018")
}

sab(5, "a run of consecutive missing years is ONE episode of that length")
{
  # The inverse of B4. Splitting a three-year break into three episodes
  # would triple the episode count and halve the mean length.
  ep <- gap_episodes(yrs("A", c(2015, 2019)))
  chk(nrow(ep) == 1L, sprintf("one episode [%d]", nrow(ep)))
  chk(identical(ep$gap_len[1], 3L),
      sprintf("three years long [%d]", ep$gap_len[1]))
  chk(identical(ep$gap_start[1], 2016L) && identical(ep$gap_end[1], 2018L),
      sprintf("2016 through 2018 [%d-%d]", ep$gap_start[1], ep$gap_end[1]))
}

sab(6, "a midwife seen once has no span and so no gap")
{
  ep <- gap_episodes(yrs("A", 2015))
  chk(nrow(ep) == 0L,
      sprintf("one observation cannot bracket anything [%d]", nrow(ep)))
}

sab(7, "a duplicate year neither creates nor closes a gap")
{
  # A source listing a midwife twice in one year is a join artefact, not
  # evidence. Collapsed before the sequence is built.
  with_dupe <- gap_episodes(yrs("A", c(2015, 2015, 2017, 2018)))
  without   <- gap_episodes(yrs("A", c(2015, 2017, 2018)))
  chk(identical(with_dupe, without),
      "the duplicated year changes nothing about the episode")
}

sab(8, "INVERTED: midwives are independent of one another")
{
  # A's gap must not close because B was present that year, and B's
  # presence must not create a gap for A.
  ep <- gap_episodes(rbind(yrs("A", c(2015, 2017)), yrs("B", c(2015, 2016, 2017))))
  chk(nrow(ep) == 1L, sprintf("only A has a gap [%d episodes]", nrow(ep)))
  chk(identical(ep$npi[1], "A"), sprintf("and it belongs to A [%s]", ep$npi[1]))
}

sab(9, "INVERTED: the empty result carries the full schema")
{
  # Three scripts bind this result. A bare data.frame() would drop columns
  # and silently change the shape of whatever it is bound to.
  none <- gap_episodes(yrs("A", c(2015, 2016)))
  some <- gap_episodes(yrs("A", c(2015, 2017)))
  chk(nrow(none) == 0L, "no episodes found")
  chk(identical(names(none), names(some)),
      "the empty result has the same columns as a populated one")
  chk(identical(vapply(none, function(x) class(x)[1], character(1)),
                vapply(some, function(x) class(x)[1], character(1))),
      "and the same column types, so rbind cannot coerce silently")
}

sab(10, "INVERTED: a missing identifier or year is dropped, not guessed")
{
  ep <- gap_episodes(rbind(yrs("A", c(2015, 2017)),
                           yrs(NA_character_, 2016),
                           data.frame(npi = "B", year = NA_integer_,
                                      stringsAsFactors = FALSE)))
  chk(nrow(ep) == 1L,
      sprintf("the NA rows contribute nothing [%d episodes]", nrow(ep)))
  chk(identical(ep$npi[1], "A") && identical(ep$gap_len[1], 1L),
      "and A's gap is unaffected by them")
}

cat(sprintf("\n%s (%d failures across 10 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
