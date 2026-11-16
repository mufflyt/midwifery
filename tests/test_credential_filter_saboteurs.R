#!/usr/bin/env Rscript
# =============================================================================
# Ten saboteurs against the credential filter: who is in the cohort at all
# =============================================================================
# WHY THIS ONE. exclude_by_credential() is four lines and decides membership.
# It is the gate that keeps physicians out of a midwife cohort in
# extract_dac_midwives.R and extract_physician_compare_historical_midwives.R,
# so a silent failure does not move a percentage -- it moves the denominator
# under every percentage in every table.
#
# E2 is the defect these were written around. A word boundary cannot see
# through punctuation, so the pattern for MD never matched "M.D.", and a
# physician written in the dotted form would have passed into the cohort
# with nothing failing. Neither current source writes the dotted form (0 of
# 4,944 and 0 of 36,339, checked directly), so the gap was latent. Latent is
# how it stays until a federal file changes its house style.
#
# Four are inverted, because a filter that excluded everything, or kept
# everything, would satisfy a naive suite and destroy the cohort either way.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "lib", "credential_filter.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}
keep <- function(x, ...) exclude_by_credential(x, ...)
sab <- function(n, name) cat(sprintf("\nE%d %s\n", n, name))

sab(1, "a bare physician credential, however it is cased")
{
  chk(all(!keep(c("MD", "md", "Md", "DO", "do", "Do"))),
      "MD and DO are excluded in every casing")
}

sab(2, "THE LATENT GAP: the dotted form a word boundary cannot see")
{
  # "\\bMD\\b" never matched "M.D." because that string holds no adjacent M
  # and D. A physician in dotted form entered the midwife cohort silently.
  chk(!keep("M.D."), "M.D. is excluded")
  chk(!keep("D.O."), "D.O. is excluded")
  chk(!keep("m.d."), "and in lower case")
  chk(!keep("CNM, M.D."), "and inside a compound credential")
}

sab(3, "INVERTED: a credential that merely contains the letters survives")
{
  # The reason the match is whole-word in the first place. A dentist (DMD)
  # and a doctor of oriental medicine (DOM) are not physicians by this
  # filter's definition, and stripping periods must not change that.
  chk(keep("DMD"), "DMD is not MD")
  chk(keep("DOM"), "DOM is not DO")
  chk(keep("D.M.D."), "and the dotted dentist is still not a physician")
  chk(keep("PH.D."), "PH.D. is kept: it contains neither credential")
}

sab(4, "a physician credential inside a compound string")
{
  chk(!keep("CNM, MD"), "after a comma")
  chk(!keep("MD/PhD"), "before a slash")
  chk(!keep("CNM MD"), "after a space")
  chk(!keep("MSN, CNM, DO"), "last in a list")
}

sab(5, "INVERTED: every midwife credential survives")
{
  midwife <- c("CNM", "CM", "CNM MSN", "APRN", "MSN", "RN", "CNM, FACNM",
               "DNP", "PHD")
  kept <- keep(midwife)
  chk(all(kept),
      sprintf("all %d midwife credentials kept [%d lost]",
              length(midwife), sum(!kept)))
}

sab(6, "a missing or blank credential is kept, and kept DETERMINISTICALLY")
{
  # An absent credential is not evidence of being a physician, so it is
  # kept. The stronger requirement is that the answer is TRUE and not NA:
  # an NA here, used as a data-frame index, injects an all-NA phantom row.
  r <- keep(c(NA_character_, "", "   "))
  chk(!any(is.na(r)), "the result is never NA")
  chk(all(r), "and all three are kept")
}

sab(7, "no phantom row when the result is used as an index")
{
  # The failure E6 guards against, demonstrated on a data frame.
  rows <- data.frame(npi = c("1", "2", "3", "4"),
                     credential = c("CNM", NA, "MD", ""),
                     stringsAsFactors = FALSE)
  out <- rows[keep(rows$credential), ]
  chk(nrow(out) == 3L, sprintf("three rows survive, not two or four [%d]",
                               nrow(out)))
  chk(!any(is.na(out$npi)), "and none of them is an all-NA phantom")
  chk(identical(out$npi, c("1", "2", "4")), "the physician is the one dropped")
}

sab(8, "INVERTED: the vector contract holds")
{
  input <- c("CNM", "MD", NA, "DMD", "D.O.")
  out <- keep(input)
  chk(length(out) == length(input),
      sprintf("length preserved [%d in, %d out]", length(input), length(out)))
  chk(is.logical(out), "the return is logical, never character or factor")
  chk(identical(out, c(TRUE, FALSE, TRUE, TRUE, FALSE)),
      "and position preserved, element for element")
}

sab(9, "a caller's exclude list is escaped, not executed")
{
  # exclude is interpolated into a regular expression. Unescaped, a caller
  # passing "M.D" would make the period a wildcard and exclude MXD, MAD,
  # M1D -- quietly removing people who are not physicians at all.
  chk(keep("MXD", exclude = "M.D"),
      "a period in the exclude list is literal, so MXD is kept")
  chk(!keep("M.D", exclude = "M.D"), "while the literal value still matches")
  # A PERIOD IS THE WEAK PROBE, because periods are stripped from both sides
  # before escaping, so it never exercises the escape at all. Mutation
  # testing caught that: removing the escape entirely broke nothing until
  # this case was added. A star survives the stripping and does not.
  chk(keep("D", exclude = "M*D"),
      "an unescaped M*D would mean 'zero or more M then D' and exclude a bare D")
  chk(keep("CNM", exclude = "(MD)"),
      "and a parenthesis in the list cannot open a capture group")
  chk(keep("CNM", exclude = c("MD", "DO")), "the default list still works")
}

sab(10, "INVERTED: excluding nothing keeps everyone")
{
  # A filter that drops rows when asked to drop nothing would silently
  # shrink any cohort that called it with an empty list.
  everyone <- c("CNM", "MD", "DO", "M.D.", NA, "")
  chk(all(keep(everyone, exclude = character(0))),
      "an empty exclude list removes nobody")
}

cat(sprintf("\n%s (%d failures across 10 saboteurs)\n",
            if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
