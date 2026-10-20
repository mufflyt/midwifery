#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: R/amcb_name_keys.R
# =============================================================================
# Almost everything in this file is a re-exported alias of the mysterynpi
# package, which carries its own CI contracts (test_mysterynpi_contracts.R
# already runs assert_*_contract() here). Saboteur-testing those aliases
# again would test mysterynpi a second time under a different name, not this
# file. The genuinely LOCAL behaviour -- the two places this file changes
# what the package returns rather than just renaming it -- is what these
# tests target, and they surface a real discrepancy between the two shims.
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
owd <- setwd(root); on.exit(setwd(owd), add = TRUE)
source(file.path(root, "R", "amcb_name_keys.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cat("\n-- amcb_parse_person(): the NA-contract shim --\n")
{
  # T1. The shim's whole job: mysterynpi renders absent parts as "", and this
  # repository's callers test is.na() instead, so the shim must convert.
  got1 <- amcb_parse_person("Jane Q Public")
  chk(identical(got1$first, "JANE") && identical(got1$middle, "Q") &&
      identical(got1$last, "PUBLIC") && is.na(got1$suffix),
      "T1 a full name parses with every present part filled and the absent suffix as NA, not ''")

  # T2. Blank input and explicit NA input must both normalise to ALL-NA
  # parts -- not an empty string anywhere, which is exactly the distinction
  # the shim exists to enforce.
  got2a <- amcb_parse_person("")
  got2b <- amcb_parse_person(NA_character_)
  chk(all(vapply(got2a, is.na, logical(1))) && all(vapply(got2b, is.na, logical(1))),
      "T2 both a blank string and an explicit NA parse to all-NA parts, never ''")
}

cat("\n-- amcb_split_first() vs amcb_parse_person(): a real contract mismatch --\n")
{
  # T3. amcb_split_first() does NOT apply the same NA-contract as
  # amcb_parse_person() -- it passes mysterynpi::split_given()'s output
  # straight through, where an absent part is "" rather than NA. Both
  # functions live in the same file and sound like they should agree; they
  # do not. Pinned here so a future caller who assumes file-wide consistency
  # (reasonably, given T1/T2 above) finds this test rather than a silent
  # is.na() check that never fires.
  got3 <- amcb_split_first("")
  chk(identical(got3$given, "") && identical(got3$middle_from_first, "") &&
      !is.na(got3$given) && !is.na(got3$middle_from_first),
      sprintf("T3 CONFIRMED DISCREPANCY: amcb_split_first('') returns '' (not NA) for both parts [given=%s, middle=%s] -- the opposite convention from amcb_parse_person() in the same file",
              dQuote(got3$given, q = FALSE), dQuote(got3$middle_from_first, q = FALSE)))

  # T4. A normal, non-blank name is unaffected by the discrepancy -- confirms
  # T3 is specifically about the absent-value convention, not a general
  # parsing difference.
  got4 <- amcb_split_first("Mary Ann")
  chk(identical(got4$given, "MARY") && identical(got4$middle_from_first, "ANN"),
      "T4 a populated name splits identically regardless of the NA-convention difference")
}

cat("\n-- coalesce_chr(): NULL and elementwise NA handling --\n")
{
  # T5. NULL must coalesce to a single empty string, not an empty character
  # vector -- a caller treating this as a scalar default would otherwise get
  # length-0 propagating silently into a paste()/sprintf() downstream.
  chk(identical(coalesce_chr(NULL), "") && length(coalesce_chr(NULL)) == 1L,
      "T5 coalesce_chr(NULL) is a length-1 '', not character(0)")

  # T6. NA is coalesced ELEMENTWISE inside a vector -- a non-NA neighbour
  # must survive untouched, and an NA must become '' in place, not vanish or
  # blank the whole vector.
  got6 <- coalesce_chr(c("a", NA, "b", NA))
  chk(identical(got6, c("a", "", "b", "")),
      sprintf("T6 coalesce_chr() replaces NA with '' per-element without touching its neighbours [%s]",
              paste(dQuote(got6, q = FALSE), collapse = ", ")))
}

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
