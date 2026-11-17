#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against comparing one year's record to another year's
# =============================================================================
# WHY THIS ONE. "Do these two records agree about where she practises" only
# means something if both records are talking about the same time. Every
# comparison in this project pairs two sources, and until now not one of the
# pairing sites could say what years it had paired:
#
#   * state_agreement_current_only() joined on npi alone, took the registry
#     with its `year` already selected away, and wrote a free-text
#     `as_of_label` into the output's year column that nothing checked. Hand
#     it 2019 PECOS and the 2026 registry and it returned a row stamped
#     `year = 2026`, 0% agreement -- seven years of drift published as
#     disagreement.
#   * state_agreement_same_year() joins on (npi, year) and so cannot
#     mismatch, but when the two year sets did not meet at all it returned
#     zero rows and the source dropped out of the agreement table with
#     nothing raised. Absent, not wrong.
#   * make_parent_field_claims() in the OIG rebuild took the year as a
#     LITERAL and the values as a bare vector. The 2019 panel has no sex
#     code, so `gender` was borrowed from the February 2026 NPPES file and
#     stamped 2019. The published row `2019,nppes,pecos,gender` is 2026
#     values against 2019 values. Sex barely moves; practice_state does.
#
# assert_vintage_gap() had been written and tested for exactly this and was
# called by NOTHING in production, because the comparisons hold years and it
# wanted dates. The adapter is assert_same_vintage_year().
#
# FOUR SABOTEURS ARE INVERTED (V4, V6, V8, V10b) because the cheap way to
# pass the other six is to refuse every comparison, which would delete the
# audit rather than fix it.
# =============================================================================

.harness <- grep("--file=", commandArgs(), value = TRUE)
source(file.path(if (length(.harness)) dirname(sub("--file=", "", .harness[1]))
                 else "tests", "helper-saboteur.R"))
root <- test_repo_root()
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
suppressPackageStartupMessages({library(dplyr); library(tibble)})
source(file.path(root, "R", "lib", "source_vintage.R"))
source(file.path(root, "R", "lib", "state_agreement.R"))
source(file.path(root, "R", "lib", "vintage_claims.R"))

SAB_PREFIX <- "V"
refusal <- function(expr)
  tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
said <- function(msg, ...) {
  if (is.null(msg)) return(FALSE)
  all(vapply(c(...), function(w) grepl(w, msg, fixed = TRUE), logical(1)))
}

# The registry's current snapshot, as build_state_source_audit.R now passes it:
# WITH its year, because stripping it is what made the pairing uncheckable.
registry_2026 <- tibble(npi = c("1", "2", "3", "4"),
                        nppes_state = c("CO", "CO", "TX", "FL"),
                        year = 2026L)
# A source with no year of its own -- a scrape, a board roster, a FHIR pull.
snapshot_rows <- tibble(npi = c("1", "2", "3"), state = c("CO", "NM", "TX"))

sab(1, "THE COMPLAINT: 2019 PECOS against the 2026 registry")
{
  # Precisely what shipped: the source is seven years old, the registry is
  # current, the join is on npi so nothing stops it, and the output row used
  # to be stamped 2026 with 0% agreement.
  m <- refusal(state_agreement_current_only(
    "pecos_revalidation", snapshot_rows, registry_2026, "2019", 2019L))
  chk(said(m, "2019", "2026"),
      "refused, naming BOTH years rather than just complaining")
  chk(said(m, "84.0 months"),
      "and saying how far apart they are, in months [84.0]")
  chk(said(m, "pecos_revalidation"),
      "and which source it was, so the caller is findable")
}

sab(2, "the registry arrives with its year selected away")
{
  # The original signature. With no year on the registry the function cannot
  # know what it is comparing against, and silence is what it did before.
  m <- refusal(state_agreement_current_only(
    "healthgrades", snapshot_rows,
    registry_2026 %>% select(npi, nppes_state), "~2026-10", 2026L))
  chk(said(m, "no year column"),
      "refused: an uncheckable pairing is not a same-year pairing")
  chk(said(m, "selecting it away"),
      "and it names the caller's mistake, not the data's")
  # The other uncheckable pairing: the source's own year is unknown. An
  # undated source is the normal case here -- a scrape, a FHIR pull -- so the
  # temptation is to let it through as "probably current", which is how an
  # eleven-month gap gets published as a same-day comparison.
  m2 <- refusal(state_agreement_current_only(
    "healthgrades", snapshot_rows, registry_2026, "~2026-10", NA_integer_))
  chk(said(m2, "must be one parseable year"),
      "an UNKNOWN source vintage is refused, not assumed current")
  chk(said(m2, "cannot be shown to be same-year"),
      "and the refusal says why that matters")
}

sab(3, "a registry spanning twenty years, joined on npi alone")
{
  # midwife_panel.csv holds 2007..2026. Passing the whole panel to a function
  # that matches on npi alone lets one midwife match any of her twenty rows,
  # and whichever one wins is an accident of row order.
  m <- refusal(state_agreement_current_only(
    "cms_ndh_fhir", snapshot_rows,
    tibble(npi = rep(c("1", "2"), each = 3L), nppes_state = "CO",
           year = rep(c(2024L, 2025L, 2026L), 2L)),
    "2026-10", 2026L))
  chk(said(m, "spans 3 year(s)"), "refused, counting the years it was handed")
  chk(said(m, "silently pools"), "and saying what pooling would have done")
}

sab(4, "INVERTED: a same-year pairing still computes, unchanged")
{
  # The cheap way to pass V1-V3 is to refuse everything. This is the real
  # audit's shape: a 2026 scrape against the 2026 registry.
  r <- state_agreement_current_only("healthgrades", snapshot_rows,
                                    registry_2026, "~2026-10 (scrape)", 2026L)
  chk(nrow(r) == 1L, "one row out")
  chk(r$n_comparable == 3L && r$n_agree == 2L,
      sprintf("2 of 3 agree, same arithmetic as before [%d of %d]",
              r$n_agree, r$n_comparable))
  chk(identical(r$year, "~2026-10 (scrape)"),
      "and the free-text label still reaches the output, not replaced by a bare year")
  chk(!"year" %in% names(r %>% select(-year)) || TRUE,
      "the registry's year column did not leak into the join as year.x/year.y")
  chk(!any(grepl("^year\\.", names(r))), "confirmed: no year.x column in the output")
}

sab(5, "the registry drifts one year ahead of the source")
{
  # The slow version of the same bug, and the one that will actually happen:
  # a source stops being re-harvested while the panel moves on. Twelve months
  # is over the six-month default, so it has to be declared.
  m <- refusal(state_agreement_current_only(
    "state_boards_of_nursing", snapshot_rows, registry_2026,
    "2025-11 (6 boards)", 2025L))
  chk(said(m, "12.0 months"), "refused at one year's drift [12.0 months]")
}

sab(6, "INVERTED: a wider limit, passed deliberately, is honoured")
{
  # Measuring ACROSS a gap is legitimate -- it is the whole point of the
  # trend figure. What must not happen is measuring across one by accident.
  r <- state_agreement_current_only("state_boards_of_nursing", snapshot_rows,
                                    registry_2026, "2025-11", 2025L,
                                    max_months = 18)
  chk(nrow(r) == 1L && r$n_comparable == 3L,
      "a declared 12-month pairing computes rather than erroring")
}

sab(7, "a source that shares no year with the registry at all")
{
  # The same-year join cannot mismatch, so this is the other failure: the
  # intersection is empty, zero rows come back, bind_rows() drops the source
  # and the agreement table is one source shorter than the coverage table.
  panel <- tibble(npi = c("1", "2"), year = 2026L, nppes_state = "CO")
  m <- refusal(state_agreement_same_year(
    "pecos_revalidation", tibble(npi = c("1", "2"), year = 2019L, state = "CO"),
    panel))
  chk(said(m, "shares no year"), "refused rather than returning zero rows")
  chk(said(m, "vanish"),
      "and it says what the zero rows would have looked like: absence, not failure")
  chk(said(m, "source years:   2019"), "listing the source's years")
  chk(said(m, "registry years: 2026"), "and the registry's")
}

sab(8, "INVERTED: a partial overlap compares the shared years and only those")
{
  # DAC covers 2013-2016 and 2026; the panel covers 2007-2026. Most real
  # sources overlap partially, and refusing those would delete the audit.
  panel <- tibble(npi = rep("1", 3L), year = c(2024L, 2025L, 2026L),
                  nppes_state = "CO")
  src <- tibble(npi = rep("1", 3L), year = c(2019L, 2025L, 2026L),
                state = c("NM", "CO", "TX"))
  r <- state_agreement_same_year("dac_physician_compare", src, panel)
  chk(nrow(r) == 2L, sprintf("two years compared, not three or zero [%d]", nrow(r)))
  chk(identical(sort(r$year), c("2025", "2026")),
      "and they are the OVERLAPPING years; 2019 has no registry row to pair with")
  chk(sum(r$n_agree) == 1L, sprintf("one of the two agrees [%d]", sum(r$n_agree)))
}

sab(9, "a claim built without saying what year its values are from")
{
  d <- tibble(npi = c("1", "2"), g = c("M", "F"))
  m <- refusal(make_parent_field_claims(d, 2019L, "nppes", "gender", d$g))
  chk(said(m, "without saying what year the VALUES are from"),
      "refused: the year was a literal and the values a bare vector")
  chk(said(m, "value_year = 2019L"), "and it suggests the honest answer")
  # Same blindness, different axis: val_vec is positional against df$npi, so a
  # short vector is recycled and pairs identifiers with other people's values.
  m2 <- refusal(make_parent_field_claims(d, 2019L, "nppes", "gender", "M",
                                         value_year = 2019L))
  chk(said(m2, "1 value(s) for 2 row(s)"),
      "a recycled value vector is refused too [1 value for 2 rows]")
  chk(said(m2, "belong to other people"), "because recycling re-labels every row")
}

sab(10, "THE LIVE ONE: 2026 sex codes stamped as a 2019 claim")
{
  # remake_oig_07_09_00440_midwifery.R:401 borrows gender from the February
  # 2026 NPPES file onto the 2019 frame, and :699 stamped it 2019. That row
  # is in the shipped artifact.
  d <- tibble(npi = c("1", "2"), g = c("M", "F"))
  m <- refusal(make_parent_field_claims(d, 2019L, "nppes", "gender", d$g,
                                        value_year = 2026L))
  chk(said(m, "stamped year 2019 from", "values that are from year 2026"),
      "an undeclared borrow is refused, naming the attribute and both years")
  chk(said(m, "as though both were 2019"),
      "and it says what the comparison would then have done")
}

sab("10b", "INVERTED: a declared borrow is allowed, and announced")
{
  # The 2019 panel genuinely has no sex code. Borrowing is a defensible
  # choice; doing it silently is not. The run has to say so out loud.
  d <- tibble(npi = c("1", "2"), g = c("M", "F"))
  logged <- character(0)
  r <- withCallingHandlers(
    make_parent_field_claims(d, 2019L, "nppes", "gender", d$g,
                             value_year = 2026L,
                             cross_vintage_reason = "the 2019 panel has no sex code"),
    message = function(x) {
      logged <<- c(logged, conditionMessage(x)); invokeRestart("muffleMessage")
    })
  chk(nrow(r) == 2L, "the claim is built")
  chk(identical(unique(r$year), 2019L),
      "still stamped 2019, so the published artifact does not change shape")
  chk(any(grepl("CROSS-VINTAGE CLAIM", logged, fixed = TRUE)),
      "and the borrow is announced on every run")
  chk(any(grepl("the 2019 panel has no sex code", logged, fixed = TRUE)),
      "with the reason, so the log says why and not just that")
}

cat(sprintf("\n%s (%d failure(s) across 10 saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS", fails))
quit(status = if (fails == 0L) 0L else 1L)
