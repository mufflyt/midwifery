#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against state cleaning: the variable the paper says to trust
# =============================================================================
# WHY THIS ONE. The manuscript's central claim is that practice STATE is the
# only geographic variable in these databases consistent enough to support
# research. Every number behind that claim passes through clean_state(),
# which maps anything it does not recognise to NA and says nothing. The
# function is four lines long and twenty-six files depend on it.
#
# The failure it invites is the one this repository keeps finding: a source
# changes format from "CO" to "Colorado", every row is refused, the audit
# publishes a much smaller n, and nothing fails. C4 is that case.
#
# C5 pins a real exclusion found while writing these: the 2026 registry panel
# carries 456 providers with a military postal code (AE 285, AP 162, AA 9),
# and they leave every state comparison in the paper. That they leave is
# defensible -- Armed Forces Europe is not a US practice state. That they
# left silently was not.
# =============================================================================

.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "clean_state.R"))

SAB_PREFIX <- "C"
quiet <- function(expr) suppressMessages(expr)

sab(1, "case and whitespace as every real extract delivers them")
{
  chk(identical(clean_state(c("co", "Co", " CO ", "\tco\n")),
                rep("CO", 4)),
      "lower, mixed and padded all normalize to one code")
}

sab(2, "a spelled-out jurisdiction resolves to its code")
{
  # THIS TEST ONCE PINNED THE OPPOSITE. It asserted that "Colorado" must be
  # NA, on the reasoning that a name compared against a code would read as
  # disagreement. The reasoning was right and the remedy was wrong: refusing
  # by discarding lost places the pipeline means to include. The registry
  # panel spells "PUERTO RICO" 184 times and PR is an accepted jurisdiction,
  # so those rows were dropped for their spelling, not their geography.
  # Resolving the name to its code satisfies the original concern properly --
  # "Colorado" and "CO" now compare equal instead of both being lost.
  chk(identical(clean_state("Colorado"), "CO"), "a state name becomes its code")
  chk(identical(clean_state("PUERTO RICO"), "PR"),
      "a territory the pipeline accepts is no longer lost to its spelling")
  chk(identical(clean_state("Pennsylvania"), "PA"),
      "which is what the licensing portal returns")
  chk(identical(clean_state("District of Columbia"), "DC"),
      "and the District resolves too")
  chk(!identical(clean_state("Colorado"), "COLORADO"),
      "the name is never passed through as though it were a code")
}

sab(3, "a code that is not a state")
{
  chk(is.na(clean_state("XX")), "a two-letter non-state is NA")
  chk(is.na(clean_state("ALBERTA")),
      "a Canadian province is NA even spelled out, because it is not in scope")
  chk(is.na(clean_state("GERMANY")), "and so is a country")
  chk(is.na(clean_state("AB")), "and so is its code")
  chk(is.na(clean_state("80204")), "a ZIP in the state column is NA")
}

sab(4, "THE CATASTROPHIC CASE: a source switches from codes to names")
{
  # This is the glob defect wearing different clothes. Every value refused,
  # a far smaller n published, nothing failed. report_state_cleaning() now
  # refuses to let that pass.
  # Spelled-out US states now resolve, so the catastrophic case is a source
  # that switches to something genuinely unrecognisable: a foreign scheme, a
  # shifted column, a numeric code.
  switched <- c("ONTARIO", "QUEBEC", "BAVARIA", "99", "ZZ")
  r <- quiet(clean_state_report(switched))
  chk(r$n_kept == 0L && r$n_unrecognised == 5L,
      sprintf("all five refused [kept %d]", r$n_kept))
  stopped <- tryCatch({
    quiet(report_state_cleaning(switched, "fixture")); FALSE
  }, error = function(e) grepl("100%|format change", conditionMessage(e)))
  chk(isTRUE(stopped),
      "and the build STOPS rather than publishing a source with no states")
  # The variant that used to be catastrophic must now simply work.
  names_only <- c("Colorado", "Texas", "Florida", "Illinois", "New York")
  rn <- quiet(clean_state_report(names_only))
  chk(rn$n_kept == 5L,
      sprintf("a source that writes names instead of codes now survives [%d]",
              rn$n_kept))
}

sab(5, "military postal codes leave, and are counted on the way out")
{
  mixed <- c("CO", "CO", "AE", "AP", "AA", "TX")
  r <- quiet(clean_state_report(mixed))
  chk(r$n_military == 3L, sprintf("AA, AE and AP counted as military [%d]",
                                  r$n_military))
  chk(r$n_kept == 3L, sprintf("the real states still kept [%d]", r$n_kept))
  chk(all(is.na(clean_state(c("AE", "AP", "AA")))),
      "and none of them enters a comparison as a state")
}

sab(6, "a partial wipeout is reported but does not stop the build")
{
  # Losing some values is normal. Losing all of them is not. Only the second
  # is fatal, or every source with one bad row would halt the audit.
  partial <- c("CO", "TX", "GERMANY", "XX", "", NA)
  r <- tryCatch(quiet(report_state_cleaning(partial, "fixture")),
                error = function(e) e)
  chk(!inherits(r, "error"), "a source with some bad values still runs")
  chk(r$n_kept == 2L && r$n_unrecognised == 2L && r$n_blank == 2L,
      sprintf("counted 2 kept, 2 refused, 2 blank [%d/%d/%d]",
              r$n_kept, r$n_unrecognised, r$n_blank))
}

sab(7, "every row is accounted for, so none can vanish unnoticed")
{
  # The arithmetic guard. kept + blank + military + unrecognised must equal
  # the input length; if a future edit introduces a fifth category that is
  # neither kept nor reported, this fails rather than losing rows quietly.
  messy <- c("CO", "", NA, "AE", "GERMANY", " tx ", "XX", "80204", "DC", "PR")
  r <- quiet(clean_state_report(messy))
  chk(r$n_kept + r$n_blank + r$n_military + r$n_unrecognised == r$n_input,
      sprintf("the four categories sum to the input [%d of %d]",
              r$n_kept + r$n_blank + r$n_military + r$n_unrecognised,
              r$n_input))
}

sab(8, "INVERTED: every valid code must survive")
{
  # A cleaner that refused everything would satisfy most tests above. All
  # fifty states, the District, and the five inhabited territories must pass.
  all_valid <- VALID_STATES
  cleaned <- clean_state(all_valid)
  chk(!any(is.na(cleaned)),
      sprintf("all %d valid codes kept [%d lost]", length(all_valid),
              sum(is.na(cleaned))))
  chk(identical(cleaned, all_valid), "and each returns itself unchanged")
  chk(all(c("DC", "PR", "VI", "GU", "AS", "MP") %in% all_valid),
      "the District and the five inhabited territories are among them")
}

sab(9, "INVERTED: the vector contract holds")
{
  # Twenty-six callers use this inside mutate(). A function that dropped or
  # reordered elements would corrupt every row alignment downstream.
  input <- c("CO", "bogus", NA, " tx ", "AE")
  out <- clean_state(input)
  chk(length(out) == length(input),
      sprintf("length preserved [%d in, %d out]", length(input), length(out)))
  chk(identical(out, c("CO", NA, NA, "TX", NA)),
      "and position preserved, element for element")
  chk(is.character(out), "the return is always character, never factor")
}

sab(10, "INVERTED: cleaning twice changes nothing")
{
  input <- c("co", " TX ", "Colorado", "AE", NA)  # Colorado resolves, then holds
  once <- clean_state(input)
  chk(identical(once, clean_state(once)),
      "a second pass over cleaned values is a no-op")
}

cat(sprintf("\n%s (%d failures across 10 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
